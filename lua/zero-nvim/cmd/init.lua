-- =============================================================================
-- cmd/init.lua — 远程命令 API
-- =============================================================================
-- sync    — 同步一次性命令（git rev-parse / git commit -F -）；argv 或完整 spec
-- stream  — 流式（搜索 / git diff / docker logs）
-- cancel  — 取消流式 session
-- with_remote_path / env_pairs — 各后端共用的 argv / env 预处理

local exec = require("zero-nvim.cmd.exec")
local daemon = require("zero-nvim.daemon")
local remote = require("zero-nvim.remote")

local M = {}

-- 常见远端二进制安装位置；ssh 非交互 shell 默认 PATH 经常缺这些。
-- $PATH 在远端 sh -c 里才展开。
M.REMOTE_PATH_PREFIX = "/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:/home/linuxbrew/.linuxbrew/bin"

--- 把 argv 包成 sh -c 'PATH=... exec "$@"' -- argv...，让远端 rg / git 能找到。
---@param argv string[]
---@return string[]
function M.with_remote_path(argv)
    local out = { "sh", "-c", ('PATH="%s:$PATH" exec "$@"'):format(M.REMOTE_PATH_PREFIX), "--" }
    return vim.list_extend(out, argv)
end

--- lua dict 形式的 env（{LC_ALL='C', ...}）→ daemon 期望的 [[k,v], ...]；空 → nil。
---@param env table?
---@return string[][]?
function M.env_pairs(env)
    if not env then return nil end
    local out = {}
    for k, v in pairs(env) do
        out[#out + 1] = { tostring(k), tostring(v) }
    end
    return #out > 0 and out or nil
end

--- 把 argv (string|string[]) 标准化成 string[]。string 走 sh -c 包装。
local function normalize_argv(argv)
    if type(argv) == "string" then return { "sh", "-c", argv } end
    if type(argv) == "table" then return argv end
    error("argv must be string or string[]")
end

--- 确保主机已连接后发一条 `method(...)` RPC。target = {user, host, port?}
---@return boolean ok
---@return any result_or_error
local function request(target, method, ...)
    local chan, err = remote.ensure_connection(target.user, target.host, target.port or 22)
    if not chan then return false, err or "no daemon channel" end
    local ok, res = pcall(vim.fn.rpcrequest, chan, method, ...)
    if not ok then return false, tostring(res) end
    return true, res
end

--- 同步命令。第二参数可以是 argv（string|string[]），也可以是完整 spec。
---@param target table { user, host, port? }
---@param argv   string|string[]|table  argv 或 { argv, env?, cwd?, stdin?, timeout_ms?, pty? }
---@param opts?  table { timeout_ms? }（覆盖 spec 同名字段）
---@return table? result  { stdout, stderr, code, duration_ms }
---@return string? err
function M.sync(target, argv, opts)
    local spec = (type(argv) == "table" and argv.argv) and vim.deepcopy(argv) or { argv = argv }
    spec = vim.tbl_extend("force", spec, opts or {})
    spec.argv = normalize_argv(spec.argv)
    local ok, res = request(target, "cmd_sync", target.user, target.host, target.port or 22, spec)
    if not ok then return nil, res end
    return res
end

--- 流式
---@param target  table { user, host, port? }
---@param spec    table { argv, parser?, env?, cwd?, stdin?, pty?, timeout_ms?, owner_buf?, owner_win? }
---@param handlers table { on_event?, on_exit? }
---@return string? session_id
---@return string? err
function M.stream(target, spec, handlers)
    handlers = handlers or {}
    local argv = normalize_argv(spec.argv)
    local sid = exec.register({
        parser = spec.parser,
        on_event = handlers.on_event,
        on_exit = handlers.on_exit,
        owner_buf = spec.owner_buf,
        owner_win = spec.owner_win,
    })
    -- 不把 parser/owner_* 等 Lua-only 字段塞给 daemon
    local ok, err = request(target, "cmd_stream", sid, target.user, target.host, target.port or 22, {
        argv = argv,
        env = spec.env,
        cwd = spec.cwd,
        stdin = spec.stdin,
        pty = spec.pty,
        timeout_ms = spec.timeout_ms,
    })
    if not ok then
        -- 连接 / 启动失败：清掉刚注册的 session
        exec.unregister(sid)
        return nil, err
    end
    return sid
end

--- 主动取消一条流式 session
function M.cancel(sid)
    return exec.cancel(sid)
end

--- notify（不是 request）：避免主线程被远端慢写阻塞；写失败时 daemon 仅打日志。
local function notify(method, ...)
    local chan = daemon.channel()
    return chan ~= nil and (pcall(vim.fn.rpcnotify, chan, method, ...))
end

--- 往流式 session 的 stdin 写一段字节。
--- 典型用例：`git commit -F -` 在 spawn 后通过这个 API 把 message 推下去；
--- `git push` pty 模式碰到 username/password prompt 时把用户输入推下去。
---@param sid string
---@param data string
---@return boolean ok
function M.write_stdin(sid, data)
    if not sid or data == nil then return false end
    return notify("cmd_stdin_write", sid, data)
end

--- 通知 daemon 把 session 的 stdin 关掉（send_eof）。worker 写完 pending 队列
--- 后才执行——保证最后一段 data 不会被丢。
---@param sid string
---@return boolean ok
function M.close_stdin(sid)
    if not sid then return false end
    return notify("cmd_stdin_close", sid)
end

return M
