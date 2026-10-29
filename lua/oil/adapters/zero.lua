--- oil.nvim adapter for zero-nvim remote editing.
--- Placed at lua/oil/adapters/zero.lua so oil.nvim can discover it
--- via require("oil.adapters.zero").
---
--- URL scheme: zero://user@host:port/remote/path
--- (port defaults to 22 if omitted)

-- oil modules are required lazily so that merely requiring this file (e.g.
-- a health check or test without oil installed) doesn't error out.
local function oil(mod)
  return require("oil." .. mod)
end

local uri = require("zero-nvim.uri")
local buffer_io = require("zero-nvim.buffer_io")

local M = {}

---@class (exact) oil.zeroUrl
---@field scheme string
---@field user string
---@field host string
---@field port integer
---@field path string

---Parse a zero:// URL into its components.
---oil.nvim calls util.parse_url(oil_url) which splits scheme and path,
---then passes the full oil_url to this function.
---@param oil_url string
---@return oil.zeroUrl
M.parse_url = function(oil_url)
  -- Fast path: the shared parser (handles IPv6 [addr] hosts, default port).
  local u, h, p, path = uri.parse(oil_url)
  if u then
    return { scheme = "zero://", user = u, host = h, port = p, path = uri.normalize_path(path) }
  end

  local scheme, url = oil("util").parse_url(oil_url)
  assert(scheme and url, string.format("Malformed zero url: '%s'", oil_url))

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
    error(string.format("Malformed zero url: %s", oil_url))
  end

  ---@cast ret oil.zeroUrl
  return ret
end

---Convert a parsed URL back to a string
---@param url oil.zeroUrl
---@return string
local function url_to_str(url)
  if url.user and url.user ~= "" and url.port then
    return uri.format(url.user, url.host, url.port, uri.normalize_path(url.path))
  end
  local pieces = { url.scheme }
  if url.user and url.user ~= "" then
    table.insert(pieces, url.user)
    table.insert(pieces, "@")
  end
  table.insert(pieces, url.host)
  -- Always include port for canonical URI format.
  -- Omitting port=22 causes mismatches with daemon-produced URIs (which always
  -- include the explicit port), leading to duplicate buffers on LSP jump.
  if url.port then
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
  res.path = uri.parent_dir(res.path)
  return url_to_str(res)
end

