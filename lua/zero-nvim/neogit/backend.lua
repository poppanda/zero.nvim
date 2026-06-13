-- =============================================================================
-- zero-nvim/neogit/backend.lua — neogit fork 远端 backend 实现
-- =============================================================================
-- 注册到 fork 版 neogit 的 backends registry 上：当 cwd 是 zero:// URI 时，
-- 接管 git 路径探测（paths）、git 进程 spawn、.git/ 文件系统监听（watch）。
--
-- 仅在用户装了 fork（require "neogit.backends" 成功）时才注册——upstream
-- neogit 没这个模块，pcall 失败就静默退出，本地行为不变。

local M = {}

local uri = require("zero-nvim.uri")
local cmd = require("zero-nvim.cmd")

-- 远端二进制 PATH 前缀：ssh 非交互 shell 的默认 PATH 经常不含这些。
-- 与 gitsigns/backend.lua 用同一份；docker 适配后续也会复用。
local REMOTE_PATH_PREFIX =
    "/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:/home/linuxbrew/.linuxbrew/bin"

--- 把 argv 包成 sh -c 'PATH=... exec "$@"' --，远端 git 才能找到。
---@param argv string[]
---@return string[]
local function wrap_with_path(argv)
    local wrapped = {
        "sh", "-c",
        ('PATH="%s:$PATH" exec "$@"'):format(REMOTE_PATH_PREFIX),
        "--",
    }
    for _, a in ipairs(argv) do wrapped[#wrapped + 1] = a end
    return wrapped
end

--- 把 lua dict 形式的 env 转成 daemon 期望的 [[k,v], ...]。空 dict → nil。
---@param env table?
---@return string[][]?
local function env_to_pairs(env)
    if not env then return nil end
    local out = {}
    for k, v in pairs(env) do
        out[#out + 1] = { tostring(k), tostring(v) }
    end
    if #out == 0 then return nil end
    return out
end

--- daemon 走 msgpack-rpc 把 stdout 字节传过来：rust 侧改成 Value::String 后
--- 应当是 Lua string；但旧 daemon 二进制 / 极端情况仍可能解成 vim.Blob (userdata)。
--- 这里做最后一道保险：任何非 string 输入都按字节重建成 Lua string。
--- Blob 直接喂 vim.split 会得到 Blob 切片，传给 fnamemodify 触发 E976。
local function coerce_to_string(text)
    if text == nil then return "" end
    if type(text) == "string" then return text end
    -- vim.Blob → Lua string：blob2list 拿字节数组，按 200 字节分块以避开
    -- string.char(unpack(...)) 的 Lua 栈上限（默认 ~250 args）
    local ok, list = pcall(vim.fn.blob2list, text)
    if not ok or type(list) ~= "table" then
        return tostring(text)
    end
    local n = #list
    if n == 0 then return "" end
    local parts = {}
    for i = 1, n, 200 do
        parts[#parts + 1] = string.char(unpack(list, i, math.min(i + 199, n)))
    end
    return table.concat(parts)
end

--- 远端 backend id：包含 user/host/port，确保不同主机的同名 worktree 不
--- 撞 Repo.cache_key / Watcher.cache_key。
---@param target table { user, host, port? }
---@return string
function M.id_for(target)
    return ("zero://%s@%s:%d"):format(target.user, target.host, target.port or 22)
end

---@param cwd string
---@return table? ctx
function M.detect(cwd)
    local user, host, port, path = uri.parse(cwd)
    if not user then return nil end
    return {
        target = { user = user, host = host, port = port },
        path = path,
        id = M.id_for({ user = user, host = host, port = port }),
    }
end

--- 一次 SSH RTT 拿全部 4 个路径——比本地的 4×vim.system 还少。
--- 单条命令：rev-parse --show-toplevel --git-common-dir --git-dir --is-inside-work-tree
--- 输出 4 行；第 4 行可能是 "true"/"false"，也可能在不是仓库时这条命令直接非 0 退出。
---@param ctx table
---@param dir string  zero:// URI 或 ctx.path 同义
---@return table?, string?
function M.paths(ctx, dir)
    -- dir 可能是 zero:// URI（来自 Repo.instance(opts.cwd)）也可能是远端绝对路径。
    -- 远端 git -C 只接受远端路径——如果是 URI，转成 ctx.path。
    local remote_dir
    local u = uri.parse(dir)
    if u then
        remote_dir = select(4, uri.parse(dir))
    else
        remote_dir = dir
    end

    -- 15s timeout：首次连接 SSH 握手 + ssh agent prompt 可能花几秒；过短的
    -- timeout 会让 paths 探测在 :Neogit 启动时就 hang 整个 nvim（cmd.sync 是
    -- blocking rpcrequest）
    --
    -- shell 探针 `[ -d "$1" ] || d=$(dirname "$1")`：用户可能从 `zero://` *文件*
    -- buffer 触发 :Neogit（neogit 拿 buffer 名当 cwd），文件路径直接喂 `git -C`
    -- 会 fatal "Not a directory"。dirname 兜底让 file/dir 两种入口都能落到仓库
    -- 探测，多 1 个 [ -d ] 测试，单 SSH RTT 不变。
    local res, err = cmd.sync(ctx.target, {
        "sh", "-c",
        ('d="$1"; [ -d "$d" ] || d="$(dirname "$d")"; PATH="%s:$PATH" exec git -C "$d" rev-parse --show-toplevel --git-common-dir --git-dir --is-inside-work-tree'):format(REMOTE_PATH_PREFIX),
        "--",
        remote_dir,
    }, { timeout_ms = 15000 })
    if not res then
        -- 报 notification 让用户看到卡点，否则只是空 status 摸不着头脑
        vim.schedule(function()
            vim.notify(("[zero-nvim/neogit] paths probe failed: %s"):format(err or "unknown"),
                vim.log.levels.ERROR)
        end)
        return nil, err
    end
    -- daemon 旧版本 cmd_sync 仍可能用 Value::Binary 发 stdout → vim.Blob。
    -- 用 coerce_to_string 兜底确保是 Lua string，避免 vim.split 切出 Blob 列表
    -- 让后续 state.worktree_root 也变 Blob 喂 fnamemodify。
    res.stdout = coerce_to_string(res.stdout)
    res.stderr = coerce_to_string(res.stderr)

    if res.code ~= 0 then
        -- 不是 git repo：返回空 worktree_root，让 neogit 走 "not in worktree" 分支
        vim.schedule(function()
            vim.notify(("[zero-nvim/neogit] not a git repo (rev-parse exit %d): %s"):format(
                res.code, vim.trim(res.stderr or "")), vim.log.levels.WARN)
        end)
        return {
            worktree_root = "",
            git_dir = "",
            worktree_git_dir = "",
            is_inside_worktree = false,
        }
    end
    local lines = vim.split(res.stdout, "\n", { plain = true })
    -- 过滤空尾行
    local clean = {}
    for _, l in ipairs(lines) do
        if l ~= "" then clean[#clean + 1] = l end
    end
    if #clean < 4 then
        return nil, "rev-parse 输出行数 < 4: " .. tostring(res.stdout)
    end
    return {
        worktree_root      = clean[1],
        git_dir            = clean[2],
        worktree_git_dir   = clean[3],
        is_inside_worktree = clean[4] == "true",
    }
end

--- 把 cmd.stream 的 stdout chunk 切成 jobstart 风格的 lines 数组（"foo\n" → {"foo", ""}）。
---
--- 关键复刻：nvim 内置 jobstart 在 on_stdout 递交字节给 Lua callback 之前
--- 会把 raw NUL 字节自动转成 LF。git 的 -z 系列命令（`status -z`, `config --null`,
--- `ls-files -z`）依赖这个隐式转换：上层代码 `vim.split(stdout, "\n")` 才能按
--- 记录分行。如果不转，残留 NUL 的 Lua 字符串传给 vim.fn.fnamemodify 会触发
--- E976（vim 字符串不允许嵌入 NUL，nvim 把它隐式视作 Blob 拒绝）。
---
--- 这是 nvim docs 里没显著标注的 jobstart 行为；我们的 backend 拿到 raw 字节，
--- 必须自己做这一步以保持兼容性。
---
--- ⚠️ Lua pattern 里 `\0` 不是字面 NUL，而是"任意字符"通配符（与 `.` 等价）！
--- 必须用 `%z` 才能匹配 NUL 字节。否则每个字符前都被插入 \n，split 出字符级
--- 而不是 record 级——这是个非常隐蔽的坑（用 `%z` 才正确）。
local function split_lines(text)
    local s = coerce_to_string(text)
    s = s:gsub("%z", "\n")
    return vim.split(s, "\n", { plain = true })
end

--- per-target 序列化闸门：每个远端同时最多 1 条 cmd.stream 在跑。
---
--- 为什么需要：neogit status init 一次性触发 6+ 个并发 git 命令（status /
--- branch / log / submodule / rebase / merge / ...），每条走 cmd.stream
--- 都会让 daemon 端 open_dedicated_session 起新 SSH session。并发开 6+ 个
--- TCP+SSH handshake + ssh-agent 协商，要么打满远端 sshd 的 MaxSessions=10，
--- 要么 libssh2 内部某条非线程安全路径炸掉 daemon。
---
--- 序列化后：6 条命令一个接一个跑，代价是 6×SSH RTT 总和（≈600ms-1s）但稳定。
--- 后续 phase 可以做 daemon 端 session pool + 队列，再放开并发。
---@type table<string, { running: boolean, queue: function[] }>
local target_gates = {}

local function gate_for(target)
    local key = ("%s@%s:%d"):format(target.user, target.host, target.port or 22)
    if not target_gates[key] then
        target_gates[key] = { running = false, queue = {} }
    end
    return target_gates[key]
end

local function gate_release(gate)
    gate.running = false
    local next_fn = table.remove(gate.queue, 1)
    if next_fn then
        gate.running = true
        -- vim.schedule：避免在 on_exit callback 上下文里直接同步重入 cmd.stream
        vim.schedule(next_fn)
    end
end

-- 给 handle 占位 id（handle.id 必须从一开始就非 nil，因为 fork 的 process.lua
-- 会立刻把它当 processes[id] 的 table key 用——nil 当 key 直接 "table index is nil"）
local handle_id_counter = 0
local function gen_handle_id()
    handle_id_counter = handle_id_counter + 1
    return ("zero-handle-%d"):format(handle_id_counter)
end

--- backend.spawn：把 neogit Process 的 SpawnOpts/SpawnCallbacks 转成 cmd.stream 调用。
--- 返回 SpawnHandle（id/send/close_stdin/stop）。
---
--- ctx 由 fork 的 process.lua 透传过来（Repo.backend_ctx）——neogit 的标准
--- backend.spawn(opts, cb) 接口拿不到 ctx，所以 fork 内 process.lua 把 ctx 加
--- 在第三个参数。这是 backend 接口的一处增补，对其他 backend 无害（它们可以
--- 忽略这个参数）。
---
--- 当前依赖 cmd.stream 的能力：stdin 一次性传入、stdout/stderr 流式回调、cancel。
--- 增量 stdin 写入（Process:send 在 spawn 后追加字节）走 noop——daemon 端
--- cmd_stdin_write RPC 还没实现（Phase 3B 计划）。Phase 3A 范围里 status / log /
--- branch / diff 这些只读命令都不需要增量 stdin，足够。
---@param opts table   { cmd, cwd, env, pty, stdin }
---@param cb   table   { on_stdout, on_stderr, on_exit }
---@param ctx  table   { target, path, id }
---@return table?, string?
function M.spawn(opts, cb, ctx)
    if not ctx or not ctx.target then
        return nil, "missing ctx.target — process.lua 没正确透传 backend_ctx"
    end

    -- cwd 兜底：fork 的 to_process 会把 git.repo.worktree_root 当 cwd 传进来，
    -- 那已经是远端绝对路径（M.paths 返回的）；但万一 caller 直接传了 zero:// URI，
    -- 这里也能解析成远端绝对路径。
    local cwd = opts.cwd or ctx.path or "/"
    if uri.parse(cwd) then
        cwd = select(4, uri.parse(cwd))
    end

    local gate = gate_for(ctx.target)

    -- handle.id 从一开始就非 nil（占位 string）：fork 的 process.lua 会
    -- 立刻 `processes[handle.id] = self`，nil 当 table key 会直接报
    -- "table index is nil"。真实 cmd.stream sid 启动后存到 closure 变量
    -- real_sid，cancel 时优先取 real_sid（已启动）否则置 cancelled flag
    -- 让 dequeue 时跳过 spawn。
    --
    -- stdin pending 队列：caller（neogit Process）可能在 spawn 返回后立刻调
    -- handle:send / handle:close_stdin（典型场景：commit 把 message 通过
    -- stdin 推下去）。但此时 real_sid 可能还没就绪（gate 在排队）。把这些
    -- 调用缓存下来，real_sid 一旦绑定就重放给 daemon。
    local real_sid = nil
    local cancelled = false
    local stdin_queue = {} -- 元素：{kind="write", data=...} 或 {kind="close"}
    local stdin_closed = false

    -- 把 queue 一次性 flush 给 daemon
    local function flush_stdin_queue(sid)
        for _, msg in ipairs(stdin_queue) do
            if msg.kind == "write" then
                cmd.write_stdin(sid, msg.data)
            elseif msg.kind == "close" then
                cmd.close_stdin(sid)
            end
        end
        stdin_queue = {}
    end

    local handle = {
        id = gen_handle_id(),
        send = function(_self, text)
            if stdin_closed then return end
            if real_sid then
                cmd.write_stdin(real_sid, text)
            else
                table.insert(stdin_queue, { kind = "write", data = text })
            end
        end,
        close_stdin = function(_self)
            if stdin_closed then return end
            stdin_closed = true
            if real_sid then
                cmd.close_stdin(real_sid)
            else
                table.insert(stdin_queue, { kind = "close" })
            end
        end,
        stop = function(_self)
            cancelled = true
            if real_sid then cmd.cancel(real_sid) end
        end,
    }

    local function actually_spawn()
        if cancelled then
            -- caller 已经放弃；直接给 on_exit 一个 aborted 通知
            vim.schedule(function() cb.on_exit(nil, -1, 0) end)
            gate_release(gate)
            return
        end

        -- 不传 spec.stdin。fork process.lua 在 spawn 之后会显式 self:send /
        -- self:close_stdin 把 self.input 推下去——走 handle.send/close_stdin。
        -- 如果这里再传一份 spec.stdin，daemon 会写两遍（一次性快路径 + 增量
        -- 通道），重复污染 commit message 等。
        local sid, err = cmd.stream(ctx.target, {
            argv = wrap_with_path(opts.cmd),
            cwd = cwd,
            env = env_to_pairs(opts.env),
            pty = opts.pty,
        }, {
            on_event = function(ev)
                if ev.kind == "stdout" then
                    cb.on_stdout(nil, split_lines(ev.text))
                elseif ev.kind == "stderr" then
                    cb.on_stderr(nil, split_lines(ev.text))
                end
            end,
            on_exit = function(code, signal, reason, _dur)
                local exit_code = (reason and -1) or (code or 0)
                cb.on_exit(nil, exit_code, signal or 0)
                gate_release(gate)
            end,
        })

        if not sid then
            -- daemon RPC 失败（chan dead / connect 失败等）：合成 on_exit 通知，
            -- 释放 gate，把错误 notify 出来让用户看到根因。
            vim.schedule(function()
                vim.notify(("[zero-nvim/neogit] cmd.stream failed: %s"):format(err or "unknown"),
                    vim.log.levels.ERROR)
                cb.on_exit(nil, -1, 0)
            end)
            gate_release(gate)
            return
        end

        real_sid = sid
        -- 把 spawn-before-real_sid 期间排队的 stdin write/close 一次性回放
        if #stdin_queue > 0 then
            flush_stdin_queue(real_sid)
        end
    end

    if gate.running then
        table.insert(gate.queue, actually_spawn)
    else
        gate.running = true
        actually_spawn()
    end

    return handle
end

--- watch：远端 .git/ 监听。Phase 3A 用事件触发模型——不连远端 inotify，
--- 仅在 BufWritePost / FocusGained / 用户 :Neogit refresh 时跑回调，足够
--- 覆盖"自己改完保存 / 切回 nvim 窗口"两条最常见的 HEAD 可能变路径。
--- 进阶版（Phase 3C）：cmd.stream 跑远端 inotifywait 长流式命令推送事件。
---@param ctx       table
---@param git_dir   string  远端 .git/ 路径（informational only，不真去监听文件系统）
---@param on_event  fun(filename: string?)
---@return function unwatch
function M.watch(ctx, git_dir, on_event)
    return require("zero-nvim.neogit.watcher").start(ctx, git_dir, on_event)
end

---@param opts table?  { watcher? = { debounce_ms?, poll_ms? } }
function M.setup(opts)
    opts = opts or {}
    local ok_req, backends = pcall(require, "neogit.backends")
    if not ok_req then
        -- 用户装的是 upstream neogit（没 backends 模块）或者根本没装。
        -- 静默退出——本地 :Neogit 仍可用。
        return
    end

    backends.register({
        id      = "zero",
        pattern = "^zero://",
        detect  = M.detect,
        paths   = M.paths,
        spawn   = M.spawn,
        watch   = M.watch,
    })

    -- watcher 子模块 setup：debounce/poll 等参数透传
    require("zero-nvim.neogit.watcher").setup(opts.watcher)
end

return M
