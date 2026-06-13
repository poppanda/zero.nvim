-- =============================================================================
-- cmd/init.lua — 远程命令三档 API
-- =============================================================================
-- sync       — 短命令快路径（git rev-parse / docker info）
-- sync_full  — 同步但需要 stdin / env / cwd（git commit -F -）
-- stream     — 流式（搜索 / git diff / docker logs）
-- cancel     — 取消流式 session

local exec = require("zero-nvim.cmd.exec")

local M = {}

--- 拿到 daemon channel，并确保对应主机已连接。target = {user, host, port?}
local function ensure_chan(target)
    local zero = require("zero-nvim")
    local port = target.port or 22
    local chan, err = zero.ensure_connection(target.user, target.host, port)
    if not chan then return nil, err or "no daemon channel" end
    return chan
end

--- 把 argv (string|string[]) 标准化成 string[]。string 走 sh -c 包装。
local function normalize_argv(argv)
    if type(argv) == "string" then
        return { "sh", "-c", argv }
    elseif type(argv) == "table" then
        return argv
    else
        error("argv must be string or string[]")
    end
end

--- 档位 1：极快路径
---@param target table { user, host, port? }
---@param argv   string|string[]
---@param opts?  table { timeout_ms? }
---@return table? result  { stdout, stderr, code, duration_ms }
---@return string? err
function M.sync(target, argv, opts)
    opts = opts or {}
    local chan, err = ensure_chan(target)
    if not chan then return nil, err end
    local spec = {
        argv = normalize_argv(argv),
        timeout_ms = opts.timeout_ms,
    }
    local ok, res = pcall(
        vim.fn.rpcrequest,
        chan,
        "cmd_sync",
        target.user, target.host, target.port or 22, spec
    )
    if not ok then return nil, tostring(res) end
    return res
end

--- 档位 2：同步全功能
---@param target table
---@param spec   table { argv, env?, cwd?, stdin?, timeout_ms?, pty? }
---@return table? result
---@return string? err
function M.sync_full(target, spec)
    local chan, err = ensure_chan(target)
    if not chan then return nil, err end
    spec = vim.tbl_extend("force", {}, spec or {})
    spec.argv = normalize_argv(spec.argv)
    local ok, res = pcall(
        vim.fn.rpcrequest,
        chan,
        "cmd_sync",
        target.user, target.host, target.port or 22, spec
    )
    if not ok then return nil, tostring(res) end
    return res
end

--- 档位 3：流式
---@param target  table { user, host, port? }
---@param spec    table { argv, parser?, env?, cwd?, stdin?, pty?, owner_buf?, owner_win? }
---@param handlers table { on_event?, on_exit? }
---@return string? session_id
---@return string? err
function M.stream(target, spec, handlers)
    handlers = handlers or {}
    local chan, err = ensure_chan(target)
    if not chan then return nil, err end

    local sid = exec.register({
        parser = spec.parser,
        on_event = handlers.on_event,
        on_exit = handlers.on_exit,
        owner_buf = spec.owner_buf,
        owner_win = spec.owner_win,
    })

    -- 不把 parser/owner_* 等 Lua-only 字段塞给 daemon
    local rpc_spec = {
        argv = normalize_argv(spec.argv),
        env = spec.env,
        cwd = spec.cwd,
        stdin = spec.stdin,
        pty = spec.pty,
        timeout_ms = spec.timeout_ms,
    }

    local ok, res = pcall(
        vim.fn.rpcrequest,
        chan,
        "cmd_stream",
        sid, target.user, target.host, target.port or 22, rpc_spec
    )
    if not ok then
        -- 启动失败：清掉刚注册的 session
        exec._sessions[sid] = nil
        return nil, tostring(res)
    end
    return sid
end

--- 主动取消一条流式 session
function M.cancel(sid)
    return exec.cancel(sid)
end

--- 往流式 session 的 stdin 写一段字节。daemon 端 worker 在 poll 循环里
--- try_recv 排空后写到 ssh channel。
---
--- notify（不是 request）：避免主线程被远端慢写阻塞；写失败时 daemon 仅打日志。
--- 典型用例：`git commit -F -` 在 spawn 后通过这个 API 把 message 推下去；
--- `git push` pty 模式碰到 username/password prompt 时把用户输入推下去。
---@param sid string
---@param data string
---@return boolean ok
function M.write_stdin(sid, data)
    if not sid or data == nil then return false end
    local zero = require("zero-nvim")
    local chan = zero._get_daemon_chan()
    if not chan then return false end
    local ok = pcall(vim.fn.rpcnotify, chan, "cmd_stdin_write", sid, data)
    return ok
end

--- 通知 daemon 把 session 的 stdin 关掉（send_eof）。worker 写完 pending 队列
--- 后才执行——保证最后一段 data 不会被丢。
---@param sid string
---@return boolean ok
function M.close_stdin(sid)
    if not sid then return false end
    local zero = require("zero-nvim")
    local chan = zero._get_daemon_chan()
    if not chan then return false end
    local ok = pcall(vim.fn.rpcnotify, chan, "cmd_stdin_close", sid)
    return ok
end

return M
