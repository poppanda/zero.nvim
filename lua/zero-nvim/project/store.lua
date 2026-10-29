local log = require("zero-nvim.log")
local util = require("zero-nvim.util")

local M = {}

---@class ZeroProjectConfig
---@field host string
---@field user string?
---@field port number?
---@field root string
---@field lsp table<string, {cmd: string[]?, settings: table?, filetypes: string[]?}>?
---@field created_at number

---@type table<string, ZeroProjectConfig>?
local _cache = nil

---@type number?
local _last_mtime = nil

local uv = vim.uv or vim.loop

---@param path string
---@return number?
local function get_mtime(path)
    local stat = uv.fs_stat(path)
    if stat and stat.mtime then
        return stat.mtime.sec
    end
    return nil
end

---@return string
local function get_store_path()
    local data_path = vim.fn.stdpath("data")
    return string.format("%s/zero-nvim/projects.json", data_path)
end

---Ensure the directory for the store file exists
local function ensure_dir(path)
    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end
end

---Load all projects from disk (with mtime caching)
---@return table<string, ZeroProjectConfig>
function M.load()
    local path = get_store_path()
    local mtime = get_mtime(path)

    if not mtime then
        _cache = {}
        _last_mtime = nil
        return _cache
    end

    if _cache and _last_mtime == mtime then
        return _cache
    end

    local file = io.open(path, "r")
    if not file then
        return {}
    end

    local content = file:read("*a")
    file:close()

    if not content or content == "" then
        _cache = {}
        _last_mtime = mtime
        return _cache
    end

    local ok, data = pcall(vim.json.decode, content)
    if not ok then
        log.error("failed to decode projects.json")
        return {}
    end

    _cache = data or {}
    _last_mtime = mtime
    return _cache
end

---Save projects to disk.
---Encodes first, writes a temp file next to the store and renames it over
---projects.json, so an encode error or crash mid-write can't truncate it.
---@param data table<string, ZeroProjectConfig>
---@return boolean ok
function M.save(data)
    local content = util.format_json(data)
    if not content then
        log.error("failed to encode projects data")
        return false
    end

    local path = get_store_path()
    ensure_dir(path)
    local tmp = string.format("%s.%d.tmp", path, uv.os_getpid and uv.os_getpid() or 0)
    local file = io.open(tmp, "w")
    if not file then
        log.error("failed to open projects.json for writing")
        return false
    end
    local ok_write = file:write(content)
    file:close()
    if not ok_write then
        os.remove(tmp)
        log.error("failed to write projects.json")
        return false
    end

    local ok_rename, rename_err = os.rename(tmp, path)
    if not ok_rename then
        os.remove(tmp)
        log.error("failed to replace projects.json: " .. tostring(rename_err))
        return false
    end

    _cache = data
    _last_mtime = get_mtime(path)
    return true
end

return M
