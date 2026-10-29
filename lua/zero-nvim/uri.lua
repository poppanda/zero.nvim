--- Shared URI helpers for the zero:// scheme.
--- All zero:// URI parsing/formatting MUST go through this module so the
--- shape (canonical, IPv6 etc.) only needs to change in one place.
---
--- Canonical form: zero://user@host:port/path
--- Port is optional on input and defaults to 22 when omitted; `format` /
--- `normalize` always emit it so the same remote file maps to one buffer.
--- IPv6 literals are written in brackets: zero://user@[::1]:22/path
--- (parse returns the bare address "::1").

local M = {}

M.DEFAULT_PORT = 22

--- Parse a zero:// URI.
---@param uri string
---@return string? user
---@return string? host
---@return integer? port
---@return string? path
function M.parse(uri)
    if type(uri) ~= "string" then return nil end

    local user, rest = uri:match("^zero://([^@/]+)@(.*)$")
    if not user then return nil end

    local host, port_str, path
    if rest:sub(1, 1) == "[" then
        -- IPv6: [addr]:port/path or [addr]/path
        host, port_str, path = rest:match("^%[([^%]]+)%]:(%d+)(/.*)$")
        if not host then
            host, path = rest:match("^%[([^%]]+)%](/.*)$")
        end
    else
        host, port_str, path = rest:match("^([^:/]+):(%d+)(/.*)$")
        if not host then
            host, path = rest:match("^([^:/]+)(/.*)$")
        end
    end
    if not host or host == "" or not path then return nil end

    return user, host, port_str and tonumber(port_str) or M.DEFAULT_PORT, path
end

--- Build a canonical zero:// URI. Always includes the explicit port to keep
--- buffer names matched across paths that produce URIs (daemon vs Lua).
---@param user string
---@param host string
---@param port integer
---@param path string
---@return string
function M.format(user, host, port, path)
    if host:find(":", 1, true) and host:sub(1, 1) ~= "[" then
        host = "[" .. host .. "]"
    end
    return string.format("zero://%s@%s:%d%s", user, host, tonumber(port) or M.DEFAULT_PORT, path)
end

--- Normalize a remote path: collapse repeated slashes and drop "/./"
--- segments. ".." is left alone on purpose (symlinks make it ambiguous).
--- A trailing slash (directory marker) is preserved.
---@param path string
---@return string
function M.normalize_path(path)
    if type(path) ~= "string" or path == "" then return "/" end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    path = path:gsub("/+", "/")
    -- "/./" 可能连续出现（/a/././b），循环到不再变化
    local prev
    repeat
        prev = path
        path = path:gsub("/%./", "/")
    until path == prev
    path = path:gsub("/%.$", "/")
    return path
end

--- Return the canonical form of a zero:// URI (explicit port, collapsed
--- slashes), or nil when `uri` is not a zero:// URI.
---@param uri string
---@return string?
function M.normalize(uri)
    local user, host, port, path = M.parse(uri)
    if not user then return nil end
    return M.format(user, host, port, M.normalize_path(path))
end

--- Ensure a directory path ends with exactly one "/".
---@param path string
---@return string
function M.as_dir(path)
    path = M.normalize_path(path)
    if path:sub(-1) ~= "/" then path = path .. "/" end
    return path
end

--- Parent directory of a path (file or directory), always with trailing "/".
--- "/a/b/" -> "/a/", "/a/b" -> "/a/", "/" -> "/".
---@param path string
---@return string
function M.parent_dir(path)
    local p = M.normalize_path(path):gsub("/+$", "")
    if p == "" then return "/" end
    local parent = p:match("^(.*)/[^/]*$") or ""
    return parent .. "/"
end

--- Join a directory and an entry name. Directories get a trailing "/".
---@param dir string
---@param name string
---@param is_dir? boolean
---@return string
function M.join(dir, name, is_dir)
    local p = M.as_dir(dir) .. name
    if is_dir then p = p .. "/" end
    return M.normalize_path(p)
end

--- Connection key used for per-remote caches: "user@host:port".
---@param user string
---@param host string
---@param port integer
---@return string
function M.target_key(user, host, port)
    return string.format("%s@%s:%s", user, host, tonumber(port) or M.DEFAULT_PORT)
end

return M
