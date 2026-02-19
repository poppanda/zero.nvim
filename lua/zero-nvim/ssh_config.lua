--- SSH Config 解析模块 for zero-nvim
--- 优先通过 Daemon RPC 解析（支持完整 OpenSSH 语法），失败时回退到本地解析。

local M = {}

-- ========================================================================
-- Daemon RPC 版本（优先使用）
-- ========================================================================

--- 尝试通过 Daemon 获取 SSH Host 列表
--- Daemon 使用 Rust ssh2-config 库，支持 Include、Match 等高级语法
---@return table[]|nil hosts
local function rpc_list_hosts()
    local ok, zero = pcall(require, "zero-nvim")
    if not ok then return nil end

    local chan = zero._get_daemon_chan and zero._get_daemon_chan()
    if not chan then return nil end

    local success, result = pcall(vim.fn.rpcrequest, chan, "list_ssh_hosts")
    if not success then return nil end

    -- Daemon 返回的 entry 中 user 可能为空字符串，转为 nil 保持一致
    for _, entry in ipairs(result) do
        if entry.user == "" then entry.user = nil end
        if entry.identity_file == "" then entry.identity_file = nil end
    end
    return result
end

--- 尝试通过 Daemon 解析 SSH 目标
---@param target string
---@return table|nil
local function rpc_resolve_target(target)
    local ok, zero = pcall(require, "zero-nvim")
    if not ok then return nil end

    local chan = zero._get_daemon_chan and zero._get_daemon_chan()
    if not chan then return nil end

    local success, result = pcall(vim.fn.rpcrequest, chan, "resolve_ssh_target", target)
    if not success then return nil end
    return result
end

-- ========================================================================
-- 本地解析（Fallback）
-- ========================================================================

--- 本地解析 ~/.ssh/config —— 当 Daemon 未启动时使用
--- 仅支持基础语法：Host, HostName, User, Port, IdentityFile
---@param path? string
---@return table[] hosts
local function local_parse(path)
    path = path or (vim.fn.expand("~") .. "/.ssh/config")

    local f = io.open(path, "r")
    if not f then return {} end

    local hosts = {}
    local current = nil

    for line in f:lines() do
        line = line:gsub("#.*$", "")
        line = line:match("^%s*(.-)%s*$") or ""
        if line == "" then goto continue end

        local key, value = line:match("^(%S+)%s+(.+)$")
        if not key then goto continue end
        key = key:lower()

        if key == "host" then
            if current and not current.host:match("[%*%?]") then
                table.insert(hosts, current)
            end
            current = {
                host = value,
                hostname = nil,
                user = nil,
                port = 22,
                identity_file = nil,
            }
        elseif current then
            if key == "hostname" then
                current.hostname = value
            elseif key == "user" then
                current.user = value
            elseif key == "port" then
                current.port = tonumber(value) or 22
            elseif key == "identityfile" then
                current.identity_file = value
            end
        end

        ::continue::
    end

    if current and not current.host:match("[%*%?]") then
        table.insert(hosts, current)
    end

    f:close()
    return hosts
end

-- ========================================================================
-- 公共 API
-- ========================================================================

--- 获取所有 SSH Host 列表
--- 优先从 Daemon 获取（完整 OpenSSH 语法），失败回退本地解析
---@param path? string 仅在本地解析时使用
---@return table[] hosts
function M.parse(path)
    -- 优先尝试 Daemon RPC
    local rpc_result = rpc_list_hosts()
    if rpc_result then return rpc_result end
    -- Fallback: 本地解析
    return local_parse(path)
end

--- 解析目标字符串为连接参数
--- 支持: "alias" | "user@host" | "user@host:port"
---@param target string
---@return table|nil result { user, hostname, port }
function M.resolve(target)
    -- 优先尝试 Daemon RPC
    local rpc_result = rpc_resolve_target(target)
    if rpc_result then return rpc_result end

    -- Fallback: 手动解析 + 本地 SSH config 查找

    -- user@host:port
    local user, host, port_str = target:match("^([^@]+)@([^:]+):(%d+)$")
    if user and host and port_str then
        local entry = M.find_host(host)
        if entry then
            return {
                user = user,
                hostname = entry.hostname or entry.host,
                port = tonumber(port_str),
            }
        end
        return { user = user, hostname = host, port = tonumber(port_str) }
    end

    -- user@host
    user, host = target:match("^([^@]+)@([^:]+)$")
    if user and host then
        local entry = M.find_host(host)
        if entry then
            return {
                user = user,
                hostname = entry.hostname or entry.host,
                port = entry.port or 22,
            }
        end
        return { user = user, hostname = host, port = 22 }
    end

    -- 纯 alias
    local entry = M.find_host(target)
    if entry then
        return {
            user = entry.user or vim.env.USER or "root",
            hostname = entry.hostname or entry.host,
            port = entry.port or 22,
        }
    end

    return nil
end

--- 通过 Host alias 查找条目（使用本地解析）
---@param name string
---@return table|nil
function M.find_host(name)
    local hosts = local_parse()
    for _, entry in ipairs(hosts) do
        if entry.host == name then
            return entry
        end
    end
    return nil
end

return M
