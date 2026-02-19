--- oil.nvim adapter for zero-nvim remote editing.
--- Placed at lua/oil/adapters/zero.lua so oil.nvim can discover it
--- via require("oil.adapters.zero").
---
--- URL scheme: oil-zero://user@host:port/remote/path
--- (port defaults to 22 if omitted)

local cache = require("oil.cache")
local constants = require("oil.constants")
local loading = require("oil.loading")
local pathutil = require("oil.pathutil")
local util = require("oil.util")

local FIELD_META = constants.FIELD_META

local M = {}

---@class (exact) oil.zeroUrl
---@field scheme string
---@field user string
---@field host string
---@field port integer
---@field path string

---Parse an oil-zero:// URL into its components.
---oil.nvim calls util.parse_url(oil_url) which splits scheme and path,
---then passes the full oil_url to this function.
---@param oil_url string
---@return oil.zeroUrl
M.parse_url = function(oil_url)
  local scheme, url = util.parse_url(oil_url)
  assert(scheme and url, string.format("Malformed oil-zero url: '%s'", oil_url))

  local ret = { scheme = scheme }

  -- Extract user@remainder
  local username, rem = url:match("^([^@%s]+)@(.*)$")
  ret.user = username or ""
  url = rem or url

  -- Try host:port/path
  local host, port, path = url:match("^([^:]+):(%d+)/(.*)$")
  if host then
    ret.host = host
    ret.port = tonumber(port)
    ret.path = "/" .. path
  else
    -- Try host/path (no port)
    host, path = url:match("^([^/]+)/(.*)$")
    ret.host = host or ""
    ret.port = 22
    ret.path = "/" .. (path or "")
  end

  if not ret.host or ret.host == "" then
    error(string.format("Malformed oil-zero url: %s", oil_url))
  end

  ---@cast ret oil.zeroUrl
  return ret
end

---Convert a parsed URL back to a string
---@param url oil.zeroUrl
---@return string
local function url_to_str(url)
  local pieces = { url.scheme }
  if url.user and url.user ~= "" then
    table.insert(pieces, url.user)
    table.insert(pieces, "@")
  end
  table.insert(pieces, url.host)
  if url.port and url.port ~= 22 then
    table.insert(pieces, string.format(":%d", url.port))
  end
  table.insert(pieces, "/")
  -- path already starts with /, trim the leading slash to avoid double
  local p = url.path
  if p:sub(1, 1) == "/" then
    p = p:sub(2)
  end
  table.insert(pieces, p)
  return table.concat(pieces, "")
end

---Get the zero-nvim core module (lazy-loaded to avoid circular deps)
---@return table
local function get_zero()
  return require("zero-nvim")
end

---@param bufname string
---@return string
M.get_parent = function(bufname)
  local res = M.parse_url(bufname)
  res.path = pathutil.parent(res.path)
  return url_to_str(res)
end

---@param url string
---@param callback fun(url: string)
M.normalize_url = function(url, callback)
  local res = M.parse_url(url)
  -- Ensure directory paths end with /
  if not vim.endswith(res.path, "/") then
    -- We need to stat to know if it's a directory
    local zero = get_zero()
    local chan, err = zero.ensure_connection(res.user, res.host, res.port)
    if chan then
      local ok, ftype = pcall(vim.fn.rpcrequest, chan, "stat", res.user, res.host, res.port, res.path)
      if ok and ftype == "directory" then
        res.path = res.path .. "/"
      end
    end
  end
  callback(url_to_str(res))
end

---@param url string
---@param column_defs string[]
---@param callback fun(err?: string, entries?: oil.InternalEntry[], fetch_more?: fun())
M.list = function(url, column_defs, callback)
  local res = M.parse_url(url)
  local zero = get_zero()

  vim.schedule(function()
    local entries_data, err = zero.get_entries(res.user, res.host, res.port, res.path)
    if not entries_data then
      callback(err or "Failed to list directory")
      return
    end

    local cache_entries = {}
    for _, entry in ipairs(entries_data) do
      local entry_type = entry.type == "directory" and "directory" or "file"
      local cache_entry = cache.create_entry(url, entry.name, entry_type)
      if entry.size then
        cache_entry[FIELD_META] = { size = entry.size }
      end
      table.insert(cache_entries, cache_entry)
    end
    callback(nil, cache_entries)
  end)
end

---@param bufnr integer
---@return boolean
M.is_modifiable = function(bufnr)
  -- Read-only for now; file mutations not yet supported
  return false
end

---@param name string
---@return nil|oil.ColumnDefinition
M.get_column = function(name)
  return nil
end

---@param bufnr integer
M.read_file = function(bufnr)
  loading.set_loading(bufnr, true)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local res = M.parse_url(bufname)
  local zero = get_zero()

  vim.schedule(function()
    local content, err = zero.get_file_content(res.user, res.host, res.port, res.path)
    loading.set_loading(bufnr, false)

    vim.bo[bufnr].modifiable = true
    vim.cmd.doautocmd({ args = { "BufReadPre", bufname }, mods = { silent = true } })

    if not content then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "Error: " .. (err or "unknown error") })
    else
      local lines = vim.split(content, "\n")
      if #lines > 0 and lines[#lines] == "" then
        table.remove(lines)
      end
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)
    end

    vim.bo[bufnr].modified = false
    local basename = pathutil.basename(bufname)
    local filetype = vim.filetype.match({ buf = bufnr, filename = basename })
    if filetype then
      vim.bo[bufnr].filetype = filetype
    end
    vim.cmd.doautocmd({ args = { "BufReadPost", bufname }, mods = { silent = true } })
  end)
end

return M
