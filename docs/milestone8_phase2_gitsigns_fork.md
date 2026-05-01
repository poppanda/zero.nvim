# zero.nvim 远程 git 渲染 — gitsigns fork 适配方案

> Phase 0（通用 cmd 基座）和 Phase 1（search 迁移到 cmd 基座）已完成并 commit。
> 本文件聚焦新的 Phase 2 设计：通过 fork gitsigns 复用其渲染层，把数据获取层
> 路由到 zero-nvim daemon。原 Phase 2 计划"自写 widgets/diff_signs.lua + ZeroGitStatus"
> 路线作废——成熟插件的渲染细节（多 sign 优先级、虚拟文本、blame popup、hunk
> 跳转、statusline 集成）重写成本太高。

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

### Backend 接口（在 fork 内新增）

新文件 `lua/gitsigns/backends.lua`：
```lua
---@class Gitsigns.Backend
---@field id           string                                   -- "local" | "zero" | ...
---@field pattern      string?                                  -- 匹配 bufpath 的 lua 模式
---@field detect       fun(bufpath: string): table?             -- → ctx 或 nil
---@field resolve_path fun(ctx): { bufpath: string, gitdir?: string, toplevel?: string }
---@field system       fun(cmd: string[], opts: table, ctx: table, on_exit: fun(SystemCompleted))

local M = {}
local registered = {}    -- 按注册顺序的 backend 列表
local default_local      -- 永远兜底

function M.register(backend) ... end       -- 追加进 registered（pattern 优先匹配）
function M.pick(bufpath) ... end           -- 返回 (backend, ctx) 或 (default_local, {bufpath})
function M.set_default_local(backend) end  -- 启动时由 system.lua 注册一个本地 backend
return M
```

`SystemCompleted` 沿用 Neovim `vim.system` 的形状：
```lua
{ stdout = string, stderr = string, code = integer, signal = integer }
```

---

## 数据流（远程 buffer 打开 → signs 渲染）

```
1. user :edit zero://u@h:22/repo/sub/foo.lua
2. zero-nvim BufReadCmd 拉文件
3. gitsigns.attach 触发：
   a. backends.pick("zero://u@h:22/repo/sub/foo.lua")
      → (zero_backend, ctx={target={u,h,22}, path="/repo/sub/foo.lua"})
   b. backend.resolve_path(ctx) → { bufpath="/repo/sub/foo.lua" }
      → 跳过 uv.fs_realpath / dir-exists 检查（fork 内部做条件分支）
   c. git.Obj.new(file="/repo/sub/foo.lua", backend=zero_backend, ctx)
4. git.Obj.new 内部调 backend.system 跑：
   - git rev-parse --show-toplevel  → "/repo"
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
包成 coroutine）。我们在 zero backend 里这样实现：

```lua
function M.system(cmd, opts, ctx, on_exit)
    local stdout_chunks, stderr_chunks = {}, {}
    require("zero-nvim.cmd").stream(ctx.target, {
        argv = cmd,
        cwd  = opts.cwd,        -- 远端 cwd（可选，gitsigns 会传 toplevel）
        env  = opts.env,
        stdin = opts.stdin,     -- 关键：stage_hunk 走 stdin patch
        timeout_ms = opts.timeout and opts.timeout * 1000 or nil,
    }, {
        on_event = function(ev)
            if     ev.kind == "stdout" then table.insert(stdout_chunks, ev.text)
            elseif ev.kind == "stderr" then table.insert(stderr_chunks, ev.text) end
        end,
        on_exit = function(code, signal, reason, _dur)
            on_exit({
                stdout = table.concat(stdout_chunks),
                stderr = table.concat(stderr_chunks),
                code   = reason and -1 or (code or 0),  -- aborted → -1
                signal = signal or 0,
            })
        end,
    })
end
```

**为什么不用 `cmd.sync_full`**：sync_full 是阻塞 `rpcrequest`，会冻结
编辑器；attach 时一个 buffer 至少 3 条 git 命令，多 buffer 同时 attach
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
local function repo_cache_key(backend_id, gitdir)
    return backend_id .. ':' .. gitdir
end
```

