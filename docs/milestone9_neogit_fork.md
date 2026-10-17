# zero.nvim 远程 git UI — neogit fork 适配方案

> 前置：Phase 0（cmd 基座）/ Phase 1（search 迁移）/ Phase 2（gitsigns fork
> backend：A 只读、B 写命令+blame、C 刷新触发器）已完成。
>
> 本文件设计 **Phase 3 / Milestone 9**：通过 fork neogit，复用其 magit 风格
> 状态/暂存/commit/rebase UI，把 git 进程执行层路由到 zero-nvim daemon。
> 路线与 gitsigns fork 对齐——backend 抽象 + zero-nvim 端注册具体 backend。

---

## 0. Implementation Status (snapshot)

- **Phase 3A — 只读 status / log / branch / diff**：✅ 落地。fork backends
  抽象（process / runner / cli / repository / watcher）+ zero-nvim 端
  `lua/zero-nvim/neogit/{backend,watcher}.lua` 已联调通过远端真仓库
  E2E。两条入口都通：
  - `:Neogit cwd=zero://u@h:p/path`（显式 cwd）
  - 在 `zero://` buffer 上直接 `:Neogit`（fallback 自动用 buffer 名）
- **Phase 3B — 暂存 / commit / push / pull**：✅ 落地（commit / merge /
  tag / push / pull / fetch）。daemon 端补了 `cmd_stdin_write` /
  `cmd_stdin_close` RPC + worker 在 poll 循环里做增量 stdin 写入；
  Lua `cmd.write_stdin` / `cmd.close_stdin` 暴露给 backend。fork 端
  `client.wrap_remote` 拦截 GIT_EDITOR 流：commit/merge/tag 用本地
  `RemoteCommitEditor`（基于 EditorBuffer + 本地 temp 文件）收消息，
  `git commit -F -` 走 stdin 推下去。push/pull/fetch 直接复用 pty 通路
  + runner 现有 username/password handler 通过 `process:send` →
  `handle.send` → `cmd_stdin_write` 把用户输入回写。
  - **不支持**：`rebase -i`（需 GIT_EDITOR 桥，留给 Phase 3C）；
    `commit --amend` 不带 `-m`（需要拉取现有消息预填，留给 3C）。
    两者都在 wrap_remote 里给明确 notification 拦下，不会让远端 git
    挂死等远端不存在的 editor。
- **Phase 3C — watcher 实时化 + GIT_EDITOR 桥**：⛔ 未开工。当前 watcher
  走 `BufWritePost / FocusGained` 触发，不连远端 inotify；rebase -i /
  amend-edit 仍未通。
- **底层 cmd 基座 perf 优化**：✅ daemon 端 per-target exec session 复用
  + 连接后台预热（commit `161e8e4`）。把 `:Neogit` 冷启动从 3s+ 压到
  ~1s 以内，不仅 neogit 受益，搜索 / gitsigns / docker 后续都共享。

---

## 1. Context

**目标**：在 `zero://user@host:port/path` 远程 buffer / cwd 下能直接跑 `:Neogit`
打开 magit 风格状态界面，stage / unstage / commit / push / pull / log / diff
等动作全部在远端执行；neogit UI 完全本地渲染，零移植成本。

**为什么 fork**（与 gitsigns 同理）：
- neogit 把 git 命令 *直接* 用 `vim.fn.jobstart` 在本机跑，硬编码了 cwd 是
  本地路径
- `cli.worktree_root` / `git_dir` / `is_inside_worktree` 这几个探测 git 仓库
  根目录的函数走 `vim.system(...)`：在远端 git 仓库的 `zero://` buffer 下
  跑这些函数会拿到本地 cwd 的 git 信息（甚至失败），不可能通过 monkey-patch
  在 lua 层干净拦截
- watcher 直接调 `vim.uv.new_fs_event()` 监听 `.git/`：远端文件系统监听只能
  fork 内部把入口换掉
- commit/rebase 编辑器流程靠 `GIT_EDITOR` 环境变量启动一个 headless nvim
  子进程：远端 git 起 editor 时，编辑器必须在远端能读写 `.git/COMMIT_EDITMSG`，
  原 client.lua 的方案不可用

**fork 维护**：
- 仓库放在 `~/Code/Neovim/neogit/`，平行于 zero.nvim 与 `~/Code/Neovim/gitsigns.nvim/`
- 分支 `zero-nvim-backend`，基于 upstream `master`
- backend 抽象做得通用 → 长期目标提 PR 给 upstream（非必需）
- zero-nvim 端只做注册 + 实现具体 backend 函数；**不**修改 fork 之外的 neogit 文件

---

## 2. 架构总览

### 两层切分

```
┌─ 数据/进程层（按 backend 替换） ──────────────────────────┐
│   process.lua / runner.lua — git 进程 spawn               │
│   cli.lua 探测函数 — worktree_root / git_dir / ...         │
│   watcher.lua — .git/ 文件系统监听                         │
│   client.lua — GIT_EDITOR 桥                              │
└─ UI / 业务层（不动） ────────────────────────────────────┘
    buffers/{status,commit_view,log_view,popup,editor,...}
    popups/* / lib/git/*（行为层不变，只改 spawn 路径）
```

### Backend 接口（在 fork 内新增）

新增 `lua/neogit/backends.lua`：

```lua
---@class Neogit.Backend
---@field id            string                                  -- "local" | "zero://u@h:p"
---@field pattern       string?                                 -- 匹配 cwd / file 的 lua 模式（可选）
---@field detect        fun(cwd: string): table?                -- → ctx 或 nil
---@field paths         fun(ctx): { worktree_root, git_dir, worktree_git_dir, is_inside_worktree }
---@field spawn         fun(opts: SpawnOpts, cb: SpawnCallbacks): SpawnHandle
---@field watch         fun(ctx, git_dir, on_event): unwatch_fn
---@field editor        fun(ctx, file_path, on_done)            -- COMMIT_EDITMSG / git-rebase-todo 桥

local M = {}
local registered = {}    -- 按注册顺序
local default_local      -- 永远兜底

function M.register(backend) ... end
function M.pick(cwd) ... end                  -- 返回 (backend, ctx) 或 (default_local, ...)
function M.set_default_local(backend) ... end
return M
```

