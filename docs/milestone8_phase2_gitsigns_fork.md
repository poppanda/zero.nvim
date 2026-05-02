# zero.nvim 远程 git 渲染 — gitsigns fork 适配方案

> **状态（2026-05-02）**
> - Phase 2A（只读 signs / hunk 跳转）— ✅ 完成
>   - zero-nvim：`76e9a08 feat(gitsigns): add zero-nvim backend for remote git diff signs`
>   - fork：`6ce1ce9 feat(backend): add pluggable data-layer backend abstraction`
> - Phase 2B（stage_hunk / reset_hunk / blame）— ✅ 完成
>   - zero-nvim：`290636c feat(gitsigns): Phase 2B — stage_hunk / reset_hunk / blame on remote buffers`
>   - fork：`c1212d9 fix(actions): gate Path.exists pre-flight on backend.is_local`
> - Phase 2C（刷新机制：事件 + 可选轮询）— ✅ 完成（本次 commit 包含）
>
> 本文档从"计划"演变为"实现 + 维护参考"，含代码导航与已踩坑总结。

---

## 目录

- [Context](#context)
- [架构总览](#架构总览)
- [数据流（远程 buffer 打开 → signs 渲染）](#数据流远程-buffer-打开--signs-渲染)
- [跨模块数据传输机制](#跨模块数据传输机制)
- [Fork 内部修改](#fork-内部修改)
- [zero-nvim 端](#zero-nvim-端)
- [Phase 2C — 刷新机制（事件 + 可选轮询）](#phase-2c--刷新机制事件--可选轮询)
- [代码导航（维护时按这里查）](#代码导航维护时按这里查)
- [实施过程中遇到的坑](#实施过程中遇到的坑)
- [验证策略](#验证策略)
- [风险与对策](#风险与对策)
- [不在本方案范围](#不在本方案范围)

---

## Context

**目标**：让 `zero://user@host:port/path` 的远程 buffer 也能用 gitsigns
正常显示 git diff signs、hunk 跳转、stage/reset、blame——但 git 命令
全部走 zero-nvim 的 daemon 跑在远端，不在本地执行。

**为什么 fork**：gitsigns 内部用 `vim.system` / `vim.uv.fs_realpath` 等本地
原语硬编码了"git 在本机执行"假设。无法通过 lua 猴子补丁干净地拦截——
attach 阶段就会因 `fs_realpath` / 目录存在性检查直接 reject 远程 URI。
最小代价是 fork + 引入"backend 抽象层"，在 fork 内部做一次重构：把
"数据获取层"从渲染层解耦，本地保留默认 backend，远程通过 zero-nvim
注册自己的 backend。

**用户决策**：
- fork 维护在 `~/Code/Neovim/gitsigns.nvim/`，平行于 zero.nvim
- branch 名 `zero-nvim-backend`，基于 upstream `main`，定期 rebase
- backend 抽象做得通用 → 长期目标提 PR 给 upstream（非必需）
- zero-nvim 端只做注册 + 实现具体 backend 函数，**不**修改 fork 之外的 gitsigns 文件

---

## 架构总览

### 两层切分
```
┌─ 数据层（按 backend 替换） ───────────────────────────┐
│   gitsigns.system.system / git.Repo / git.Obj         │
│   - spawn 进程 / 等待退出                              │
│   - 解析 bufpath → toplevel / gitdir / relpath         │
│   - 持有 SystemCompleted 风格的 stdout/stderr/code     │
└─ 渲染层（**不动**）─────────────────────────────────┘
    manager.lua / signs.lua / hunks.lua / status.lua /
    actions.lua / blame_formatter.lua / popup.lua /
    hunk_preview.lua / current_line_blame.lua / etc.
```

### Backend 接口（fork 内 `lua/gitsigns/backends.lua`）

```lua
---@class Gitsigns.Backend
---@field id           string                                   -- "local" | "zero" | ...
---@field is_local?    boolean                                   -- 控制本地路径检查、watcher 等
---@field pattern?     string                                    -- 匹配 bufpath 的 lua 模式
---@field detect       fun(bufpath: string): table?              -- → ctx 或 nil
---@field resolve_path fun(ctx, bufpath): string                 -- 返回 git 命令用的路径
---@field system       fun(cmd: string[], opts: table, ctx: table, on_exit: fun(SystemCompleted))

local M = {}
function M.register(backend) ... end       -- 追加进 registered（pattern 优先匹配）
function M.pick(bufpath) ... end           -- 返回 (backend, ctx)；最终 fallback default_local
function M.set_default_local(backend) end  -- 启动时由 system.lua 注册一个本地 backend
function M.get(id) ... end                 -- 按 id 取已注册 backend（zero-nvim smoke 用）
return M
```

`SystemCompleted` 沿用 Neovim `vim.system` 的形状：
```lua
{ stdout = string, stderr = string, code = integer, signal = integer }
```

`is_local` 是后来加上的——决定 attach 时是否做本地 `Path.exists` / `Path.is_dir`
检查、是否启 `uv.fs_event` 监听 `.git/HEAD`、actions 的 `bcache.file` 存在性
预检是否走。所有"只在本地有意义"的分支都按它分流（详见[实施过程中遇到的坑](#实施过程中遇到的坑)）。

---

## 数据流（远程 buffer 打开 → signs 渲染）

```
1. user :edit zero://u@h:22/repo/sub/foo.lua
2. zero-nvim BufReadCmd 拉文件 + 显式 fire BufReadPost
3. gitsigns.attach 触发：
   a. backends.pick("zero://u@h:22/repo/sub/foo.lua")
      → (zero_backend, ctx={target={u,h,22}, path="/repo/sub/foo.lua"})
   b. backend.resolve_path(ctx, bufpath) → "/repo/sub/foo.lua"
      → 跳过 uv.fs_realpath / dir-exists 检查（按 backend.is_local 分流）
   c. git.Obj.new(file="/repo/sub/foo.lua", revision, encoding, gitdir, toplevel, backend, ctx)
4. git.Obj.new 内部调 backend.system 跑：
   - git rev-parse --show-toplevel  → "/repo"
   - git config <core.*>            → 编码 / autocrlf 等
   - git ls-files /repo/sub/foo.lua
   - git cat-file -p HEAD:sub/foo.lua  → 基线字节
5. zero_backend.system 把每条命令包装成 cmd.stream 调用 → daemon
   → 累积 stdout/stderr → on_exit 时回调 gitsigns 的 SystemCompleted
6. gitsigns 拿到基线字节 → 本地跑 xdiff (diff_int.lua) 算 hunks
7. signs 渲染 → buffer 上出现 +/~/-
```

### 关键点
- **基线 diff 计算在本地完成**（gitsigns 已经在用 xdiff 纯 Lua 实现），
  daemon 只负责把 HEAD 内容捞过来。零额外远程开销。
- **每次远程 git 命令 = 1 个 cmd.stream**，daemon 用专属 SSH session 跑，
  不阻塞 SFTP / read_dir / 其他 buffer 的 git 操作。
- **path 转换只在入口一次**：detect 解析 URI 拿出 `path`，从此 git 命令
  全用 remote path（不带 `zero://` 前缀）。出口（UI）几乎不需要 URI 回填。

---

## 跨模块数据传输机制

### 异步包装：cmd.stream → SystemCompleted

gitsigns 的 `system(cmd, opts, on_exit)` 是 callback 风格（被 `async.wrap(3, ...)`
包成 coroutine）。在 zero backend 里这样实现：

```lua
function M.system(cmd, opts, ctx, on_exit)
    -- gitsigns 的 stage_hunks 用 string[] patch；vim.system 对 string[] 的语义是
    -- 每行 + '\n'（含末尾），等价于 table.concat(arr, "\n") .. "\n"。
    -- 漏掉末尾 '\n' 会让 git apply 报 "corrupt patch at line N"。
    local stdin = opts.stdin
    if type(stdin) == "table" then
        stdin = table.concat(stdin, "\n") .. "\n"
    end

    -- vim.SystemOpts.stdout/stderr 也支持流式回调（function(err, data)，EOF 用
    -- data == nil 收尾）；blame --incremental 的 buffered_line_reader 是
    -- coroutine yield 等数据，少了那个 nil 收尾会永远阻塞。
    local stdout_cb = type(opts.stdout) == "function" and opts.stdout or nil
    local stderr_cb = type(opts.stderr) == "function" and opts.stderr or nil

    local stdout_chunks, stderr_chunks = {}, {}

    require("zero-nvim.cmd").stream(ctx.target, {
        argv = wrap_with_path(cmd),  -- sh -c 'PATH=...:$PATH exec "$@"' --
        cwd = opts.cwd,
        env = env_to_pairs(opts.env),
        stdin = stdin,
        timeout_ms = opts.timeout and opts.timeout * 1000 or nil,
    }, {
        on_event = function(ev)
            if     ev.kind == "stdout" then
                if stdout_cb then stdout_cb(nil, ev.text)
                else stdout_chunks[#stdout_chunks+1] = ev.text end
            elseif ev.kind == "stderr" then
                if stderr_cb then stderr_cb(nil, ev.text)
                else stderr_chunks[#stderr_chunks+1] = ev.text end
            end
        end,
        on_exit = function(code, signal, reason)
            if stdout_cb then stdout_cb(nil, nil) end       -- EOF for streaming reader
            if stderr_cb then stderr_cb(nil, nil) end
            on_exit({
                stdout = stdout_cb and "" or table.concat(stdout_chunks),
                stderr = stderr_cb and "" or table.concat(stderr_chunks),
                code   = reason and -1 or (code or 0),
                signal = signal or 0,
            })
        end,
    })
end
```

**为什么不用 `cmd.sync_full`**：sync_full 是阻塞 `rpcrequest`，会冻结
编辑器；attach 时一个 buffer 至少 4 条 git 命令，多 buffer 同时 attach
会瞬间卡顿。stream 是 notification 驱动，全程异步。

### 并发模型

- 每个 `cmd.stream` 在 daemon 端拿独立 SSH session（`open_dedicated_session`，
  Phase 0 已建好）。同一主机多条 git 命令并发跑互不阻塞。
- gitsigns 自身用 coroutine 串行化 *单个 buffer 的* git 操作（避免
  比较 stale baseline）；不同 buffer 之间是天然并行。
- daemon 端 SSH session pool 上限：libssh2 单 Session 不能多线程，但
  打开多 Session（每条 cmd 一个）安全；session pool 上限取决于 ssh
  server 的 `MaxSessions`（默认 10）—— **风险点：大量并发 attach 时
  超 MaxSessions 会失败**，需要 daemon 端排队（见下方风险表）。

### Repo 缓存

gitsigns 自带 `repo_cache` 按 `gitdir` 去重（弱表）。两个 host 上
同名 `gitdir`（比如都是 `/repo/.git`）会撞键。fork 内修复：

```lua
-- repo.lua
local function repo_cache_key(backend, gitdir)
    return backend.id .. ':' .. gitdir
end
```

`backend.id`：local backend 是 `"local"`，zero backend 内部按 `"zero://u@h:p"`
（包含 user/host/port）做缓存键前缀。两个不同远端的同路径 gitdir 自然分开。

### Path 翻译

| 边界 | 方向 | 处理 |
|---|---|---|
| URI → remote path | attach 入口 | `backend.detect(bufpath)` 一次解析，结果存 ctx |
| 远端命令的 cwd | 调 system 时 | gitsigns 传 `opts.cwd = toplevel`（远端绝对路径），原样转给 cmd.stream |
| stdout 字节 → 字符串行 | git/cmd.lua 内 | gitsigns 现有逻辑 split('\n')；二进制 baseline 走 stdout 字节字段不分行 |
| remote path → URI | UI（极少需要） | 仅在打开文件场景需要回拼 URI；hunk preview / blame popup 不涉及 |

---

## Fork 内部修改

| 文件 | 改动 | 说明 |
|---|---|---|
| `lua/gitsigns/backends.lua` | **新增** registry | ~85 行；register / pick / set_default_local / get |
| `lua/gitsigns/system.lua` | 启动时注册 default `local` backend | +10 行；`system()` 主体不变（向后兼容） |
| `lua/gitsigns/attach.lua` | `get_buf_context` 改走 `backends.pick`；本地路径检查按 `backend.is_local` 分流 | ~30 行 |
| `lua/gitsigns/git.lua` | `Obj.new` 新增 `backend, ctx` 参数；存到 `self.repo` | ~5 行（透传到 Repo.get） |
| `lua/gitsigns/git/repo.lua` | `Repo.get` / `get_info` / `get_head_oid` 等新增 `backend, ctx`；`repo_cache` 键加 backend.id 前缀；watcher 仅 local 启 | ~30 行 |
| `lua/gitsigns/git/cmd.lua` | `git_command` 新增可选 `backend, ctx`；有 backend 时调 `backend.system`，否则原 `system.system` | ~20 行 |
| `lua/gitsigns/actions.lua` | `stage_hunk` / `stage_buffer` 的 `Path.exists` 预检按 `backend.is_local` 分流 | ~6 行 × 2 处（Phase 2B 加） |

**总计 fork diff ~200 行**，集中在 7 个文件，rebase 友好。

### 核心 fork 修改点 — git/cmd.lua

```lua
-- 改造后：
local function git_command(args, spec, backend, ctx)
    spec = spec or {}
    local cmd = { 'git', ..., unpack(args) }
    local sys
    if backend then
        sys = async.wrap(3, function(c, o, on_exit)   -- closure 只 3 个参数
            backend.system(c, o, ctx, on_exit)         -- ctx via closure
        end)
    else
        sys = async.wrap(3, require('gitsigns.system').system)
    end
    local result = sys(cmd, opts)
    return stdout_lines(result.stdout), result.stderr, result.code
end
```

⚠️ **`async.wrap(N, fn)` 的 `N` 是闭包接受的"总参数数（含 callback）"**，不是
原函数的参数数。如果写 `async.wrap(4, function(c, o, on_exit) ...)` 但闭包只
接受 3 个参数，`await_cbfun` 会把 callback 注入到第 4 位，闭包看到的 `on_exit`
是 nil，永远不调用 → coroutine 永远阻塞。详见[实施过程中遇到的坑](#实施过程中遇到的坑)。

调用链：`Obj.method` → `self.repo:command(args, spec)` → `git_command(args, spec, self.backend, self.ctx)`。

---

## zero-nvim 端

### 目录结构（实际）

```
lua/zero-nvim/gitsigns/
├── backend.lua    -- 注册到 fork 的 backend；实现 system/detect/resolve_path
└── refresh.lua    -- 远端没 fs_event，靠事件 + 可选轮询触发 :Gitsigns refresh
```

### 注册时机

`init.lua` `M.setup(opts)` 末尾：
```lua
require("zero-nvim.gitsigns.backend").setup(options.gitsigns)
```
`options.gitsigns` 透传给 `refresh` 子模块（`{ refresh = { debounce_ms, poll_ms } }`）。
即使用户装的是 upstream gitsigns，`pcall(require, 'gitsigns.backends')` 失败也
不影响 refresh 部分注册——只是 zero:// buffer 不会有 sign 而已。

### 复用现有
- `lua/zero-nvim/uri.lua` — 解析 zero:// URI
- `lua/zero-nvim/cmd/init.lua` — `cmd.stream` API（Phase 0 已建好）

### 不用动的
- daemon Rust 代码 —— 现有 `cmd_stream` / `cmd_sync` 已够用
- gitsigns 渲染层 —— signs.lua / manager.lua / hunks.lua 一行不改

---

## Phase 2C — 刷新机制（事件 + 可选轮询）

**问题**：本地 gitsigns 用 `uv.fs_event` 监听 `.git/HEAD`；远端没法直接监听。
最初计划只做事件触发版（plan A），实际加了**可选轮询**作为补充——纯事件
覆盖不到"buffer 一直焦点不切换、HEAD 被外部改"这种边缘场景。

### 实际实现（`lua/zero-nvim/gitsigns/refresh.lua`）

两条路径，都打到同一个 `do_refresh()`（带 in-flight gate）：

| 路径 | 触发 | 经过 debounce？ |
|---|---|---|
| 事件 | `BufEnter` / `BufWritePost` 命中 `zero://*`，`FocusGained` 且当前 buf 是 zero:// | ✅ 300ms |
| 轮询 | `uv.new_timer` 间隔 `poll_ms`，仅在有 zero:// buffer 摆在 win 上时发 | ❌ 直接进 in-flight gate |

**为什么轮询不走 debounce**：debounce 用于"短时间多次事件合并"。轮询自身就是
固定节奏，再 debounce 会让 `poll_ms < debounce_ms` 时 debounce timer 被反复
重置永远不触发——这是写 smoke 时发现并修掉的实际 bug（commit 内 L6 case）。

### 默认配置

```lua
require("zero-nvim").setup({
    gitsigns = {
        refresh = {
            debounce_ms = 300,   -- 事件 debounce + in-flight 释放节奏
            poll_ms = 0,         -- 0 = 关闭；建议 ≥5000（要 > debounce_ms）
        },
    },
})
```

`poll_ms = 0`（默认）= 不创建 timer，零开销；纯事件驱动应付 95% 场景。

### in-flight gate

`:Gitsigns refresh` 内部是 async（attach + N 条 git 命令），同步触发即返。我们
靠"等够 1 个 debounce 周期再放 in-flight"作为启发——避免连发把 daemon 打爆。
不是严格保证，但够用。

---

## 代码导航（维护时按这里查）

### zero-nvim 端

| 关注点 | 文件 : 行 / 函数 |
|---|---|
| backend 入口注册 | `lua/zero-nvim/gitsigns/backend.lua` `M.setup(opts)` |
| URI → ctx 解析 | `lua/zero-nvim/gitsigns/backend.lua` `M.detect(bufpath)` |
| cmd → SystemCompleted 适配 | `lua/zero-nvim/gitsigns/backend.lua` `M.system(cmd, opts, ctx, on_exit)` |
| 远端 PATH 注入 | `lua/zero-nvim/gitsigns/backend.lua` `wrap_with_path(argv)` |
| 流式回调（blame --incremental） | `lua/zero-nvim/gitsigns/backend.lua` 中 `stdout_cb / stderr_cb` 分支 |
| stdin trailing-\n 修复 | `lua/zero-nvim/gitsigns/backend.lua` `if type(stdin) == "table" then` |
| refresh autocmd 注册 | `lua/zero-nvim/gitsigns/refresh.lua` `M.setup(opts)` |
| refresh 节流（debounce + in-flight） | `lua/zero-nvim/gitsigns/refresh.lua` `do_refresh / schedule_refresh` |
| 轮询 timer | `lua/zero-nvim/gitsigns/refresh.lua` `configure_poll()` |
| 默认配置 | `lua/zero-nvim/init.lua` `defaults.gitsigns` |
| BufReadPost 显式 fire | `lua/zero-nvim/init.lua` `BufNew` autocmd 内 |
| smoke 入口 | `scripts/smoke_phase2a.{lua,sh}` / `scripts/smoke_phase2c.{lua,sh}` |

### Fork 端（`~/Code/Neovim/gitsigns.nvim/`，branch `zero-nvim-backend`）

| 关注点 | 文件 : 函数 |
|---|---|
| backend 注册表 | `lua/gitsigns/backends.lua`（整文件） |
| local backend 默认注册 | `lua/gitsigns/system.lua` 模块加载尾部 |
| backend.pick / 路径检查分流 | `lua/gitsigns/attach.lua` `get_buf_context` |
| `Obj.new` 透传 backend | `lua/gitsigns/git.lua` `Obj.new` |
| `Repo.get` / 缓存 key 加 backend.id | `lua/gitsigns/git/repo.lua` `M.get / repo_cache_key` |
| watcher gating | `lua/gitsigns/git/repo.lua` `M._new` |
| `git_command` 走 backend | `lua/gitsigns/git/cmd.lua` `git_command` |
| stage 预检 gating | `lua/gitsigns/actions.lua` `stage_hunk` / `stage_buffer`（搜 `backend_is_local`） |

### 关键 commit

| Phase | zero-nvim | gitsigns fork |
|---|---|---|
| 2A 只读 signs | `76e9a08` | `6ce1ce9` |
| 2B 写 + blame | `290636c` | `c1212d9` |
| 2C 刷新机制 | （本次 commit） | — |

---

## 实施过程中遇到的坑

按踩到的顺序列出，避免后续维护重蹈覆辙。

### 1. `async.wrap(N, fn)` 的 N 是闭包参数数，不是原函数参数数

最初 `git/cmd.lua` 写 `async.wrap(4, function(c, o, on_exit) backend.system(c, o, ctx, on_exit) end)`
（想着 4 = c + o + ctx + on_exit）。结果 `await_cbfun` 把 callback 注入到 `args[4]`，
但闭包只读 3 个参数，`on_exit` 是 nil。表象：attach 永远跑不到第 3 条 git 命令，
buffer 卡在"半 attach"。**修法**：闭包就 3 个参数（c / o / on_exit），
ctx 走 closure 闭包；`async.wrap(3, ...)`。

### 2. oil.nvim 的 `buftype = "acwrite"` 让 attach 直接被 reject

oil 给所有打开的文件 buffer 设 `buftype = "acwrite"`（见 oil/init.lua:1100），
而 gitsigns attach 上来就 `if buftype ~= '' then return 'Non-normal buffer'`。
**修法**：fork attach.lua 把这个判定按 `backend.is_local` 分流——非 local
backend 不查 buftype（远端 buffer 本来就是虚拟的）。

### 3. oil 的 `signcolumn = "no"` window 选项会持久到文件 buffer

oil 用 `view.set_win_options` 给 oil 目录窗设 `win_options.signcolumn = "no"`。
窗里换成文件 buffer 后这个 window 选项不会还原，sign 就显示不出来。
**修法**：用户在 oil 配置里把 `win_options.signcolumn = "yes"`。
（不是 fork 内的事，但这是排查 sign 不显示的常见盲点。）

### 4. `BufReadCmd` 不会自动 fire `BufReadPost`

我们用 `BufReadCmd` 接管 `zero://*` 的内容加载，但 `BufReadCmd` **替换**
`BufRead`，不再自动派 `BufReadPost`。gitsigns 的 attach autocmd 监听的是
`BufReadPost`——结果远端 buffer 永远不会触发 attach。
**修法**：`init.lua` 的 BufReadCmd handler 末尾显式
`vim.api.nvim_exec_autocmds("BufReadPost", { buffer = args.buf })`。

### 5. `actions.lua` 的本地 `Path.exists` 预检拒掉远端 buffer

`stage_hunk` / `stage_buffer` 在跑 git apply 之前 `if not util.Path.exists(bcache.file)`
预检——远端文件本地不存在，直接报 "Cannot stage lines. Please add the file
to the working tree."。**修法**：fork actions.lua 同样按 `backend.is_local` 分流。

### 6. `vim.system` 对 `string[]` stdin 的语义带末尾 `\n`

gitsigns 的 `create_patch` 返回 `string[]`（每行一个元素）。`vim.system`
对 `string[]` 的实际语义是"每元素 + '\n'（含末尾）"，等价于
`table.concat(arr, "\n") .. "\n"`。我最初写
`table.concat(arr, "\n")`（漏末尾 \n），git apply 报 "corrupt patch at line N"。
**修法**：`table.concat(arr, "\n") .. "\n"`。

### 7. `git blame --incremental` 需要流式回调 + EOF nil

gitsigns blame 用 `coroutine.yield` 等数据：`function on_stdout(_, data) reader(data) end`，
reader 是 `buffered_line_reader` 形态，`data == nil` 是 EOF 信号。如果
backend.system 只在 on_exit 一次性吐 stdout，coroutine 永远不退出。
**修法**：backend.system 检查 `opts.stdout / opts.stderr` 是不是 function，
是就每个 chunk 立刻 `cb(nil, text)`，on_exit 时 `cb(nil, nil)` 收尾；
`SystemCompleted.stdout/stderr` 用流式回调时留空（与 vim.system 语义一致）。

### 8. 轮询路径不能走 debounce

Phase 2C 最初设计是事件 + 轮询都走 debounce。结果 smoke L6 暴露：
`poll_ms < debounce_ms` 时每次 poll 都 `debounce_timer:stop():start()` 重置
debounce，导致 debounce 永远不到期。**修法**：轮询路径直接调 `do_refresh()`
（带 in-flight gate），不走 debounce。

---

## 验证策略

### Phase 2A 烟雾测试

`scripts/smoke_phase2a.{lua,sh}` — 4 层自下而上验：
- L1: cmd.stream + echo（daemon notification 通路）
- L2: cmd.stream + git rev-parse（远端 PATH + git）
- L3: backend.system（gitsigns→daemon 适配层）
- L4: 完整 `:edit zero://...` → BufReadCmd → gitsigns attach（cache + #hunks 强校验）

```bash
bash scripts/smoke_phase2a.sh <user> <host> <port> <remote_path>
```

### Phase 2B smoke 扩展

`scripts/smoke_phase2a.lua` 内新增 L5/L6（同脚本）：
- L5: backend.system + `cat -` 用 table stdin（验末尾 \n）
- L6: backend.system + `git blame --incremental` opts.stdout 流式回调

### Phase 2C 本地 smoke

`scripts/smoke_phase2c.{lua,sh}` — **不连远端**，纯验 refresh 模块：
- L1: setup 装齐 BufEnter / BufWritePost / FocusGained 三个 autocmd
- L2: BufEnter 触发后 debounce 期内 0 次，过后 1 次
- L3: 短时间多次 BufEnter 合成 1 次（debounce 合并）
- L4: in-flight gate 不崩
- L5: poll_ms > 0 + 无 zero:// 窗口 → timer 空跑不刷
- L6: poll_ms > 0 + 有 zero:// 窗口 → timer 触发刷新

```bash
bash scripts/smoke_phase2c.sh
```

### 性能基线（Phase 2A 实测）
- 单 buffer attach 端到端 < 500ms（含 SSH RTT 100ms × N 命令）
- 同时 attach 5 个 buffer：UI 无明显卡顿

### Regression
- 本地 git repo `:edit /local/repo/file.lua` → signs 行为完全等价于 upstream gitsigns
- fork 自带 test suite 全过（157/157）

### 运行 fork 自身测试

```bash
cd ~/Code/Neovim/gitsigns.nvim && make test
```

---

## 风险与对策

| 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|
| backend 抽象的边界没找准，需要二次重构 | ~~中~~（已落地） | — | 已通过 fork 157 测试 + 远端 attach 验证 |
| gitsigns upstream 频繁改动 git/* 模块 → rebase 痛苦 | 中 | 长期维护成本 | 改动收敛在 backend 抽象层；7 个文件每个 < 30 行；rebase 失败时优先 cherry-pick `backends.lua` |
| 大量并发 attach 撞 SSH MaxSessions | 中 | 多 buffer 打开报错 | 待补：daemon 端 cmd.stream 加 session 池上限（建议 8）+ 排队；gitsigns coroutine 已自串行，进一步降低并发 |
| `git cat-file -p HEAD:bin_file` 二进制内容 | 低 | binary baseline 不准 | 当 stdout 含 NUL 时 gitsigns 已有跳过分支 |
| `.git/HEAD` 变化无监听 → sign stale | ~~中~~（缓解） | — | Phase 2C：事件触发兜底；可选 poll 补漏 |
| ssh server 无 git PATH | 低 | rev-parse 找不到 git | backend.system 用 `sh -c 'PATH=...:$PATH exec "$@"' --` 注入 |
| upstream 不接受 backends 抽象 PR | 高 | 永久 fork | 接受；fork 改动小、rebase 成本低 |
| `:Gitsigns refresh` 太重（refresh 本意是清重附） | 低 | poll 频率高时 daemon 打爆 | 默认 poll_ms = 0；用户开 poll 时建议 ≥5000ms |

---

## 不在本方案范围

- **`:ZeroGitStatus` 浮窗 UI**（原计划 Phase 2 track A）—— gitsigns 已有
  `:Gitsigns blame` / `Gitsigns toggle_signs` 等丰富命令，远端 status
  概览功能可以走 `:Gitsigns` builtin 或后续 fork neogit
- **stash / log / branch / rebase / commit 等高级写操作** —— P3+，可能
  通过 fork neogit 解决
- **HEAD 监听方案 B（远端 inotifywait）** —— 后续优化；当前事件 + 可选 poll 已够
- **docker 适配** —— Phase 4 独立工作
