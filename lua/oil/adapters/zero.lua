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
local log = require("zero-nvim.log")
local remote = require("zero-nvim.remote")
local buffers = require("zero-nvim.buffers")

local M = {}

---@class (exact) oil.zeroUrl
---@field scheme string
---@field user string
---@field host string
---@field port integer
---@field path string

---Parse a zero:// URL into its components.
---@param oil_url string
---@return oil.zeroUrl
M.parse_url = function(oil_url)
  local u, h, p, path = uri.parse(oil_url)
  if not u then error(string.format("Malformed zero url: '%s'", oil_url)) end
  return { scheme = "zero://", user = u, host = h, port = p, path = uri.normalize_path(path) }
end

---Canonical URL string (explicit port: omitting :22 would mismatch
---daemon-produced URIs and create duplicate buffers on LSP jump).
---@param url oil.zeroUrl
---@return string
local function url_to_str(url)
  return uri.format(url.user, url.host, url.port, uri.normalize_path(url.path))
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
  -- 目录路径要以 / 结尾，得 stat 一下（预取过的 URI 已知是文件，跳过）
  if not vim.endswith(res.path, "/") and not buffers.has_prefetched(url_to_str(res)) then
    local ok, ftype = remote.request(res.user, res.host, res.port, "stat", res.path)
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
  vim.schedule(function()
    local entries_data, err = remote.list_dir(res.user, res.host, res.port, res.path)
    if not entries_data then
      callback(err or "Failed to list directory")
      return
    end

    local cache = oil("cache")
    local FIELD_META = oil("constants").FIELD_META
    local cache_entries = {}
    for _, entry in ipairs(entries_data) do
      local cache_entry = cache.create_entry(url, entry.name, entry.type == "directory" and "directory" or "file")
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
  local ok, err = pcall(buffers.write_buffer, bufnr, vim.api.nvim_buf_get_name(bufnr),
    { bang = vim.v.cmdbang == 1 })
  loading.set_loading(bufnr, false)
  if not ok then
    log.error("Save failed: " .. tostring(err))
  end
end

--- 远端操作的统一回调：成功（返回 true）→ callback()，否则 callback(err)。
local function run(res, callback, method, ...)
  local args = { ... }
  vim.schedule(function()
    local ok, ret = remote.request_interactive(res.user, res.host, res.port, method, unpack(args))
    if ok and ret == true then callback() else callback(tostring(ret or (method .. " failed"))) end
  end)
end

---@param url string
---@param type "file"|"directory"
---@param callback fun(err?: string)
M.create_entry = function(url, type, callback)
  local res = M.parse_url(url)
  if type == "directory" then
    return run(res, callback, "mkdir", res.path)
  end
  -- Prevent creating files ending with / (Oil handles normalization but just in case)
  if vim.endswith(res.path, "/") then
    return callback("File path ends with /")
  end
  run(res, callback, "write_file", res.path, "")
end

---@param url string
---@param callback fun(err?: string)
M.delete_entry = function(url, callback)
  local res = M.parse_url(url)

  vim.schedule(function()
    local function rm(method)
      local ok, ret = remote.request_interactive(res.user, res.host, res.port, method, res.path)
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
    if not file_err or not rm("remove_dir") then return callback() end
    callback(file_err)
  end)
end

---@param src_url string
---@param dst_url string
---@param callback fun(err?: string)
M.rename_entry = function(src_url, dst_url, callback)
  local src = M.parse_url(src_url)
  local dst = M.parse_url(dst_url)

  -- rename is a single SFTP op on one connection: src and dst must share it.
  if uri.target_key(src.user, src.host, src.port) ~= uri.target_key(dst.user, dst.host, dst.port) then
    return callback(string.format(
      "Cannot move across different remotes (%s -> %s); copy + delete instead",
      uri.target_key(src.user, src.host, src.port), uri.target_key(dst.user, dst.host, dst.port)))
  end
  run(src, callback, "rename", src.path, dst.path)
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

--- BufReadPre → 写内容 → filetype → BufReadPost（oil 自己的 BufReadCmd 不会替我们触发）
local function finish_read(bufnr, bufname, path, res, err)
  vim.cmd.doautocmd({ args = { "BufReadPre", bufname }, mods = { silent = true } })
  if not buffers.apply_fetched(bufnr, path, res, err) then return end
  if vim.bo[bufnr].filetype == "" or vim.bo[bufnr].filetype == "oil" then
    buffers.detect_filetype(bufnr, path)
  end
  vim.cmd.doautocmd({ args = { "BufReadPost", bufname }, mods = { silent = true } })
end

---@param bufnr integer
M.read_file = function(bufnr)
  local loading = oil("loading")
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local url = M.parse_url(bufname)

  -- Fast path: if the buffer was already populated (e.g. by an earlier load),
  -- DON'T re-fetch and DON'T re-set lines. nvim_buf_set_lines(0, -1, ...)
  -- replacing ALL lines causes Neovim to reset the cursor in any window
  -- displaying the buffer to (1,0) — clobbering the LSP target.
  local lc = vim.api.nvim_buf_line_count(bufnr)
  if vim.b[bufnr].zero_loaded and (lc > 1 or vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] ~= "") then
    loading.set_loading(bufnr, false)
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].modified = false
    if vim.bo[bufnr].filetype == "" or vim.bo[bufnr].filetype == "oil" then
      buffers.detect_filetype(bufnr, url.path)
    end
    vim.cmd.doautocmd({ args = { "BufReadPost", bufname }, mods = { silent = true } })
    return
  end

  -- Content prefetched by the LSP-location preload: apply it synchronously
  -- (no extra round-trip, cursor stays where LSP puts it).
  if buffers.has_prefetched(bufname) then
    loading.set_loading(bufnr, false)
    return finish_read(bufnr, bufname, url.path, buffers.fetch(url.user, url.host, url.port, url.path))
  end

  loading.set_loading(bufnr, true)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local res, err = buffers.fetch(url.user, url.host, url.port, url.path, true)
    loading.set_loading(bufnr, false)
    finish_read(bufnr, bufname, url.path, res, err)
  end)
end

return M