`SpawnOpts` / `SpawnCallbacks` 与 neogit 现有 `Process:spawn()` 内部
`jobstart` 的接口对齐：

```lua
---@class SpawnOpts
---@field cmd     string[]
---@field cwd     string
---@field env     table<string,string>?
---@field pty     boolean?
---@field stdin   string?

---@class SpawnCallbacks
---@field on_stdout fun(_, lines: string[])    -- 与 jobstart 语义一致：增量 lines
---@field on_stderr fun(_, lines: string[])
---@field on_exit   fun(_, code: integer, signal?: integer)

---@class SpawnHandle
---@field send       fun(self, text: string)   -- stdin write
---@field close_stdin fun(self)
---@field stop       fun(self)                 -- 等价 jobstop
```

`SpawnHandle` 的好处：local backend 的 stop 直接 `fn.jobstop(job)`；
zero backend 的 stop 调 `cmd_cancel`，行为一致，runner.lua 不用区分。

---

## 3. 数据流（远程 buffer 打开 → :Neogit）

```
1. user 在 zero:// buffer 上 :Neogit
   或 user 设置 cwd 为 zero:// 后 :Neogit
2. neogit lib/git/repository.lua → 调 cli.worktree_root(cwd)
   a. backends.pick(cwd) → (zero_backend, ctx={target, path})
   b. backend.paths(ctx) 一次性返回 worktree_root / git_dir / ...
      （内部用 backend.spawn 跑 rev-parse，但对 cli.lua 来说是黑盒）
3. status buffer 打开 → repository:refresh()
4. refresh 调 lib/git/{status,branch,log,...}*.lua → 各自 cli.* call
5. cli call → runner.call(process, opts) → process:spawn_async(...)
6. Process:spawn() 内：
   if self.backend then
       self.handle = self.backend.spawn({cmd=self.cmd, cwd=..., env=...},
                                        {on_stdout=..., on_stderr=..., on_exit=...})
   else
       self.handle = jobstart(...)
   end
7. zero_backend.spawn 把 SpawnOpts 转成 cmd.stream 调 daemon
   → daemon 在远端跑 git → 流式 stdout/stderr 通过 cmd.stream 回到本地
   → on_stdout(lines) 喂给 neogit 现有的 ProcessResult 累积逻辑
8. on_exit 触发 → neogit refresh 数据 → status buffer 重绘
```

### 关键点

- **runner.call / Process:spawn 仍然是 sync 风格**（被 plenary.async coroutine
  包起来）：jobstart 异步 → on_exit 回调 → coroutine resume。zero backend
  把 cmd.stream 的 on_exit 接到同一回调上即可，行为等价
- **path 翻译只在 detect 一次**：cwd 解析出 ctx，从此 git 命令的 cwd / 文件
  路径全用远端绝对路径
- **PATH 注入**：和 gitsigns backend 一致——`opts.env` 自动加上
  `/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:...` 前缀，远端 sh
  非交互 shell 才能找到 git

---

## 4. 跨模块数据传输机制

### 4.1 异步包装：cmd.stream → SpawnCallbacks

```lua
function Backend.spawn(opts, cb)
    local stdin_buf = ""           -- 在 on_event 之前用户调 send 的 stdin 累积
    local handle = {}

    local stream_h, err = require("zero-nvim.cmd").stream(ctx.target, {
        argv = wrap_with_path(opts.cmd),
        cwd = opts.cwd,
        env = env_to_pairs(opts.env),
        stdin = opts.stdin,            -- 一次性 stdin（commit -F、apply --cached 等）
        pty = opts.pty,                -- daemon 端可走 pty 模式（cmd.stream 已支持）
    }, {
        on_event = function(ev)
            if ev.kind == "stdout" then
                cb.on_stdout(nil, split_lines(ev.text))
            elseif ev.kind == "stderr" then
                cb.on_stderr(nil, split_lines(ev.text))
            end
        end,
        on_exit = function(code, signal, reason, _dur)
            cb.on_exit(nil,
                reason and -1 or (code or 0),
                signal or 0)
        end,
    })

    handle.send = function(_, text)
        require("zero-nvim.cmd").write_stdin(stream_h, text)   -- 见下文 4.2
    end
    handle.close_stdin = function(_) require("zero-nvim.cmd").close_stdin(stream_h) end
    handle.stop = function(_) require("zero-nvim.cmd").cancel(stream_h) end
    return handle
end
```

### 4.2 stdin 增量写入：daemon 侧已落地（Phase 3B）

neogit 的 `Process:send(text)` 是 *jobstart 后* 任意时刻往 stdin 写字节，
比如 runner.lua 的 interactive 处理（`process:send(value .. "\r\n")`）。
gitsigns 没用到这个能力——它只 `opts.stdin` 一次性传 patch。

**daemon 侧 Phase 3B 落地的 RPC**：
- `cmd_stdin_write [session_id, data]` — 往 stream 的 stdin 写字节
- `cmd_stdin_close [session_id]` — 通知 worker 把 stdin 关掉（send_eof）

实现要点：
- `CmdHandle` 增加 `stdin_tx: Mutex<Option<mpsc::Sender<StdinMsg>>>`，
  worker 启动时填上 sender，rx 进 `run_inner`。
- `exec_stream.rs` 主 poll 循环每次 iteration 排空 stdin queue，把
  pending 字节按 chunk 写到 channel（non-blocking write，
  EAGAIN 不阻塞 stdout 读取）；写完队列且收到 close 标志后才 send_eof。
- spec.stdin 仍然作为快路径保留：caller 一次性传完会立刻
  write_all + send_eof（`git apply --cached -p2 -` 等），不进 queue。
- Lua 层：`cmd.write_stdin(sid, data)` / `cmd.close_stdin(sid)` 都是
  rpcnotify（不阻塞主线程）。`backend.lua` 的 SpawnHandle.send /
  close_stdin 直接转发；spawn 期间 real_sid 还没就绪时把消息缓存到
  `stdin_queue`，real_sid 一出来就 flush。

