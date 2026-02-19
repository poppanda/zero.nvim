--- SSH Config parser for zero-nvim
--- Parses ~/.ssh/config and provides structured host entries.

local M = {}

--- Parse an SSH config file into a list of host entries.
--- Ignores wildcard hosts (e.g. Host *).
---@param path? string Path to ssh config (default: ~/.ssh/config)
---@return table[] hosts List of { host, hostname, user, port, identity_file }
function M.parse(path)
    path = path or (vim.fn.expand("~") .. "/.ssh/config")

    local lines = {}
    local f = io.open(path, "r")
    if not f then return {} end
    for line in f:lines() do
        table.insert(lines, line)
    end
    f:close()

    local hosts = {}
    local current = nil

    for _, line in ipairs(lines) do
        -- Strip comments and trim whitespace
        line = line:gsub("#.*$", "")
        line = line:match("^%s*(.-)%s*$") or ""
        if line == "" then goto continue end

        local key, value = line:match("^(%S+)%s+(.+)$")
        if not key then goto continue end
        key = key:lower()

        if key == "host" then
            -- Save previous host entry
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

    -- Don't forget the last host entry
    if current and not current.host:match("[%*%?]") then
        table.insert(hosts, current)
    end

    return hosts
end

--- Resolve a target string into connection parameters.
--- target can be:
---   - A HostName alias from ssh config (e.g. "myserver")
---   - A "user@host" string
---   - A "user@host:port" string
---@param target string
---@return table|nil result { user, hostname, port } or nil if unresolvable
function M.resolve(target)
    -- Try user@host:port
    local user, host, port_str = target:match("^([^@]+)@([^:]+):(%d+)$")
    if user and host and port_str then
        -- Check if host is an ssh config alias
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

    -- Try user@host
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

    -- Bare alias — must be an ssh config Host name
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

--- Find a host entry by its Host alias.
---@param name string Host alias to look up
---@return table|nil entry
function M.find_host(name)
    local hosts = M.parse()
    for _, entry in ipairs(hosts) do
        if entry.host == name then
            return entry
        end
    end
    return nil
end

return M
