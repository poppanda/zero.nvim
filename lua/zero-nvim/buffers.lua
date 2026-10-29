--- zero:// buffer 生命周期：读取 / 写回 / 目录视图 / readfile() 补丁 / 预取 stash /
--- filetype 检测，以及相关的全部 buffer autocmd（含 oil 兼容的那几条）。
local uri = require("zero-nvim.uri")
local log = require("zero-nvim.log")
local remote = require("zero-nvim.remote")
local buffer_io = require("zero-nvim.buffer_io")

local M = {}

-- 批量预取的文件内容，key 为规范化 URI。BufReadCmd / oil read_file 读取时
-- 优先消费这里的内容（一次性），避免 LSP 跳转时每个文件再单独 fetch 一次。
local prefetched = {}

local readfile_patched = false

-- ---------------------------------------------------------------------------
-- 预取 stash
-- ---------------------------------------------------------------------------

local function stash_key(name) return uri.normalize(name) or name end

---@param name string zero:// URI
---@param content string
function M.stash(name, content)
    prefetched[stash_key(name)] = content
end

--- Consume prefetched content for a URI (one-shot).
---@return string?
function M.take_prefetched(name)
    local key = stash_key(name)
    local content = prefetched[key]
    prefetched[key] = nil
    return content
end

---@return boolean
function M.has_prefetched(name)
    return prefetched[stash_key(name)] ~= nil
end

-- ---------------------------------------------------------------------------
-- 小工具
-- ---------------------------------------------------------------------------

--- Find a buffer by its exact name (vim.fn.bufnr() does pattern matching,
--- which misfires on names containing wildcards or a "zero://" prefix).
---@param name string
---@return integer?
function M.find_buf(name)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b) == name then return b end
    end
    return nil
end

--- 按路径 + 前几行内容（shebang / 无扩展名文件）检测并设置 filetype。
---@param buf integer
---@param path string remote path
---@return string? ft
function M.detect_filetype(buf, path)
    if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].zero_is_dir then return nil end
    local ft = vim.filetype.match({ filename = path, contents = vim.api.nvim_buf_get_lines(buf, 0, 5, false) })
    if ft and ft ~= "" and vim.bo[buf].filetype ~= ft then
        vim.bo[buf].filetype = ft
    end
    return ft
end

--- Rename `buf` to `new_name` without clobbering the window's alternate file,
--- then wipe the placeholder buffer `:file` leaves behind for the old name.
local function rename_buffer(buf, new_name)
    local old_name = vim.api.nvim_buf_get_name(buf)
    if old_name == new_name then return end
    local ok = pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("keepalt noautocmd file " .. vim.fn.fnameescape(new_name))
    end)
    if not ok then return end
    vim.schedule(function()
        local old = M.find_buf(old_name)
        if old and old ~= buf and not vim.api.nvim_buf_is_loaded(old) and vim.fn.bufwinid(old) == -1 then
            pcall(vim.api.nvim_buf_delete, old, { force = true })
        end
    end)
end

--- `buf` is an alias (non-canonical name) of the already existing `target`
--- buffer: keep it empty/unwritable, move its windows to `target`, wipe it.
local function redirect_alias(buf, target)
    buffer_io.mark_failed(buf)
    vim.b[buf].zero_alias_of = target
    vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_valid(target) then return end
        for _, w in ipairs(vim.fn.win_findbuf(buf)) do
            pcall(vim.api.nvim_win_set_buf, w, target)
        end
        if vim.fn.bufwinid(buf) == -1 then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end)
end

--- 把 buf 改名为规范名 `canon`；已有同名 buffer 时把 buf 当别名重定向过去。
---@return boolean ok false = buf 已被重定向，调用方不要再加载
local function claim_name(buf, canon)
    local existing = M.find_buf(canon)
    if existing and existing ~= buf then
        redirect_alias(buf, existing)
        return false
    end
    rename_buffer(buf, canon)
    return true
end

-- ---------------------------------------------------------------------------
-- 读取
-- ---------------------------------------------------------------------------

---@alias zero.Fetched { type: "file", content: string }|{ type: "new" }|{ type: "directory" }

--- 读取远端路径（不碰 buffer）。优先消费预取 stash；远端不存在的文件路径
--- 返回 { type = "new" }（与 :e newfile 一致）。
---@param interactive? boolean 需要密码时允许同步弹出输入（用户主动操作）
---@return zero.Fetched? res
---@return string? err
function M.fetch(user, host, port, path, interactive)
    local content = M.take_prefetched(uri.format(user, host, port, path))
    if content then return { type = "file", content = content } end

    local request = interactive and remote.request_interactive or remote.request
    local ok, res = request(user, host, port, "fetch_path", path)
    if not ok then
        if not path:match("/$") and buffer_io.is_missing_error(res) then return { type = "new" } end
        return nil, tostring(res)
    end
    local kind = type(res) == "table" and res[1]
    if kind == "file" then return { type = "file", content = buffer_io.to_bytes(res[2]) or "" } end
    if kind == "directory" then return { type = "directory" } end
    return nil, "unexpected daemon reply"