`backend.id`：local backend 是 `"local"`，zero backend 是 `"zero://u@h:p"`
（包含 user/host/port）。两个不同远端的同路径 gitdir 自然分开。

### Path 翻译

| 边界 | 方向 | 处理 |
|---|---|---|
| URI → remote path | attach 入口 | `backend.detect(bufpath)` 一次解析，结果存 ctx |
| 远端命令的 cwd | 调 system 时 | gitsigns 传 `opts.cwd = toplevel`（远端绝对路径），原样转给 cmd.stream |
| stdout 字节 → 字符串行 | git/cmd.lua 内 | gitsigns 现有逻辑 split('\n')；二进制 baseline 走 stdout 字节字段不分行 |
| remote path → URI | UI（极少需要） | 仅在打开文件场景需要回拼 URI；hunk preview / blame popup 不涉及 |

---

## Fork 内部需修改的文件（gitsigns）

| 文件 | 改动 | 改动量 |
|---|---|---|
| `lua/gitsigns/backends.lua` | **新增** registry | ~50 行 |
| `lua/gitsigns/system.lua` | 启动时注册 default_local backend；`system()` 不变（向后兼容） | +10 行 |
| `lua/gitsigns/attach.lua` | 加 `backends.pick`；非 local backend 跳过 `uv.fs_realpath` 和 dir-exists 检查；调 `backend.resolve_path` 替代 | ~30 行 |
| `lua/gitsigns/git.lua` | `Obj.new` 新增 `backend, ctx` 参数；存到 `self.backend / self.ctx`；所有 `self.repo:command(...)` 路径不变 | ~20 行 |
| `lua/gitsigns/git/repo.lua` | `Repo.get` 新增 `backend, ctx` 参数；`repo_cache` 键加 backend.id 前缀；存 `self.backend / self.ctx` 到 Repo 实例 | ~30 行 |
| `lua/gitsigns/git/cmd.lua` | `git_command` 新增可选 `backend, ctx` 参数；分支：有 backend 时调 `backend.system`，否则走原 `system.system` | ~20 行 |

**总计 fork diff ~150 行**，集中在 6 个文件，rebase 友好。

### 核心 fork 修改点 — git/cmd.lua

```lua
-- 当前（简化）：
local asystem = async.wrap(3, require('gitsigns.system').system)

local function git_command(args, spec)
    spec = spec or {}
    local cmd = { 'git', ..., unpack(args) }
    local stdout, stderr, code = asystem(cmd, opts)
    return stdout_lines, stderr_str, code
end

-- 改造后：
local function git_command(args, spec, backend, ctx)
    spec = spec or {}
    local cmd = { 'git', ..., unpack(args) }
    local sys
    if backend then
        sys = async.wrap(4, function(c, o, on_exit)  -- 4 = +ctx
            backend.system(c, o, ctx, on_exit)
        end)
    else
        sys = async.wrap(3, require('gitsigns.system').system)
    end
    local result = sys(cmd, opts)
    return stdout_lines(result.stdout), result.stderr, result.code
end
```

调用链：`Obj.method` → `self.repo:command(args, spec)` → `git_command(args, spec, self.backend, self.ctx)`。

---

## zero-nvim 端

### 新增文件 `lua/zero-nvim/gitsigns/backend.lua`