### 4.3 PTY 模式（Phase 3B 已通）

neogit 用 `pty=true` 主要是为了 git 的 ANSI 颜色 + `Username for ...` /
`Password for ...` 这类 prompt 走 stderr 的特殊缓冲。

实现：daemon 端 `RemoteCommand.pty` 字段早期就预留好了；exec_stream
建 channel 后看到 `cmd.pty` 就 `channel.request_pty("xterm-256color",
None, None)`。Phase 3B 验证 push / pull / fetch 的 username/password
prompt：runner.lua 的 `handle_line_interactive` 走 `process:send`
推回输入 → backend 的 `handle.send` → `cmd.write_stdin` →
worker 排队写 channel。username + `\r\n` 入 stdin → git 继续 →
push 完成。

PTY 模式下 stdout/stderr 合并成单流（libssh2 行为，与 nvim jobstart
pty=true 一致）；neogit on_partial_line 走的就是单流，无需额外适配。

### 4.4 watcher

复用 Phase 2C 的 `gitsigns/refresh.lua` 思路：

```lua
-- lua/zero-nvim/neogit/watcher.lua
function M.watch(ctx, git_dir, on_event)
    -- 简单方案：autocmd 触发 + 可选轮询
    -- BufWritePost / FocusGained → schedule on_event("HEAD")
    -- poll_ms > 0 → uv.timer 定时跑
    -- 不区分 fs_event 的 events 类型——neogit 拿到 callback 就 refresh，等价
end

function M.unwatch(unwatch_fn) ... end
```

进阶（**Phase 3C**）：`cmd_stream` 跑远端 `inotifywait -m -q -e modify,create
.git/` 长流式命令，每个 stdout 行就是一次事件，daemon 推回本地 → 真实时
监听。前提：远端有 inotify-tools（Linux）或 `fswatch`（macOS）。
没有则降级到 Phase 3A 的轮询方案。

### 4.5 GIT_EDITOR 桥（最难一块）

#### 流程拆解

neogit 现有流程（client.lua）：
```
1. neogit 把 GIT_EDITOR env 设成
     "$NVIM_PATH --headless --clean -R -c <runtimepath> -c <lua>"
2. git commit / git rebase -i 在子进程里调 GIT_EDITOR <file>
3. headless nvim 启动 → 调 client.client(opts)
   → fn.serverstart() 起一个 RPC server
   → 通过 NVIM env 找到父 nvim → rpc 让父 nvim 调 client.editor(target, child_addr, ...)
4. 父 nvim 打开 editor buffer，user 编辑 → :wq
5. on_unload 通过 child_addr rpc 回调 → headless nvim qall
6. git 看到 editor 退出码 0 → 继续 commit
```

#### 远端化要解决的问题

git 跑在远端 → 远端拉起的 GIT_EDITOR 必须能：
- 拿到 `.git/COMMIT_EDITMSG`（远端绝对路径）
- 让本地 nvim 编辑
- 等本地 nvim 保存 + 关闭后才退出
- 退出码反映用户是否取消

#### 方案：daemon 端反向 channel

```
远端 git
   └─ exec $GIT_EDITOR /repo/.git/COMMIT_EDITMSG
       │
       │  GIT_EDITOR = "$ZERO_HOME/zero-editor.sh /repo/.git/COMMIT_EDITMSG"
       │  zero-editor.sh 用法：往一个预先挂好的 named pipe / unix socket
       │  写 "EDIT <file>"，然后 read 等回应
       │
       └─ FIFO /tmp/zero-editor-<sid>.sock
              │
              │ daemon 远端启动 git 时已经在同一 ssh session 后台开了
              │ tail -f 或一个常驻 reader（cmd_stream 二号子任务）
              │
              ↓
         daemon stdout 流回本地 → on_event("editor", file=...)
              ↓
   本地 zero-nvim：sftp 把 file 拖到本地缓冲（用 zero:// URI 直接打开）
              ↓
   交给 neogit.buffers.editor 渲染（fork 把 client.editor 的 RPC 拼接
   换成本地直接 require）
              ↓
   user :wq → on_unload(0) → zero-nvim 调 daemon 把 buffer 内容写回 .git/COMMIT_EDITMSG
                         → daemon 往 fifo 写 "DONE 0"
                         → 远端 zero-editor.sh read 到 → exit 0
                         → git 继续
```

#### 简化版（**Phase 3B 用这个**）

不做 fifo / sideband，直接 **绕过 GIT_EDITOR**：

- 拦截 `git commit` 调用：fork 内的 commit popup 已经在本地 buffer 里收
  集 message → 改成 `git commit -F <upload-path>` 而不是 `git commit -e`
- `git commit -F -` 走 stdin 更省事：把 message 放 `opts.stdin`
- `merge --edit` 同理：消息已经在本地 popup 里
- `tag -m <msg>` / `commit --amend -m <msg>` 直接走 args

**只解决不了**：
- `git rebase -i`（rebase-todo 编辑）
- `git commit --amend` 不带 `-m`（要看现有 message 编辑）

→ Phase 3B 的范围里，**rebase 交互模式不支持**（用户提示 + popup
guard），其余 commit / merge / tag 全部能走。Phase 3C 再补 fifo 桥
让 rebase / `commit --amend` 可用。

#### Phase 3C 的 fifo 桥实现

- daemon 新增 RPC `editor_session_open { target, sid } → { fifo_path }`：
  在远端 mktemp + mkfifo
- daemon 把 sid → fifo_path 记到 state；同时启动一个后台
  cmd.stream 跑 `cat $fifo_path`（独占 ssh session），stdout 回到本地
- 跑 git 时把 `GIT_EDITOR=zero-editor.sh` 注入 env，`zero-editor.sh`
  shell 实现：
  ```sh
  #!/bin/sh
  echo "EDIT $1" >> $ZERO_FIFO
  read line < $ZERO_FIFO_REPLY      # 阻塞读
  case "$line" in DONE\ 0) exit 0;; *) exit 1;; esac
  ```
