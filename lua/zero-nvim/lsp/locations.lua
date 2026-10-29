--- LSP 跳转 / 引用结果里的 zero:// 位置预加载。
---
--- Neovim 0.11 的 definition 流程：on_response → util.locations_to_items →
--- vim.uri_to_bufnr → bufadd（空的 unlisted buffer）→ nvim_win_set_buf +
--- nvim_win_set_cursor —— buffer 没内容时 set_cursor 直接报错。所以在
--- locations_to_items（schedule 回调里，无 textlock）这一层先把内容装好。
local uri = require("zero-nvim.uri")
local log = require("zero-nvim.log")
local remote = require("zero-nvim.remote")
local buffers = require("zero-nvim.buffers")
local buffer_io = require("zero-nvim.buffer_io")

local M = {}

local installed = false

local JUMP_METHODS = {
    ["textDocument/definition"] = true,
    ["textDocument/declaration"] = true,
    ["textDocument/typeDefinition"] = true,
    ["textDocument/implementation"] = true,
    ["textDocument/references"] = true,
}

--- 把 locations 里的 zero:// URI 原地规范化（vim.uri_to_bufnr 才会落到
--- BufReadCmd 用的同一个 buffer 上），返回缺内容的文件 URI（去重）。
local function collect(locations)
    local needed, seen = {}, {}
    for _, loc in ipairs(locations) do
        local field = type(loc) == "table"
            and ((type(loc.uri) == "string" and "uri") or (type(loc.targetUri) == "string" and "targetUri"))
        local canon = field and uri.is_zero(loc[field]) and uri.normalize(loc[field])
        if canon then
            loc[field] = canon
            if not seen[canon] and not canon:match("/$") then
                seen[canon] = true
                local b = buffers.find_buf(canon)
                if not (b and vim.api.nvim_buf_is_loaded(b)) or vim.b[b].zero_load_failed then
                    table.insert(needed, canon)
                end
            end
        end
    end
    return needed
end

--- 每台主机一次 fetch_paths，内容放进 buffers 的预取 stash。
local function fetch_all(uris)
    local hosts = {}
    for _, canon in ipairs(uris) do
        local u, h, p, path = uri.parse(canon)
        local key = uri.target_key(u, h, p)
        hosts[key] = hosts[key] or { user = u, host = h, port = p, paths = {}, uris = {} }
        table.insert(hosts[key].paths, path)
        table.insert(hosts[key].uris, canon)
    end
    for key, hd in pairs(hosts) do
        log.debug(string.format("Batch fetching %d files from %s", #hd.paths, key))
        local ok, content_map = remote.request(hd.user, hd.host, hd.port, "fetch_paths", hd.paths)
        if ok and type(content_map) == "table" then
            for i, path in ipairs(hd.paths) do
                local content = buffer_io.to_bytes(content_map[path])
                if content then buffers.stash(hd.uris[i], content) end
            end
        else
            log.warn("Batch fetch failed: " .. tostring(content_map))
        end
    end
end

--- Make sure the zero:// buffers referenced by LSP locations hold content
--- before Neovim's LSP code reads them. Buffers are `bufload`ed (BufReadCmd /
--- oil's read_file consume the stash) and stay unlisted: BufWinEnter lists
--- them once the user actually opens one.
---@param locations table[]
function M.preload(locations)
    if type(locations) ~= "table" then return end
    local needed = collect(locations)
    if #needed == 0 then return end
    fetch_all(needed)
    for _, canon in ipairs(needed) do
        local b = buffers.find_buf(canon) or vim.fn.bufadd(canon)
        if not vim.api.nvim_buf_is_loaded(b) then
            pcall(vim.fn.bufload, b)
        else -- 之前加载失败过：就地重新加载
            local u, h, p, path = uri.parse(canon)
            pcall(buffers.load, b, u, h, p, path)
        end
        buffers.take_prefetched(canon) -- 未被消费（例如 oil 走了别的路径）就丢弃
    end
end

--- 单个位置跳转的光标兜底：某些 adapter（oil 的异步 read_file）在 LSP 设好光标
--- 之后才整体替换内容，Neovim 会把显示该 buffer 的 window 光标复位到 (1,0)。
local function resnap_cursor(locations)
    if type(locations) ~= "table" or #locations ~= 1 then return end
    local loc = locations[1]
    local target = loc.uri or loc.targetUri
    local range = loc.range or loc.targetSelectionRange
    if not uri.is_zero(target) or not (range and range.start) then return end
    local buf = buffers.find_buf(target)
    if not buf then return end
    local want_line = (range.start.line or 0) + 1
    local want_char = range.start.character or 0
    vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        for _, w in ipairs(vim.fn.win_findbuf(buf)) do
            if vim.api.nvim_win_get_cursor(w)[1] ~= want_line then
                local lnum = math.min(want_line, math.max(1, vim.api.nvim_buf_line_count(buf)))
                local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
                pcall(vim.api.nvim_win_set_cursor, w, { lnum, math.min(want_char, #line) })
                pcall(vim.api.nvim_win_call, w, function() vim.cmd("normal! zv") end)
            end
        end
    end)
end

--- 安装两个补丁（幂等）：
---   • vim.lsp.util.locations_to_items —— buf.lua 的 on_response 通过表字段查找
---     调它，所以即使按键映射在 setup 之前就捕获了 vim.lsp.buf.definition 也生效。
---   • vim.lsp.buf_request_all —— 第三方引用 / 预览插件（code-view.nvim 等）直接
---     调它再 io.open(uri)；io.open 读不了 zero://，但它们一般先找同名的已加载 buffer。
function M.install()
    if installed then return end
    installed = true

    local orig_lti = vim.lsp.util.locations_to_items
    vim.lsp.util.locations_to_items = function(locations, offset_encoding)
        local ok, err = pcall(M.preload, locations)
        if not ok then log.debug("Preloading LSP locations failed: " .. tostring(err)) end
        resnap_cursor(locations)
        return orig_lti(locations, offset_encoding)
    end

    local orig_brall = vim.lsp.buf_request_all
    vim.lsp.buf_request_all = function(bufnr, method, params, handler)
        if not JUMP_METHODS[method] then
            return orig_brall(bufnr, method, params, handler)
        end
        return orig_brall(bufnr, method, params, function(results, ctx)
            local locs = {}
            for _, r in pairs(results or {}) do
                local res = r and r.result
                if type(res) == "table" then
                    if res.uri or res.targetUri then
                        table.insert(locs, res)
                    else
                        vim.list_extend(locs, res)
                    end
                end
            end
            pcall(M.preload, locs)
            return handler(results, ctx)
        end)
    end
end

return M