```lua
local M = {}

function M.id_for(target)
    return ("zero://%s@%s:%d"):format(target.user, target.host, target.port or 22)
end

function M.detect(bufpath)
    -- 复用 zero-nvim.uri.parse
    local target, path = require("zero-nvim.uri").parse(bufpath)
    if not target then return nil end
    return { target = target, path = path, id = M.id_for(target) }
end

function M.resolve_path(ctx)
    return { bufpath = ctx.path }   -- daemon 自己 realpath，无需本地
end

function M.system(cmd, opts, ctx, on_exit)
    local stdout, stderr = {}, {}
    require("zero-nvim.cmd").stream(ctx.target, {
        argv = cmd,
        cwd = opts.cwd,
        env = opts.env,
        stdin = opts.stdin,
        timeout_ms = opts.timeout and opts.timeout * 1000 or nil,
    }, {
        on_event = function(ev)
            if     ev.kind == "stdout" then table.insert(stdout, ev.text)
            elseif ev.kind == "stderr" then table.insert(stderr, ev.text) end
        end,
        on_exit = function(code, _signal, reason)
            on_exit({
                stdout = table.concat(stdout),
                stderr = table.concat(stderr),
                code   = reason and -1 or (code or 0),
                signal = 0,
            })
        end,
    })
end

function M.setup()
    local ok, backends = pcall(require, "gitsigns.backends")
    if not ok then return end          -- gitsigns 未装或非 fork 版本，静默退出
    backends.register({
        id      = "zero",              -- 单 id；具体远端 id 在 detect 里返回
        pattern = "^zero://",
        detect  = M.detect,
        resolve_path = M.resolve_path,
        system  = M.system,
    })
end

return M
```

### 修改 `lua/zero-nvim/init.lua`

`M.setup()` 末尾加：
```lua
require("zero-nvim.gitsigns.backend").setup()
```

### 复用现有
- `lua/zero-nvim/uri.lua` — 解析 zero:// URI（已存在）
- `lua/zero-nvim/cmd/init.lua` — `cmd.stream` API（Phase 0 已建好）

### 不用动的
- daemon 完全不动 —— 现有 `cmd_stream` / `cmd_sync` 已够用
- gitsigns 渲染层 —— signs.lua / manager.lua / actions.lua 一行不改

---

## 分阶段交付

### Phase 2A — 只读 signs（约 2 天）

**目标**：远程 buffer 出现 +/~/- signs，hunk 跳转 `]h`/`[h` 工作。

**实现范围**：
- fork gitsigns 到 `~/Code/Neovim/gitsigns.nvim/`，新建分支 `zero-nvim-backend`
- 实现 backend 抽象（上述 6 个文件改动）
- 实现 zero-nvim 的 backend 注册
- 跑通：rev-parse / ls-files / cat-file -p HEAD:relpath

**验收**：
1. 本地 repo buffer 行为零变化（regression）
2. 打开 `zero://...` 远程 git buffer，signs 在 1-2 秒内出现
3. 编辑 + `:w` → signs 在 1 秒内更新
4. `]h`/`[h` 跳转正确
5. 同时打开 5 个远程 buffer，全部 attach 成功
6. 关闭所有 buffer 后 `pgrep -f "git "` 远端无残留

### Phase 2B — 写命令 + blame（约 2 天）

**目标**：`:Gitsigns stage_hunk` / `reset_hunk` / `blame` 工作。

**实现范围**：
- 验证 stdin 通路（`git apply --cached -p2 -` 用 stdin 传 patch）
- 验证 incremental output（`git blame --incremental` 是流式天然契合 cmd.stream）
- 不需要新 RPC，全部走现有 backend.system

**验收**：
1. 选中 hunk → `:Gitsigns stage_hunk` → `git status` 远端确认 staged
2. `:Gitsigns blame_line` 显示行级 commit 信息
3. `:Gitsigns reset_hunk` 还原 hunk

### Phase 2C — HEAD 监听 + 边角（约 1 天）

**目标**：`.git/HEAD` 变化时 sign 自动刷新。

**问题**：本地 gitsigns 用 `uv.fs_event` 监听 `.git/HEAD`；远端没法直接
监听文件系统。

**方案 A（推荐，简单）**：BufWritePost / FocusGained 触发
`require('gitsigns').refresh()`；不轮询。

**方案 B（重）**：daemon 端跑 `inotifywait` 长流式命令推送变更。后续优化。

Phase 2A 内**不实现**，Phase 2C 才考虑。

---

## 验证策略

### Phase 2A 烟雾测试
```vim
:edit zero://u@h:22/some/repo/file.lua
" 等 1-2 秒，左边栏出现 sign
:edit zero://u@h:22/some/repo/another.lua
" 同时 attach，无卡顿
:w
" sign 更新

" cancel 验证：随便挑一个 buffer，:bw，远端 ssh u@h "pgrep -f 'cat-file'" 应空
```

