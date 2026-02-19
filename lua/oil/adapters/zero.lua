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
  return true
end

---@param bufnr integer
M.write_file = function(bufnr)
  loading.set_loading(bufnr, true)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local res = M.parse_url(bufname)
  local zero = get_zero()

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")
  -- Ensure trailing newline if file is not empty
  if #content > 0 and content:sub(-1) ~= "\n" then
    content = content .. "\n"
  end

  vim.schedule(function()
    local chan = zero._get_daemon_chan and zero._get_daemon_chan()
    if not chan then
      loading.set_loading(bufnr, false)
      vim.notify("Daemon not connected", vim.log.levels.ERROR)
      return
    end

    local ok, ret = pcall(vim.fn.rpcrequest, chan, "write_file", res.user, res.host, res.port, res.path, content)
    loading.set_loading(bufnr, false)

    if ok and ret == true then
      vim.bo[bufnr].modified = false
      vim.notify("Saved: " .. res.path, vim.log.levels.INFO)
    else
      vim.notify("Save failed: " .. tostring(ret), vim.log.levels.ERROR)
    end
  end)
end

---@param url string
---@param type "file"|"directory"
---@param callback fun(err?: string)
M.create_entry = function(url, type, callback)
  local res = M.parse_url(url)
  local zero = get_zero()
  local chan = zero._get_daemon_chan and zero._get_daemon_chan()
  if not chan then return callback("Daemon not connected") end

  -- Prevent creating files ending with / (Oil handles normalization but just in case)
  if type == "file" and vim.endswith(res.path, "/") then
    return callback("File path ends with /")
  end

  vim.schedule(function()
    if type == "directory" then
      local ok, ret = pcall(vim.fn.rpcrequest, chan, "mkdir", res.user, res.host, res.port, res.path)
      if ok and ret == true then callback() else callback(ret or "RPC failed") end
    else
      -- Create empty file
      local ok, ret = pcall(vim.fn.rpcrequest, chan, "write_file", res.user, res.host, res.port, res.path, "")
      if ok and ret == true then callback() else callback(ret or "RPC failed") end
    end
  end)
end

---@param url string
---@param callback fun(err?: string)
M.delete_entry = function(url, callback)
  local res = M.parse_url(url)
  local zero = get_zero()
  local chan = zero._get_daemon_chan and zero._get_daemon_chan()
  if not chan then return callback("Daemon not connected") end

  vim.schedule(function()
    -- Try remove_file first, if it fails maybe it's a dir?
    -- Actually we should probably know the type, but delete_entry signature doesn't pass it.
    -- However, we can guess or try both. Or use `stat`?
    -- Optimization: Just try remove_file, if fail try remove_dir?
    -- Better: Check trailing slash? Oil urls for dirs usually end in /

    local method = "remove_file"
    if vim.endswith(url, "/") then
      method = "remove_dir"
    else
      -- If no trailing slash, it COULD be a dir, but usually Oil adds slash for dirs in list.
      -- Let's try remove_file first.
    end

    -- To be safe, let's stat it first? No, that's slow.
    -- Let's assume Oil passes us the URL as it knows it.
    -- If we look at `list`, we cache entries.

    -- Let's try remove_file, if it fails with specific error?
    -- The daemon `remove_file` uses `unlink`, `remove_dir` uses `rmdir`.

    local ok, ret = pcall(vim.fn.rpcrequest, chan, "remove_file", res.user, res.host, res.port, res.path)
    if ok and ret == true then
      callback()
      return
    end

    -- If remove_file failed, try remove_dir (maybe it was a dir)
    local ok2, ret2 = pcall(vim.fn.rpcrequest, chan, "remove_dir", res.user, res.host, res.port, res.path)
    if ok2 and ret2 == true then
      callback()
    else
      callback(ret or ret2 or "Delete failed")
    end
  end)
end

---@param src_url string
---@param dst_url string
---@param callback fun(err?: string)
M.rename_entry = function(src_url, dst_url, callback)
  local res_src = M.parse_url(src_url)
  local res_dst = M.parse_url(dst_url)
  local zero = get_zero()
  local chan = zero._get_daemon_chan and zero._get_daemon_chan()
  if not chan then return callback("Daemon not connected") end

  -- Basic check: user/host/port should match
  if res_src.user ~= res_dst.user or res_src.host ~= res_dst.host then
    return callback("Cannot rename across different hosts")
  end

  vim.schedule(function()
    local ok, ret = pcall(vim.fn.rpcrequest, chan, "rename", res_src.user, res_src.host, res_src.port, res_src.path,
      res_dst.path)
    if ok and ret == true then callback() else callback(ret or "Rename failed") end
  end)
end



---@param action table
---@return string
M.render_action = function(action)
  if action.type == "create" then
    return string.format("Create %s", action.url)
  elseif action.type == "delete" then
    return string.format("Delete %s", action.url)
  elseif action.type == "move" then
    return string.format("Move %s -> %s", action.src_url, action.dest_url)
  else
    return string.format("%s %s", action.type, action.url)
  end
end

---@param action table
---@param callback fun(err?: string)
M.perform_action = function(action, callback)
  if action.type == "create" then
    M.create_entry(action.url, action.entry_type, callback)
  elseif action.type == "delete" then
    M.delete_entry(action.url, callback)
  elseif action.type == "move" then
    M.rename_entry(action.src_url, action.dest_url, callback)
  else
    callback(string.format("Action '%s' not supported", action.type))
  end
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
