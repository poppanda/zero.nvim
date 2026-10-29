--- 远端连接与按连接的 RPC 调用。
--- 所有 `method(user, host, port, ...)` 形式的 daemon RPC 都应走 request /
--- request_interactive：自动起 daemon、建连接、NOT_CONNECTED 时重连重试一次。
local daemon = require("zero-nvim.daemon")
local uri = require("zero-nvim.uri")
local buffer_io = require("zero-nvim.buffer_io")

local M = {}

local uv = vim.uv or vim.loop

-- 连接失败的负缓存时长：不可达主机在这段时间内不会被反复阻塞式重连。
local CONNECT_FAILURE_TTL_MS = 10000

-- 以下全部 key 为 "user@host:port"，daemon 退出时整体清空
local state = {
    connected = {},        -- -> true
    password_hosts = {},   -- -> true when initial auth used password
    connect_failures = {}, -- -> { at = ms, err = string } (negative cache)
    scanned_projects = {}, -- "<key>:<path>" -> true
    host_cache = {},       -- -> 任意模块的按主机缓存（remote_home、mason bins 等）
}

daemon.on_exit(function()
    for k in pairs(state) do state[k] = {} end
end)

---@return integer? chan
---@return string? err
function M.ensure_connection(user, host, port, password)
    local chan = daemon.ensure()
    if not chan then return nil, "Daemon not running" end
    local key = uri.target_key(user, host, port)

    if state.connected[key] then return chan end

    -- 负缓存：不可达主机 10s 内直接返回上次的错误，不再阻塞式重连。
    -- 带密码的调用（用户刚输入）总是绕过。
    if not password then
        local failure = state.connect_failures[key]
        if failure and (uv.now() - failure.at) < CONNECT_FAILURE_TTL_MS then
            return nil, failure.err
        end
    end

    local ok, res = pcall(vim.fn.rpcrequest, chan, "connect", user, host, port, password)
    if not ok then
        local err = tostring(res)
        state.connect_failures[key] = { at = uv.now(), err = err }
        return nil, err
    end
    state.connect_failures[key] = nil
    state.connected[key] = true
    if password then
        state.password_hosts[key] = true
    end
    return chan
end

local function do_request(interactive, user, host, port, method, ...)
    local chan, err = M.ensure_connection(user, host, port)
    if not chan and interactive and tostring(err):find("AUTH_FAILED", 1, true)
        and #vim.api.nvim_list_uis() > 0 then
        -- 典型场景：daemon 重启后密码认证的连接丢失。用户主动操作（保存等）时
        -- 同步询问一次密码，而不是直接失败。
        local ok_in, pw = pcall(vim.fn.inputsecret, string.format("SSH Password (%s@%s): ", user, host))
        if ok_in and type(pw) == "string" and pw ~= "" then
            chan, err = M.ensure_connection(user, host, port, pw)
        end
    end
    if not chan then return false, tostring(err or "not connected") end

    local ok, res = pcall(vim.fn.rpcrequest, chan, method, user, host, port, ...)
    if not ok and tostring(res):find("NOT_CONNECTED", 1, true) then
        -- daemon 侧会话丢了（daemon 重启 / 被回收）：重连一次后重试
        state.connected[uri.target_key(user, host, port)] = nil
        chan, err = M.ensure_connection(user, host, port)
        if not chan then return false, tostring(err) end
        ok, res = pcall(vim.fn.rpcrequest, chan, method, user, host, port, ...)
    end
    if not ok then return false, tostring(res) end
    return true, res
end

--- Issue a per-connection RPC (`method(user, host, port, ...)`), making sure
--- the daemon is running and the host is connected; retries once after a
--- reconnect when the daemon answers NOT_CONNECTED.
---@return boolean ok
---@return any result_or_error
function M.request(user, host, port, method, ...)
    return do_request(false, user, host, port, method, ...)
end

--- Like request, but may prompt for an SSH password synchronously when the
--- host needs password auth (use only for user-initiated actions).
function M.request_interactive(user, host, port, method, ...)
    return do_request(true, user, host, port, method, ...)
end

---@return boolean
function M.uses_password_auth(user, host, port)
    return state.password_hosts[uri.target_key(user, host, port)] == true
end

--- 按主机的缓存表（同一 user@host:port 每次返回同一张表），daemon 退出时清空。
---@return table
function M.host_cache(user, host, port)
    local key = uri.target_key(user, host, port)
    local t = state.host_cache[key]
    if not t then
        t = {}
        state.host_cache[key] = t
    end
    return t
end

--- 该主机是否已建立连接（不会触发连接）。
---@return boolean
function M.is_connected(user, host, port)
    return state.connected[uri.target_key(user, host, port)] == true
end

--- Resolve and cache the remote user's $HOME. Hard-coding /home/<user>
--- breaks on macOS (/Users/...), root (/root), and containerized hosts
--- where $HOME is non-standard.
---@return string?
function M.remote_home(user, host, port)
    local cache = M.host_cache(user, host, port)
    if cache.remote_home then return cache.remote_home end
    local ok, home = M.request(user, host, port, "exec_remote", 'printf %s "$HOME"')
    if not ok or type(home) ~= "string" or home == "" then return nil end
    cache.remote_home = home
    return home
end

--- 列目录；首次访问某目录时顺带通知 daemon 后台 scan_project。
---@return table[]? entries
---@return string? err
function M.list_dir(user, host, port, dir)
    local ok, entries = M.request(user, host, port, "read_dir", dir)
    if not ok then return nil, entries end
    local project_key = string.format("%s:%s", uri.target_key(user, host, port), dir)
    local chan = daemon.channel()
    if chan and not state.scanned_projects[project_key] then
        pcall(vim.rpcnotify, chan, "scan_project", user, host, port, dir)
        state.scanned_projects[project_key] = true
    end
    return entries
end

--- 读取远端文件内容（字节串）。
---@return string? bytes
---@return string? err
function M.read_file(user, host, port, path)
    local ok, content = M.request(user, host, port, "fetch_file", path)
    if not ok then return nil, content end
    return buffer_io.to_bytes(content)
end

return M