- daemon 拿 stdout `EDIT <file>` → notification → 本地 zero-nvim 把
  file 拉下来打开 buffer → :wq 时回写 + RPC `editor_session_reply
  { sid, status }` → daemon 往 reply fifo 写 `DONE 0`

实现挺多但也都是 SSH + FIFO 的常规活，可控。

---

## 5. Fork 内部需修改的文件（neogit）

| 文件 | 改动 | 改动量 |
|---|---|---|
| `lua/neogit/backends.lua` | **新增** registry + default_local | ~60 行 |
| `lua/neogit/process.lua` | `Process.new` 增 `backend, ctx` 字段；`Process:spawn()` 走 backend.spawn 分支；`stop / send / close_stdin` 走 SpawnHandle | ~40 行 |
| `lua/neogit/runner.lua` | 把 `process.cwd` 解析后选 backend 注入到 process（或 caller 已注入则直通）；interactive prompt 路径不变（pty 走 backend） | ~10 行 |
| `lua/neogit/lib/git/cli.lua` | `worktree_root` / `git_dir` / `worktree_git_dir` / `is_inside_worktree` 改成 `backend.paths(ctx)` 一次拿全部；获取 git executable 时考虑远端没有 alias | ~30 行 |
| `lua/neogit/lib/git/repository.lua` | `Repo.new(...)` 接受 backend/ctx，并存到实例；`repo_cache` 键加 `backend.id ":"` 前缀（同 gitsigns repo_cache） | ~25 行 |
| `lua/neogit/watcher.lua` | `Watcher.new(root)` 拿 backend.watch 替代 `vim.uv.new_fs_event`；远端 backend 的实现挂回 `dispatch_refresh` | ~30 行 |
| `lua/neogit/client.lua` | `get_envs_git_editor` 在 backend 是 zero 时换成 `zero-editor.sh`；`client.editor` 这个 headless-nvim 入口在远端用不到，但 fork 仍保留本地路径 | ~25 行 |

**总计 fork diff ~220 行**，集中在 7 个文件。比 gitsigns（150 行 / 6 文件）
略多——主要因为多了 watcher 和 GIT_EDITOR 桥。

### 核心 fork 修改点 — process.lua:Spawn

```lua
function Process:spawn(cb)
    -- ...原有 res / on_stdout / on_stderr / on_exit 构造...

    if self.backend and self.backend ~= backends.default_local then
        self.handle = self.backend.spawn({
            cmd = self.cmd, cwd = self.cwd, env = self.env, pty = self.pty,
            stdin = self.input,
        }, {
            on_stdout = on_stdout,
            on_stderr = on_stderr,
            on_exit = on_exit,
        })
        if not self.handle then
            error("Failed to start remote process: " .. vim.inspect(self))
            return false
        end
        processes[self.handle.id] = self     -- 用 handle.id 而非 jobid
        self.job  = self.handle.id           -- alias，让旧代码 jobwait/jobstop 调 handle.stop
        self.stdin = self.handle              -- send 走 handle:send
    else
        local job = fn.jobstart(self.cmd, { ... })  -- 原代码不变
        ...
    end
    return true
end

function Process:send(data)
    if self.handle then
        self.handle:send(data)
    else
        api.nvim_chan_send(self.stdin, data)
    end
end

function Process:stop()
    if self.handle then
        self.handle:stop()
    else
        assert(fn.jobstop(self.job) == 1, "invalid job id")
    end
end
```

### 核心 fork 修改点 — cli.lua 路径探测

```lua
-- 原 4 个独立 vim.system 函数合并：
local function probe_paths(backend, ctx, dir)
    if backend ~= default_local then
        return backend.paths(ctx, dir)
    end
    -- 本地路径不变：4 次 vim.system
    return {
        worktree_root      = ...,
        git_dir            = ...,
        worktree_git_dir   = ...,
        is_inside_worktree = ...,
    }
end
```

zero backend 的 `paths()` 在远端 *单次* `cmd_sync` 跑：
```sh
git -C $dir rev-parse --show-toplevel --git-common-dir --git-dir --is-inside-work-tree
```
然后 split 成 4 行——一次 SSH RTT 拿到全部，比本地的 4 次 vim.system 更快。

---

## 6. zero-nvim 端

### 新增文件 `lua/zero-nvim/neogit/backend.lua`

骨架（Phase 3A 完成，Phase 3B/3C 补充 editor）：

```lua
local M = {}

local REMOTE_PATH_PREFIX =
    "/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:/home/linuxbrew/.linuxbrew/bin"

local function wrap_with_path(argv)
    local wrapped = { "sh", "-c",
        ('PATH="%s:$PATH" exec "$@"'):format(REMOTE_PATH_PREFIX), "--" }
    for _, a in ipairs(argv) do wrapped[#wrapped + 1] = a end
    return wrapped
end

function M.id_for(target)
    return ("zero://%s@%s:%d"):format(target.user, target.host, target.port or 22)
end

function M.detect(cwd)
    -- cwd 可能是 zero:// URI 或 zero-nvim 设的远端 cwd
    local user, host, port, path = require("zero-nvim.uri").parse(cwd)
    if not user then return nil end
    return {
        target = { user = user, host = host, port = port },
        path = path,
        id = M.id_for({ user = user, host = host, port = port }),
    }
end

function M.paths(ctx, dir)
    local cmd = require("zero-nvim.cmd")
    local res, err = cmd.sync(ctx.target, {
        argv = wrap_with_path({ "git", "-C", dir or ctx.path,
            "rev-parse", "--show-toplevel", "--git-common-dir",
            "--git-dir", "--is-inside-work-tree" }),
    })
    if err or res.code ~= 0 then return nil, err or res.stderr end
    local lines = vim.split(res.stdout, "\n", { trimempty = true })
    return {
        worktree_root      = lines[1],
        git_dir            = lines[2],
        worktree_git_dir   = lines[3],
        is_inside_worktree = lines[4] == "true",
    }
end

function M.spawn(opts, cb)
    -- 见 §4.1 实现，Phase 3A 范围
end

function M.watch(ctx, git_dir, on_event)
    -- Phase 3A：refresh.lua 模式（autocmd + 可选 poll）
    -- Phase 3C：换成 cmd.stream 跑 inotifywait
    return require("zero-nvim.neogit.watcher").start(ctx, git_dir, on_event)
end

function M.editor(ctx, file_path, on_done)
    -- Phase 3B：不走这个；neogit fork 的 commit popup 改用 stdin 传 message
    -- Phase 3C：fifo 桥实现
    error("editor bridge not implemented yet")
end

function M.setup()
    local ok, backends = pcall(require, "neogit.backends")
    if not ok then return end
    backends.register({
        id      = "zero",
        pattern = "^zero://",
        detect  = M.detect,
        paths   = M.paths,
        spawn   = M.spawn,
        watch   = M.watch,
        editor  = M.editor,
    })
end

return M
```

