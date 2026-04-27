--- Shared URI helpers for the zero:// scheme.
--- All zero:// URI parsing/formatting MUST go through this module so the
--- shape (canonical, IPv6 etc.) only needs to change in one place.
---
--- Canonical form: zero://user@host:port/path
--- Port is optional and defaults to 22 when omitted.

local M = {}

--- Parse a zero:// URI.
---@param uri string
---@return string? user
---@return string? host
---@return integer? port
---@return string? path
function M.parse(uri)
    if type(uri) ~= "string" then return nil end

    -- zero://user@host:port/path
    local user, host, port_str, path =
        uri:match("^zero://([^@]+)@([^:/]+):(%d+)(/.*)$")
    if user and host and port_str and path then
        return user, host, tonumber(port_str), path
    end

    -- zero://user@host/path  (no port — default 22)
    user, host, path = uri:match("^zero://([^@]+)@([^:/]+)(/.*)$")
    if user and host and path then
        return user, host, 22, path
    end

    return nil
end

--- Build a canonical zero:// URI. Always includes the explicit port to keep
--- buffer names matched across paths that produce URIs (daemon vs Lua).
---@param user string
---@param host string
---@param port integer
---@param path string
---@return string
function M.format(user, host, port, path)
    return string.format("zero://%s@%s:%d%s", user, host, port, path)
end

return M