end

--- 把 fetch 结果写进文件 buffer。失败（或拿到的是目录）时 buffer 保持为空、
--- 不可修改并标记 b:zero_load_failed，之后的 :w 不会截断远端文件。
---@param res zero.Fetched?
---@param err? string
---@return boolean ok
function M.apply_fetched(buf, path, res, err)
    if res and res.type == "file" then
        -- 不设 readonly：bufload / BufRead / 折叠操作之后会触发 W10。
        -- buflisted 在 BufWinEnter 时才设（只为 quickfix 预加载的 buffer 不该出现在 tab 栏）。
        buffer_io.apply(buf, res.content)
        return true
    elseif res and res.type == "new" then
        buffer_io.apply(buf, "")
        vim.b[buf].zero_new_file = true
        log.info("[New] " .. path)
        return true
    end
    buffer_io.mark_failed(buf)
    log.error(string.format("Failed to read %s: %s (buffer is read-only; :e to retry)",
        path, err or "not a regular file"))
    return false
end

local function render_dir(buf, user, host, port, path, entries)
    local lines = { '" Remote Directory: ' .. path, '" Press <CR> to open, R to refresh, .. to go up', "", " \239\132\149 ../" }
    local entry_map = { [#lines] = { name = "..", type = "directory" } }
    table.sort(entries, function(a, b)
        if a.type ~= b.type then return a.type == "directory" end
        return a.name < b.name
    end)
    for _, entry in ipairs(entries) do
        local is_dir = entry.type == "directory"
        table.insert(lines, (is_dir and " \239\132\149 " or " \239\133\155 ") .. entry.name .. (is_dir and "/" or ""))
        entry_map[#lines] = entry
    end
    local bo = vim.bo[buf]
    bo.modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    bo.modified = false
    bo.modifiable = false
    bo.readonly = true
    bo.filetype = "netrw"
    vim.b[buf].zero_is_dir = true
    vim.b[buf].zero_loaded = true
    vim.b[buf].zero_load_failed = nil

    vim.keymap.set("n", "<CR>", function()
        local entry = entry_map[vim.fn.line(".")]
        if not entry then return end
        local new_path = entry.name == ".." and uri.parent_dir(path)
            or uri.join(path, entry.name, entry.type == "directory")
        vim.cmd("edit " .. vim.fn.fnameescape(uri.format(user, host, port, new_path)))
    end, { buffer = buf, silent = true })
    vim.keymap.set("n", "R", function() M.load(buf, user, host, port, path) end, { buffer = buf, silent = true })
end

--- Load remote `path` into `buf` synchronously (file content or directory view).
---@return boolean ok
function M.load(buf, user, host, port, path)
    local res, err = M.fetch(user, host, port, path, true)
    if not res or res.type ~= "directory" then
        return M.apply_fetched(buf, path, res, err)
    end
    -- 目录 buffer 名统一以 "/" 结尾，".." / 子目录拼接才不会出错
    local dir = uri.as_dir(path)
    if dir ~= path and not claim_name(buf, uri.format(user, host, port, dir)) then
        return false
    end
    local entries, list_err = remote.list_dir(user, host, port, dir)
    if not entries then
        buffer_io.mark_failed(buf)
        log.error("Failed to list " .. dir .. ": " .. tostring(list_err))
        return false
    end
    render_dir(buf, user, host, port, dir, entries)
    return true
end

--- Read handler for a zero:// buffer (BufReadCmd). Canonicalizes the buffer
--- name first so zero://u@h/p and zero://u@h:22/p share one buffer.
local function read_buffer(buf, name)
    local canon = uri.normalize(name)
    if not canon or (canon ~= name and not claim_name(buf, canon)) then return end
    local user, host, port, path = uri.parse(canon)
    if M.load(buf, user, host, port, path) and not vim.b[buf].zero_is_dir then
        -- filetype 在这里设而不是 load 里：BufReadCmd 触发时 window 已切到这个
        -- buffer，TreeSitter / syntax 的 on_win decoration provider 才能挂上。
        M.detect_filetype(buf, path)
        -- BufReadCmd 取代了 BufRead —— 下游（gitsigns attach 等）需要显式 BufReadPost。
        vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf, modeline = false })
    end
end

-- ---------------------------------------------------------------------------
-- 写回
-- ---------------------------------------------------------------------------

--- Write `buf` (or lines [first, last] of it) to the zero:// URI `target`.
--- Shared by BufWriteCmd / FileWriteCmd / FileAppendCmd and the oil adapter.
---
--- Rules:
---   • 写到 buffer 自己的名字且整个 buffer 写成功 → 清 'modified' + BufWritePost
---   • 写到别的 URI（:w zero://other）→ 不动当前 buffer 的 'modified'
---   • buffer 从未成功加载（b:zero_load_failed）→ 拒绝写，`:w!` 可强制覆盖
---   • 写失败 → 把 'modified' 置位，让 :wq / :x 停下来而不是丢掉修改
---@param opts? { first?: integer, last?: integer, append?: boolean, bang?: boolean }
---@return boolean ok
function M.write_buffer(buf, target, opts)
    opts = opts or {}
    local canon = uri.normalize(target)
    if not canon then
        log.error("Invalid zero:// target: " .. tostring(target))
        return false
    end
    local user, host, port, path = uri.parse(canon)
    local own = uri.normalize(vim.api.nvim_buf_get_name(buf)) == canon

    if path:match("/$") or (own and vim.b[buf].zero_is_dir) then
        log.error("Cannot write a directory: " .. path)
        return false
    end
    if own and vim.b[buf].zero_load_failed and not opts.bang then
        log.error(string.format(
            "Refusing to write %s: the remote file was never loaded successfully (use :w! to overwrite it)", path))
        return false
    end

    local content, whole = buffer_io.buffer_content(buf, opts.first, opts.last)
    if opts.append then
        local old, err = M.fetch(user, host, port, path, true)
        if not old or old.type == "directory" then
            log.error("Append failed: " .. tostring(err or "not a regular file"))
            return false
        end
        content = (old.content or "") .. content
        whole = false
    end

    local ok, res = remote.request_interactive(user, host, port, "write_file", path, content)
    local full_own = own and whole
    if ok and res == true then
        if full_own then
            vim.bo[buf].modified = false
            vim.b[buf].zero_load_failed = nil
            vim.b[buf].zero_new_file = nil
            vim.b[buf].zero_loaded = true
            vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf, modeline = false })
        end
        log.info(string.format('"%s" %dB written', path, #content))
        return true
    end

    log.error("Save failed: " .. tostring(res))
    -- BufWriteCmd 返回时 buffer 仍是 modified → Vim 视为写失败，:wq 不会退出
    if full_own then vim.bo[buf].modified = true end
    return false
end

-- ---------------------------------------------------------------------------
-- readfile() 补丁
-- ---------------------------------------------------------------------------

--- vim.fn.readfile() replacement for zero:// paths (honours {type} and {max}).
---@return string[]
function M.readfile(fname, ftype, max)
    local canon = uri.normalize(fname)
    local user, host, port, path = uri.parse(canon or "")
    if not user then error("E484: Can't open file " .. fname, 0) end

    local content
    local b = M.find_buf(canon)
    if b and buffer_io.is_loaded(b) and not vim.bo[b].modified and not vim.b[b].zero_is_dir then
        content = buffer_io.buffer_content(b)
    else
        local res = M.fetch(user, host, port, path)
        if not res or res.type ~= "file" then error("E484: Can't open file " .. fname, 0) end
        content = res.content
    end

    local lines = vim.split(content, "\n", { plain = true })
    if not (type(ftype) == "string" and ftype:find("b", 1, true)) then
        -- readfile(): 末尾换行不产生额外空项；NL 前的 CR 去掉
        if lines[#lines] == "" then table.remove(lines) end
        for i, l in ipairs(lines) do lines[i] = (l:gsub("\r$", "")) end
    end
    -- readfile() 里 NUL 以 NL 表示
    for i, l in ipairs(lines) do lines[i] = (l:gsub("%z", "\n")) end

    max = tonumber(max)
    if not max then return lines end
    if max >= 0 then return { unpack(lines, 1, math.min(max, #lines)) } end
    return { unpack(lines, math.max(1, #lines + max + 1), #lines) }
end

-- ---------------------------------------------------------------------------
-- autocmds
-- ---------------------------------------------------------------------------

-- oil 把这些 win-local 选项钉在 window 上 (oil/view.lua:set_win_options)；从 oil
-- 列表选文件后 buffer 换了选项却没换（gitsigns 因 signcolumn="no" 不 attach、
-- wrap=false 让 markdown ftplugin 失效）。
local OIL_WINOPTS = {
    "signcolumn", "wrap", "cursorcolumn", "foldcolumn",
    "spell", "list", "conceallevel", "concealcursor",
}

local function setup_oil_compat(group)
    -- 只在 explorer="oil" 时注册：别的模式没人跑 set_win_options，多余的 reset
    -- 反而会抹掉 BufReadCmd 路径里用户 ftplugin 的 setlocal。目录 buffer 是
    -- oil 自己的列表，保留它的样式。须注册在下面 BufWinEnter 之前：oil 流里
    -- ftplugin 在 FileType=oil 拦截器 schedule 之后才 setlocal，不会被复位。
    vim.api.nvim_create_autocmd("BufWinEnter", {
        pattern = "zero://*",
        group = group,
        callback = function(args)
            if args.file:match("/$") then return end
            local win = vim.api.nvim_get_current_win()
            if vim.api.nvim_win_get_buf(win) ~= args.buf then return end
            for _, opt in ipairs(OIL_WINOPTS) do
                local default = vim.api.nvim_get_option_value(opt, { scope = "global" })
                vim.api.nvim_set_option_value(opt, default, { scope = "local", win = win })
            end
        end,
    })
end

--- 注册所有 zero:// buffer autocmd（到 init.lua 已清空的 ZeroNvim 组）并安装
--- readfile() 补丁。explorer = "oil" 时 BufReadCmd / BufWriteCmd 交给 oil 的
--- adapter（两边都注册会无限刷新）。
---@param group integer
---@param explorer string
function M.setup(group, explorer)
    local function on(event, opts)
        opts.group = group
        if opts.pattern == nil then opts.pattern = "zero://*" end
        vim.api.nvim_create_autocmd(event, opts)
    end

    -- zero:// buffer 是虚拟的：swap 文件救不回任何东西，而残留的 swap（上次
    -- nvim 崩溃留下的）还会让加载卡在 E325 ATTENTION。oil / builtin 共用。
    on("BufNew", { callback = function(args) vim.bo[args.buf].swapfile = false end })
    on("SwapExists", { callback = function() vim.v.swapchoice = "e" end })

    -- 文件内容只在 BufReadCmd 里加载一次；LSP 跳转路径由 lsp/locations.lua 预取。
    if explorer ~= "oil" then
        on("BufReadCmd", { callback = function(args) read_buffer(args.buf, args.match) end })
        -- 同步写入：:wq / :x 依赖 BufWriteCmd 返回时 'modified' 已复位，否则 E37。
        on("BufWriteCmd", {
            callback = function(args)
                M.write_buffer(args.buf, args.match, { bang = vim.v.cmdbang == 1 })
            end,
        })
    else
        setup_oil_compat(group)
    end

    -- :{range}w zero://... / :w >> zero://... —— '[ '] 标出范围。oil 不处理
    -- 这两个事件，两种 explorer 都注册。
    on({ "FileWriteCmd", "FileAppendCmd" }, {
        callback = function(args)
            local first = vim.api.nvim_buf_get_mark(args.buf, "[")[1]
            local last = vim.api.nvim_buf_get_mark(args.buf, "]")[1]
            M.write_buffer(args.buf, args.match, {
                first = first > 0 and first or nil,
                last = last > 0 and last or nil,
                append = args.event == "FileAppendCmd",
                bang = vim.v.cmdbang == 1,
            })
        end,
    })

    -- 用户真正打开时才 list（设 buflisted 会触发 BufAdd，barbar / bufferline 靠它
    -- 注册 tab）；bufload() 的临时 autocmd window 里不算。filetype 仍为空时补检测
    -- （oil 路径从不触发我们的 BufReadCmd）。
    on("BufWinEnter", {
        callback = function(args)
            local buf = args.buf
            if vim.fn.win_gettype() ~= "autocmd" and not vim.bo[buf].buflisted then
                pcall(vim.api.nvim_set_option_value, "buflisted", true, { buf = buf })
            end
            if args.file:match("/$") or vim.bo[buf].filetype ~= "" then return end
            local _, _, _, path = uri.parse(args.file)
            if path then M.detect_filetype(buf, path) end
        end,
    })

    -- oil 会给它管理的所有 zero:// buffer（包括文件）设 filetype=oil，盖掉正确的
    -- filetype。schedule 到 oil 处理完之后再改回来。
    on("FileType", {
        pattern = "oil",
        callback = function(args)
            local name = vim.api.nvim_buf_get_name(args.buf)
            local _, _, _, path = uri.parse(name)
            if not path or path:match("/$") then return end
            local buf = args.buf
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "oil" then
                    M.detect_filetype(buf, path)
                end
            end)
        end,
    })

    -- 第三方插件（引用查看 / 代码预览）直接用 readfile() 读文件，绕过 BufReadCmd。
    -- 只拦 Lua 侧调用；Vimscript 的 :call readfile() 走 C 内建，不受影响。
    if not readfile_patched then
        readfile_patched = true
        local orig = vim.fn.readfile
        vim.fn.readfile = function(path, ...)
            if uri.is_zero(path) then return M.readfile(path, ...) end
            return orig(path, ...)
        end
    end
end

return M