### 修改 `lua/zero-nvim/init.lua`

`M.setup()` 末尾加：
```lua
require("zero-nvim.neogit.backend").setup()
```

### 复用现有
- `lua/zero-nvim/uri.lua` — URI 解析
- `lua/zero-nvim/cmd/init.lua` — `cmd.stream` / `cmd.sync` API
- `lua/zero-nvim/gitsigns/refresh.lua` 的设计模式 → 复制成 `neogit/watcher.lua`

### 不用动的
- daemon 现有 RPC 大部分够用
- gitsigns fork（独立维护，互不干扰）

### daemon 端待补
- **Phase 3B**：`cmd_stdin_write` / `cmd_stdin_close` RPC（§4.2）
- **Phase 3B**：`cmd_stream` 接受 `pty: bool`，对应 libssh2 request_pty（§4.3）
- **Phase 3C**：`editor_session_open / reply` RPC（§4.5）

### Phase 3A 已落地的 daemon 改动（不在原计划但必须做）
- `cmd/dispatch.rs` 的 `handle_cmd_sync` 和 `cmd_stream` sink 把
  stdout/stderr 由 `Value::Binary` 改成 `Value::String(from_utf8_lossy)`：
  详情见 §6.5 第 1 条。
- `connect.rs` + `state.rs` 加 per-target exec session 复用 + 后台预热
  （commit `161e8e4`）：见 §10。

---

## 6.5 Phase 3A 实施踩坑 / Gotchas

实施 Phase 3A 时遇到的几个非显然问题。下次重写 backend 或扩展 Phase 3B/3C
前先看这一节，能省下重复 debug 的时间。

### 1. msgpack-rpc bin → vim.Blob (userdata)，触发 E976

daemon 把 stdout 当 `rmpv::Value::Binary` 回传，nvim **内置** msgpack-rpc
解码会把 bin 解成 `vim.Blob`（userdata），`type() == "userdata"`，喂给
`vim.fn.fnamemodify` / `vim.fn.expand` 立刻 `E976: Using a Blob as a String`。
（注意 `vim.mpack` Lua 模块行为不同，它解出来是普通 Lua string——这俩
不是同一个解码器，出现解码不对称。）

修复：daemon 改成 `Value::String(String::from_utf8_lossy(bytes).into_owned())`
直接发 string；同时 lua 侧 `coerce_to_string` 留作兜底（旧 daemon
binary 兼容 + 任何意料之外的 Blob 输入都能再压成 string）。

### 2. Lua pattern 里 `\0` ≠ 字面 NUL，必须用 `%z`

`git status -z`、`ls-files -z`、`config --null` 都用 NUL 分隔记录。
nvim 的 `jobstart` 在 on_stdout 转给 lua callback 之前**会**自动把 NUL
转 LF；我们 backend 直接拿 raw 字节，必须自己做这一步以保持兼容。

写法 1（错）：`s:gsub("\0", "\n")` —— Lua pattern 把 `\0` 当成"任意
字符"通配（与 `.` 等价），结果在每个字符前插一个 LF，split 出字符级
而非 record 级。

写法 2（对）：`s:gsub("%z", "\n")` —— `%z` 是 Lua pattern 的"字面
NUL"。`backend.lua:split_lines` 用的就是这个。

### 3. `vim.fs.normalize` 把 `zero://` 折成 `zero:/`

neogit 的 repository / watcher 在拿到 cwd 时调 `vim.fs.normalize` 规整
分隔符，副作用是连续 `//` 折成单 `/`，URI scheme `zero://u@h:p/...`
就坏了。

修复：fork 内 `lib/git/repository.lua` 和 `watcher.lua` 在 cwd 匹配
`^%w+://` 时直接跳过 normalize。

### 4. `lcd <remote_path>` 在本地不存在 → E472

neogit 的 status buffer 启动时会 `lcd config.cwd`。本地不存在该路径
时 `lcd` 直接报 E472。

修复：fork 内 `lib/buffer.lua` 加 `vim.fn.isdirectory(config.cwd) == 0`
guard 跳过 lcd——neogit 内部所有 git 调用都通过 backend.spawn 的
`opts.cwd` 传到远端，根本不依赖窗口 lcd。

### 5. 并发开 SSH session → "Invalid channel: 4" / daemon 不稳

neogit `:refresh` 一次能并发触发 5+ git 命令。每条 cmd.stream 都让
daemon 端 `open_dedicated_session` 起新 SSH session。并发开 5+ TCP +
SSH handshake + ssh-agent 协商，要么打满远端 sshd `MaxSessions=10`，
要么 libssh2 内部某条非线程安全路径炸 daemon。

修复（双层）：
- Lua 层：`backend.lua:target_gates` per-target 序列化闸门，同一远端
  最多 1 条 cmd.stream 在跑，其他排队。
- Daemon 层：`exec_sessions: HashMap<String, Arc<Mutex<Session>>>` 缓存
  per-target 复用 session（commit `161e8e4`）。后续命令只开新 channel
  不开新 session，并发开 channel 在同一 mutex 下天然串行化。

### 6. handle.id 必须从一开始就非 nil

