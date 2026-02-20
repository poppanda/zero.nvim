local M = {}

---@class ZeroProjectConfig
---@field host string
---@field user string?
---@field port number?
---@field root string
---@field lsp table<string, {cmd: string[]?, settings: table?}>?
---@field created_at number

---@return string
local function get_store_path()
    local data_path = vim.fn.stdpath("data")
    return string.format("%s/zero-nvim/projects.json", data_path)
end

---Ensure the directory for the store file exists
local function ensure_dir()
    local path = get_store_path()
    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end
end

---Load all projects from disk
---@return table<string, ZeroProjectConfig>
function M.load()
    local path = get_store_path()
    local file = io.open(path, "r")
    if not file then
        return {}
    end

    local content = file:read("*a")
    file:close()

    if not content or content == "" then
        return {}
    end

    local ok, data = pcall(vim.json.decode, content)
    if not ok then
        vim.notify("zero-nvim: Failed to decode projects.json", vim.log.levels.ERROR)
        return {}
    end

    return data or {}
end

---Save projects to disk
---@param data table<string, ZeroProjectConfig>
function M.save(data)
    ensure_dir()
    local path = get_store_path()
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
end

return M