### Phase 2A 性能基线
- 单 buffer attach 端到端 < 500ms（含 SSH RTT 100ms × 3 命令）
- 同时 attach 5 个 buffer：UI 无明显卡顿，首个 sign 显示 < 1.5s

### Phase 2A regression
- 本地 git repo `:edit /local/repo/file.lua` → signs 行为完全等价于 upstream gitsigns
- 跑 gitsigns 自带的 test suite（fork 本身要保持原有测试通过）

### Phase 2B 验证
- stage：`:Gitsigns stage_hunk` 后远端 `git diff --cached` 显示该 hunk
- blame：`:Gitsigns blame` 弹窗显示正确的 commit + author + date

---

## 风险与对策

| 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|
| backend 抽象的边界没找准，需要二次重构 | 中 | Phase 2A 拖延 | 先按"6 文件改动"实现 → 跑通本地 backend regression → 再上 zero backend；本地 regression 失败立刻退回收紧抽象 |
| gitsigns upstream 频繁改动 git/* 模块 → rebase 痛苦 | 中 | 长期维护成本 | 改动收敛在 backend 抽象层；对每个 git/*.lua 文件的修改尽量小（< 30 行/文件）；rebase 失败时优先 cherry-pick 我们的 backends.lua |
| 大量并发 attach 撞 SSH MaxSessions | 中 | 多 buffer 打开报错 | daemon 端 cmd.stream 加 session 池上限（比如 8）+ 排队；gitsigns coroutine 已经有自己的串行化，进一步降低并发 |
| `git cat-file -p HEAD:bin_file` 二进制内容 | 低 | binary baseline 不准 | Phase 2A 不解决；当 stdout 含 NUL 时跳过 attach（gitsigns 已有此分支） |
| `.git/HEAD` 变化无监听 → sign stale | 中 | 用户感知到旧 diff | Phase 2C 方案 A：BufWritePost / FocusGained 自动 `:Gitsigns refresh` |
| ssh server 无 git PATH | 低 | rev-parse 找不到 git | Phase 1 已有 PATH 注入模式；backend.system 的 opts.env 自动注入相同 PATH 前缀 |
| upstream 不接受 backends 抽象 PR | 高 | 永久 fork | 接受；fork 改动小、rebase 成本低，作为长期方案可控 |

---

## 不在本方案范围

- **`:ZeroGitStatus` 浮窗 UI**（原计划 Phase 2 track A）—— gitsigns 已有
  `:Gitsigns blame` / `Gitsigns toggle_signs` 等丰富命令，远端 status
  概览功能可以走 `:Gitsigns` builtin 或后续 fork neogit
- **stash / log / branch / rebase / commit 等高级写操作** —— P3+，可能
  通过 fork neogit 解决
- **docker 适配** —— Phase 4 独立工作

---

## 关键文件清单

### 新增（fork 内）
- `~/Code/Neovim/gitsigns.nvim/lua/gitsigns/backends.lua`

### 修改（fork 内）
- `~/Code/Neovim/gitsigns.nvim/lua/gitsigns/system.lua`
- `~/Code/Neovim/gitsigns.nvim/lua/gitsigns/attach.lua`
- `~/Code/Neovim/gitsigns.nvim/lua/gitsigns/git.lua`
- `~/Code/Neovim/gitsigns.nvim/lua/gitsigns/git/repo.lua`
- `~/Code/Neovim/gitsigns.nvim/lua/gitsigns/git/cmd.lua`

### 新增（zero-nvim 内）
- `lua/zero-nvim/gitsigns/backend.lua`

### 修改（zero-nvim 内）
- `lua/zero-nvim/init.lua` —— `M.setup()` 末尾调 `gitsigns.backend.setup()`

### 不动
- daemon Rust 代码（cmd 基座已够用）
- 其余 gitsigns 模块（manager / signs / hunks / actions / ...）