fork 的 `process.lua:Spawn` 拿到 SpawnHandle 后立刻
`processes[handle.id] = self`。如果我们在异步排队期间留 `handle.id =
nil`，等队列释放后再填真实 sid，那 `processes[nil] = self` 直接
`table index is nil`。

修复：`gen_handle_id()` 给 handle 立刻分配占位 string `"zero-handle-N"`，
真实 cmd.stream sid 启动后存到 closure 变量 `real_sid`，cancel 时优先
取 `real_sid`，否则置 `cancelled` flag 让队列里的 `actually_spawn`
看到时直接给 on_exit 一个 aborted。

### 7. `cli.probe_paths`：3 次串行 cmd.sync 让 :Neogit 卡住

原计划 cli.lua 用 4 个独立 `vim.system` 调用，fork 改成调 `backend.paths`。
最初实现把 `worktree_root / git_dir / worktree_git_dir / is_inside_worktree`
拆成 3-4 个独立 backend.paths 调用 → 3-4 次 `cmd.sync` 串行 RPC →
`:Neogit` 启动卡几秒。

修复：fork 内 `cli.probe_paths(dir, backend, ctx)` 一次拿全部 4 个字段；
`Repo.new` 调一次。zero backend 的 `M.paths` 内部就只跑一条
`rev-parse --show-toplevel --git-common-dir --git-dir --is-inside-work-tree`，
单次 SSH RTT 全拿到。

### 8. `:Neogit`（不带 cwd）从 `zero://` buffer 触发时打开错的本地仓库

upstream `construct_opts` 的 fallback 是 `vim.uv.cwd()`——本地路径，完全
忽略当前 buffer 名。用户在 `zero://u@h:p/repo/sub/file.cpp` 上跑
`:Neogit` 会落到本地仓库甚至 "not a git repository"。

修复（fork `lua/neogit.lua:construct_opts`）：fallback 时先看当前 buffer 名，
如果匹配 `^%w+://` 且 `backends.pick(bufname)` 命中（即有注册的远端 backend
认领），就把 bufname 当 cwd_guess。

### 9. URI cwd 经 `worktree_root` 转换会丢失 scheme

construct_opts 的旧逻辑：拿到 cwd_guess 后调 `git.cli.worktree_root(cwd_guess,
backend, ctx)` 把 `cwd_guess` 转成 worktree 根。本地 backend 返回纯路径
（`/local/repo`），URI backend 也返回纯**远端**路径（`/repo`）——scheme
丢了。下游 `M.open` 再 `backends.pick(opts.cwd)`，pattern `^zero://` 命中
不上，落回 default_local（实际是 nil），开错仓库。

修复：URI 形式的 cwd_guess **不**经 worktree_root 转换，直接 `opts.cwd =
cwd_guess`。`Repo.instance(uri)` 内部会走 `backend.paths` 拿到真实
worktree_root 存到 repo 实例上，UI 用的也是那个；opts.cwd 只是入口
路由 key，保留 URI 才能让所有 `backends.pick(opts.cwd)` 正确命中。

### 10. `buffers/status/init.lua` 还有两处 `vim.fs.normalize` 没 patch

第一轮只改了 `M.new` 里的一处，结果 `M.register / M.instance` 仍用
normalize 后的 key，URI 一进 register 就被折成 `zero:/u@h:p/repo`，
之后 `M.instance(uri)` lookup 又用未折叠的 URI → 永远找不到，重复
开 status buffer 实例。

修复：抽出 `normalize_dir(dir)` helper（URI 跳 normalize），register /
instance / new 三处统一走它，key 一致。

### 11. URI buffer 是 *文件* 路径，`git -C $file` fatal "Not a directory"

bufname 通常是 `zero://u@h:p/repo/sub/file.cpp`，M.paths 把 path 部分
原样喂 `git -C`。git 要求 `-C` 后面是目录，传文件直接 fatal 退出。

修复（zero-nvim 端 M.paths）：shell 探针
```sh
d="$1"; [ -d "$d" ] || d="$(dirname "$d")"
exec git -C "$d" rev-parse ...
```
file/dir 两种入口都自动落到正确的目录，单 SSH RTT 不变。

### 12. process.lua 在 spawn 后立刻 `self:send(self.input)`，不能再传 spec.stdin

fork 的 `process.lua:Process:spawn` 在拿到 SpawnHandle 后会显式跑：
```lua
if self.input then
  self:send(self.input)
  -- ...
  self:close_stdin()
end
```
也就是说 stdin 数据是通过 SpawnHandle.send/close_stdin 推下去的。

我们在 backend.lua 里如果**同时**把 `stdin = opts.stdin` 也塞给
`cmd.stream`，daemon 会先一次性 `write_all + send_eof` 把数据写下去
（spec.stdin 快路径），然后 SpawnHandle.send 又通过 cmd_stdin_write
推一遍——同一份 message 被 git 看两次，commit message 里出现重复内容。

修复：backend.lua 的 `cmd.stream` 调用**不**传 `stdin = opts.stdin`，
完全依赖 handle.send/close_stdin 这条增量路径。spec.stdin 仅留给不
通过 SpawnHandle 走的 caller（如 cmd.sync 的 git apply --cached）。

### 13. `cmd.to_process({})` 仅构造、不 spawn — 适合 inspect 只读 argv

fork 的 `client.wrap_remote` 需要在 spawn 之前判断 cmd 的 subcommand
（commit / merge / rebase 等）以及 argv 里有没有 `-m` / `--no-edit`
这类 skip-editor 标志。cli builder 的 `state` 是 closure-bound 私有
（key 是 local symbol `k_state`），外部拿不到。

绕过：调 `cmd.to_process({on_error=fn, hidden=true, long=false})` 拿到
新构造的 Process（不 spawn，纯构造）。Process.cmd 是完整 argv 数组，
可直接扫描。后续真正调 `cmd.call(...)` 会再触发一次 to_process（state
共享），不影响。

注意：扫 argv 时遇到 `-c key=val` 这类要消耗两个 token 的全局选项，
要把 `key=val` 一起跳过——否则 `core.preloadindex=true` 会被当成
subcommand。`-C dir` 同理。

