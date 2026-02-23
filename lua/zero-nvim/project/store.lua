local M = {}

---@class ZeroProjectConfig
---@field host string
---@field user string?
---@field port number?
---@field root string
---@field lsp table<string, {cmd: string[]?, settings: table?}>?
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
        vim.notify("zero-nvim: Failed to decode projects.json", vim.log.levels.ERROR)
        return {}
    end

    _cache = data or {}
    _last_mtime = mtime
    return _cache
end

---Save projects to disk
---@param data table<string, ZeroProjectConfig>
function M.save(data)
    local path = get_store_path()
    ensure_dir(path)
    local file = io.open(path, "w")
    if not file then
        vim.notify("zero-nvim: Failed to open projects.json for writing", vim.log.levels.ERROR)
        return
    end

    local ok, content = pcall(vim.json.encode, data)
    if not ok then
        file:close()
        vim.notify("zero-nvim: Failed to encode projects data", vim.log.levels.ERROR)
        return
    end

    file:write(content)
    file:close()

    _cache = data
    _last_mtime = get_mtime(path)
end

return M