---@param url string
---@param callback fun(url: string)
M.normalize_url = function(url, callback)
  local res = M.parse_url(url)
  -- Ensure directory paths end with /
  -- (prefetched URIs are known files: skip the stat round-trip)
  if not vim.endswith(res.path, "/") and not get_zero()._has_prefetched(url_to_str(res)) then
    -- We need to stat to know if it's a directory
    local ok, ftype = get_zero().request(res.user, res.host, res.port, "stat", res.path)
    if ok and ftype == "directory" then
      res.path = res.path .. "/"
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

    local cache = oil("cache")
    local FIELD_META = oil("constants").FIELD_META
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
  -- Synchronous on purpose: oil's BufWriteCmd returns right after this, and
  -- :wq / :x need 'modified' cleared by then. Shared with the builtin
  -- BufWriteCmd (load-failure guard, eol/fileformat handling, reconnect).
  local loading = oil("loading")
  loading.set_loading(bufnr, true)
  local ok, err = pcall(get_zero().write_buffer, bufnr, vim.api.nvim_buf_get_name(bufnr),
    { bang = vim.v.cmdbang == 1 })
  loading.set_loading(bufnr, false)
  if not ok then
    vim.notify("Save failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end

---@param url string
---@param type "file"|"directory"
---@param callback fun(err?: string)
M.create_entry = function(url, type, callback)
  local res = M.parse_url(url)
  local zero = get_zero()

  -- Prevent creating files ending with / (Oil handles normalization but just in case)
  if type == "file" and vim.endswith(res.path, "/") then
    return callback("File path ends with /")
  end

  vim.schedule(function()
    local ok, ret
    if type == "directory" then
      ok, ret = zero.request_interactive(res.user, res.host, res.port, "mkdir", res.path)
    else
      -- Create empty file
      ok, ret = zero.request_interactive(res.user, res.host, res.port, "write_file", res.path, "")
    end
    if ok and ret == true then callback() else callback(tostring(ret or "RPC failed")) end
  end)
end

---@param url string
---@param callback fun(err?: string)
M.delete_entry = function(url, callback)
  local res = M.parse_url(url)
  local zero = get_zero()

  vim.schedule(function()
    local function rm(method)
      local ok, ret = zero.request_interactive(res.user, res.host, res.port, method, res.path)
      if ok and ret == true then return nil end
      if ok then return "Delete failed: unexpected reply " .. tostring(ret) end
      return tostring(ret)
    end

    -- Oil passes directory URLs with a trailing "/": go straight to rmdir.
    if vim.endswith(url, "/") then
      return callback(rm("remove_dir"))
    end

    -- Otherwise assume a file; fall back to rmdir in case it's a directory
    -- whose URL lost its slash. Report the file error if both fail — that is
    -- the operation the user actually asked for.
    local file_err = rm("remove_file")
    if not file_err then return callback() end
    if not rm("remove_dir") then return callback() end
    callback(file_err)
  end)
end

---@param src_url string
---@param dst_url string
---@param callback fun(err?: string)
M.rename_entry = function(src_url, dst_url, callback)
  local res_src = M.parse_url(src_url)
  local res_dst = M.parse_url(dst_url)
  local zero = get_zero()

  -- rename is a single SFTP op on one connection: src and dst must share it.
  if res_src.user ~= res_dst.user or res_src.host ~= res_dst.host
      or tonumber(res_src.port) ~= tonumber(res_dst.port) then
    return callback(string.format(
      "Cannot move across different remotes (%s@%s:%s -> %s@%s:%s); copy + delete instead",
      res_src.user, res_src.host, tostring(res_src.port), res_dst.user, res_dst.host, tostring(res_dst.port)))
  end

  vim.schedule(function()
    local ok, ret = zero.request_interactive(res_src.user, res_src.host, res_src.port, "rename",
      res_src.path, res_dst.path)
    if ok and ret == true then callback() else callback(tostring(ret or "Rename failed")) end
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

local function detect_filetype(bufnr, bufname)
  if vim.bo[bufnr].filetype == "" or vim.bo[bufnr].filetype == "oil" then
    local basename = oil("pathutil").basename(bufname)
    local filetype = vim.filetype.match({ buf = bufnr, filename = basename })
    if filetype then
      vim.bo[bufnr].filetype = filetype
    end
  end
end

---@param bufnr integer
M.read_file = function(bufnr)
  local loading = oil("loading")
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local zero = get_zero()

  -- Fast path: if the buffer was already populated (e.g. by an earlier load),
  -- DON'T re-fetch and DON'T re-set lines. nvim_buf_set_lines(0, -1, ...)
  -- replacing ALL lines causes Neovim to reset the cursor in any window
  -- displaying the buffer to (1,0) — clobbering the LSP target.
  local lc = vim.api.nvim_buf_line_count(bufnr)
  local already_loaded = vim.b[bufnr].zero_loaded and (lc > 1 or
    (lc == 1 and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] ~= ""))
  -- Content prefetched by zero-nvim's LSP-location preload: apply it
  -- synchronously (no extra round-trip, cursor stays where LSP puts it).
  local prefetched = not already_loaded and zero._take_prefetched(bufname) or nil
  if already_loaded or prefetched then
    loading.set_loading(bufnr, false)
    if prefetched then
      vim.cmd.doautocmd({ args = { "BufReadPre", bufname }, mods = { silent = true } })
      buffer_io.apply(bufnr, prefetched)
    else
      vim.bo[bufnr].modifiable = true
      vim.bo[bufnr].modified = false
    end
    detect_filetype(bufnr, bufname)
    vim.cmd.doautocmd({ args = { "BufReadPost", bufname }, mods = { silent = true } })
    return
  end

  loading.set_loading(bufnr, true)
  local res = M.parse_url(bufname)

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local ok, fetched = zero.request(res.user, res.host, res.port, "fetch_path", res.path)
    loading.set_loading(bufnr, false)

    vim.cmd.doautocmd({ args = { "BufReadPre", bufname }, mods = { silent = true } })

    if ok and type(fetched) == "table" and fetched[1] == "file" then
      buffer_io.apply(bufnr, buffer_io.to_bytes(fetched[2]) or "")
    elseif not ok and buffer_io.is_missing_error(fetched) then
      -- New file: empty, writable
      buffer_io.apply(bufnr, "")
      vim.b[bufnr].zero_new_file = true
    else
      -- Never put the error text into the buffer: a later :w would write it
      -- over the real file. Leave it empty + non-modifiable; BufWriteCmd
      -- refuses to save it (unless :w!).
      buffer_io.mark_failed(bufnr)
      local msg = ok and ("not a regular file: " .. res.path) or tostring(fetched)
      vim.notify("ZeroNvim: Failed to read " .. res.path .. ": " .. msg
        .. " (buffer is read-only; :e to retry)", vim.log.levels.ERROR)
      return
    end

    detect_filetype(bufnr, bufname)
    vim.cmd.doautocmd({ args = { "BufReadPost", bufname }, mods = { silent = true } })
  end)
end

return M