### 14. EditorBuffer 默认 `load=true` 会 Path:readlines —— 远端路径炸

`Buffer.create { name = filename, load = true }` 走 `Path:new(filename):
readlines()` 加载**本地**文件内容。远端 commit-msg 直接传
`/remote/.git/COMMIT_EDITMSG` 会让 plenary 报 ENOENT 然后 EditorBuffer
卡住。

修复（fork `buffers/remote_commit_editor.lua`）：用本地 cache 目录
mktemp 一份 `.gitcommit` 文件，预先 `vim.fn.writefile(initial_lines)`
把模板（注释行）落盘，让 `load=true` 顺利读到。用户保存（Submit）后
EditorBuffer 内部 `buffer:write()` 把 message 写回同一文件，我们在
`on_unload` 回调里 `vim.fn.readfile` 读出来 + 剥掉 `^#` 注释行 → 拿
干净 message 喂 `cmd.args("-F","-").input(message)`。

---

## 7. 分阶段交付

### Phase 3A — 只读状态 + diff 浏览（约 3 天）

**目标**：远端 cwd 下 `:Neogit` 打开状态界面，能看到 unstaged / staged
hunks，能 diff 浏览 / log / branch 列表。所有"读"操作 work，不动文件。

**实现范围**：
- daemon 补 `cmd_stdin_write` / `cmd_stdin_close` / `pty` 参数
- fork neogit + 实现 backends 抽象（process.lua / runner.lua / cli.lua /
  repository.lua / watcher.lua）
- zero-nvim 端 backend.lua（detect / paths / spawn / watch — 用
  refresh.lua 模式，不上 inotifywait）
- watcher 简化为：BufEnter / BufWritePost / FocusGained 时若 status buffer
  存在则 dispatch_refresh

**验收**：
1. 本地 git repo `:Neogit` 行为零变化（regression）
2. 在 zero:// buffer 下 `:Neogit`，3-5 秒内出现远端 status
3. 状态 buffer 跳转到 hunk → `<Tab>` 展开 diff，正常显示
4. `:Neogit log` / `:Neogit branch` UI 正常
5. 同时打开本地仓库和远端仓库的 Neogit buffer（两个不同 status）
   互不干扰
6. 关闭 status buffer 后 `pgrep -f 'git status'` 远端无残留

### Phase 3B — 暂存 + commit + push/pull（约 2 天）

**目标**：`s` stage / `u` unstage / `c c` commit / `P p` push / `F u` fetch
等核心写命令工作。**rebase -i 不支持，commit --amend 不带 -m 不支持。**

**实现范围**：
- 验证 stdin 通路（stage_hunk 走 patch via stdin）
- 验证 pty 通路（push 时的 username/password prompt 用 runner.lua 现有
  interactive 路径，stdin 写回，cmd_stdin_write 落地）
- fork neogit 的 commit popup 修改：`git commit -F -` + stdin 传消息，
  绕过 GIT_EDITOR；rebase / amend-edit 触发时给 popup guard 提示
  "remote backend 暂不支持，请用 :Neogit commit --message"

**验收**：
1. 在远端 status 上 `s` stage 一个 hunk → `git diff --cached` 远端确认
2. `u` unstage 还原
3. `c c` 弹出 commit popup → 写消息 → `<C-c><C-c>` 提交成功，远端
   `git log -1` 看到新 commit，author 是远端 git config 的 user
4. `P p` push 到 origin（私钥需远端有，否则跳过）
5. fatal error / username prompt 时 UI 弹出输入框，回传给远端 git stdin

### Phase 3C — watcher 实时化 + editor 桥（约 2 天）

**目标**：实时 watcher（inotifywait/fswatch）+ rebase/amend-edit 通过
fifo 桥可用。

**实现范围**：
- daemon `editor_session_open / reply` RPC + `zero-editor.sh` 部署到
  `~/.zero-nvim/bin/zero-editor.sh`（首次连接时 sftp 上传）
- 远端 watcher 用 cmd.stream 跑 inotifywait（Linux）/ fswatch（macOS），
  自动探测；探测失败降级到 3A 的轮询
- backend.editor 实现：notification → fetch file → 打开 zero://
  buffer → :wq 后回写 + reply

**验收**：
1. 远端 `git pull` 改了 HEAD → 本地 status buffer 在 1s 内自动刷新（不
   靠用户 :w 触发）
2. `c a` (amend) 不带 -m → 弹出 editor，原 message 显示在本地 buffer，
   编辑后保存 → 远端 commit 成功
3. `r i` rebase -i → todo list buffer 在本地，编辑后保存 → 远端 rebase
   按 todo 执行

---

## 8. 验证策略

### Phase 3A 烟雾测试
```vim
:cd zero://u@h:22/some/repo
:Neogit
" 等 3-5 秒，status 出现：unstaged / untracked / branch info

" 在另一个分裂窗口下：
:edit zero://u@h:22/some/repo/file.lua
" 改一行，:w
" status buffer 在 1s 内（FocusGained 触发）显示新 hunk

" 远端 ssh u@h "pgrep -f 'git'" → 应该没有残留
```

### Phase 3A 性能基线（实测，加完 §10 perf 优化后）
- :Neogit 冷启动端到端 < 1.5s（首条 cmd.stream 命中预热好的 exec session，
  后续 5+ 条命令复用，每条只付 channel_session ≈ 40ms）
- refresh < 800ms（session 已热，纯 channel + git runtime）

> 注：未做 §10 perf 优化（commit `161e8e4`）前实测冷启动 3s+，瓶颈是
> 每条 cmd.stream 都重新做 SSH 握手（200-500ms × 6 命令）。

### Phase 3A regression
- 本地 `:Neogit` 行为完全等价于 upstream
- 跑 neogit 自带 test suite（fork 保持原测试通过）

### Phase 3B 验证
- stage/unstage：`Gitsigns refresh` 之后 sign 也对应变化（gitsigns +
  neogit 共用 daemon 不互斥）
- commit：远端 `git log -1 --format='%an %ae %s'` 验证 author
  和 message 完整
