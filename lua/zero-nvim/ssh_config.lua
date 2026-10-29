--- SSH Config 解析模块 for zero-nvim
--- 优先通过 Daemon RPC 解析（Rust ssh2-config，支持 Include、Match 等完整
--- OpenSSH 语法），daemon 起不来时回退到本地的最小解析器。
local daemon = require("zero-nvim.daemon")

local M = {}

local DEFAULT_PATH = vim.fn.expand("~") .. "/.ssh/config"

--- Daemon RPC（按需启动 daemon）；失败返回 nil。
local function rpc(method, ...)
    local chan = daemon.ensure()
    if not chan then return nil end
    local ok, res = pcall(vim.fn.rpcrequest, chan, method, ...)
    if ok and type(res) == "table" then return res end
    return nil
end

-- 本地解析结果按 mtime 缓存：path -> { mtime, hosts }
local cache = {}

--- 本地解析 ~/.ssh/config —— 仅支持 Host, HostName, User, Port, IdentityFile
---@param path? string
---@return table[] hosts
local function local_parse(path)
    path = path or DEFAULT_PATH
    local stat = (vim.uv or vim.loop).fs_stat(path)
    if not stat then return {} end
    local hit = cache[path]
    if hit and hit.mtime == stat.mtime.sec then return hit.hosts end

    local f = io.open(path, "r")
    if not f then return {} end
    local hosts, current = {}, nil
    local function flush()
        if current and not current.host:match("[%*%?]") then table.insert(hosts, current) end
    end
    for line in f:lines() do
        local key, value = vim.trim((line:gsub("#.*$", ""))):match("^(%S+)%s+(.+)$")
        key = key and key:lower()
        if key == "host" then
            flush()
            current = { host = value, port = 22 }
        elseif current and key then
            if key == "hostname" then current.hostname = value
            elseif key == "user" then current.user = value
            elseif key == "port" then current.port = tonumber(value) or 22
            elseif key == "identityfile" then current.identity_file = value
            end
        end
    end
    flush()
    f:close()

    cache[path] = { mtime = stat.mtime.sec, hosts = hosts }
    return hosts
end

--- 未在 ssh config 里指定 User 时的默认用户名。
---@return string
function M.default_user()
    return vim.env.USER or "root"
end

--- 获取所有 SSH Host 列表
---@param path? string 仅在本地解析时使用
---@return table[] hosts
function M.parse(path)
    local hosts = rpc("list_ssh_hosts")
    if not hosts then return local_parse(path) end
    -- Daemon 返回的 entry 中 user / identity_file 可能为空字符串，转为 nil 保持一致
    for _, entry in ipairs(hosts) do
        if entry.user == "" then entry.user = nil end
        if entry.identity_file == "" then entry.identity_file = nil end
    end
    return hosts
end

--- 通过 Host alias 查找条目（使用本地解析）
---@param name string
---@return table|nil
local function find_host(name)
    for _, entry in ipairs(local_parse()) do
        if entry.host == name then return entry end
    end
    return nil
end

--- 解析目标字符串为连接参数
--- 支持: "alias" | "user@host" | "user@host:port"（host 也可以是 alias）
---@param target string
---@return { user: string, hostname: string, port: integer }|nil
function M.resolve(target)
    local resolved = rpc("resolve_ssh_target", target)
    if resolved then return resolved end

    local user, host, port = target:match("^([^@]+)@([^:]+):?(%d*)$")
    local entry = find_host(host or target)
    if not user and not entry then return nil end
    return {
        user = user or entry.user or M.default_user(),
        hostname = entry and (entry.hostname or entry.host) or host,
        port = tonumber(port) or (entry and entry.port) or 22,
    }
end

return M