- push：远端 fork 的 dummy 仓库验证

### Phase 3C 验证
- watcher：远端 shell 跑 `git checkout some-branch` → 本地 status
  buffer 在 1s 内显示新 branch
- editor：rebase-i 把 commit 顺序换一下，远端 git log --oneline
  确认重排

---

## 9. 风险与对策

| 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|
| backend 抽象边界没找准 | 中 | Phase 3A 拖延 | 先实现到本地 backend → 跑通 regression → 再上 zero backend |
| neogit upstream 频繁改 process/cli | 中 | rebase 痛苦 | 改动收敛在 backends.lua + 7 个文件薄分支；rebase 失败优先 cherry-pick backends.lua |
| pty 模式下 stderr 进 stdout 让 ProcessResult.stderr 永远空 | 中 | runner 的 fatal-error 检测失效 | 跟随 neogit 现状：pty=true 时只看 stdout 的 "fatal:" 行；不依赖 stderr |
| daemon stdin 增量写并发问题（多 buffer 同时 commit） | 低 | 写错对应 channel | cmd_stdin_write 用 handle 路由，每条 cmd_stream 独立 session 天然隔离 |
| inotifywait/fswatch 远端没装 | 中 | watcher 实时降级 | Phase 3C 自动探测；都没就退回 3A 的轮询，不影响正确性 |
| `zero-editor.sh` 首次连接上传失败 | 低 | rebase/amend 不可用 | 启动时检测 + 失败给 notification + 用 lazy upload；默认 message-only commit 仍可用 |
| 用户混用 `cd zero://...` 和本地 cwd | 中 | backend pick 不准 | detect 优先匹配 cwd；Status buffer 启动时记录 backend，refresh 时复用 |
| daemon SSH session 数被打满（status 一次开 5+ 命令） | 中 | 部分命令排队 | gitsigns 已经在用同 daemon；neogit 新增 4-6 条/refresh，session pool 上限调到 16 |
| upstream 不接受 backends 抽象 | 高 | 永久 fork | 接受；改动小、rebase 友好 |

---

## 10. 与 gitsigns fork 的协同

zero-nvim 用户同时启用 gitsigns + neogit fork：

- 共用 daemon 进程、共用 SSH 连接池（Phase 0 已设计）
- 共用 PATH 注入策略（两个 backend 字面上都是同一个 wrap_with_path）
- 共用 watcher 思路（refresh.lua / neogit/watcher.lua 是同模板）
- **不冲突**：gitsigns 关心 buffer 的 hunks，neogit 关心整个 repo 的
  status；refresh 都靠 daemon 跑 git，互不踩

zero-nvim init.lua setup 顺序：
```lua
require("zero-nvim.gitsigns.backend").setup(opts.gitsigns)
require("zero-nvim.neogit.backend").setup(opts.neogit)
```

两个 backend 各自 pcall require fork 模块，没装就静默退出——本地不装
gitsigns/neogit 也不会报错。

### 共用 daemon cmd 基座的 perf 改进（commit `161e8e4`）

neogit 一次 refresh 触发 6+ 条 git 命令，原 cmd.stream 实现每条都通过
`open_dedicated_session` 起新 SSH 会话（TCP + 协议握手 + 认证 ≈
200-500ms）。优化分两步：

1. **per-target exec session 复用**：`DaemonState.exec_sessions:
   HashMap<String, Arc<Mutex<Session>>>` 缓存每个远端的复用 session。
   `borrow_exec_session` 惰性建好后所有 cmd.stream 共用，握手只付一次；
   后续命令仅做轻量 `channel_session()` 协商。session-dead 错误（broken
   pipe / -43 / -49）时自动 drop 缓存，下条命令重建。

2. **连接后台预热**：`handle_connect` 完成 SFTP 会话建立后，spawn 后台
   线程跑 `borrow_exec_session`，让用户首条 cmd.stream（典型场景：
   `:ZeroProject open` 后立刻 `:Neogit`）直接命中已建好的 session，
   省下首次握手 ≈ 400ms。

收益对 neogit 最直观（多命令场景），但 gitsigns、search、未来 docker
适配都共享这层基座，普惠收益。

---

## 11. 不在本方案范围

- **diffview / fugitive 适配** —— 后续可循同模式扩展
- **docker exec 后端** —— Phase 4 独立工作；backend 抽象天然支持，
  写一个 docker_backend.lua 就行
- **submodule 完整支持** —— neogit upstream 自己也半残，跟随 upstream
- **GPG signing prompt** —— pty 通路覆盖到 username/password 即够 80%
  场景；GPG pin entry 是另一种 pty 子流程（pinentry），后续视用户
  反馈再上

---

## 12. 关键文件清单

### 新增（fork ~/Code/Neovim/neogit/ 内）
- `lua/neogit/backends.lua`
- `lua/neogit/buffers/remote_commit_editor.lua`（Phase 3B：本地收消息走 -F -）

### 修改（fork 内）
- `lua/neogit/process.lua`
- `lua/neogit/runner.lua`
- `lua/neogit/lib/git/cli.lua`
- `lua/neogit/lib/git/repository.lua`
- `lua/neogit/watcher.lua`
- `lua/neogit/client.lua`

### 新增（zero-nvim 内）
- `lua/zero-nvim/neogit/backend.lua`
- `lua/zero-nvim/neogit/watcher.lua`（仿 gitsigns/refresh.lua）
- 后续：`lua/zero-nvim/neogit/editor_bridge.lua`（Phase 3C）
- 资源：`lua/zero-nvim/neogit/zero-editor.sh`（Phase 3C 远端部署）

### 修改（zero-nvim 内）
- `lua/zero-nvim/init.lua` — `M.setup()` 末尾调 `neogit.backend.setup()`
- `daemon/src/cmd/` — Phase 3A 加 `stdin_write` / `stdin_close` / `pty`
- 后续：`daemon/src/cmd/editor.rs`（Phase 3C fifo 桥）

### 不动
- 其余 neogit 模块（buffers / popups / lib/git/* 行为层）
- gitsigns fork（互不干扰）
