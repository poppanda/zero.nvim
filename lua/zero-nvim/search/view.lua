--- :ZeroSearch 的绘制层：四窗口浮窗布局（path / query / results / preview）、
--- 按键、结果树渲染、预览渲染。状态与搜索调度都在 search/init.lua。
local float = require("zero-nvim.ui.float")
local util = require("zero-nvim.util")
local icons = require("zero-nvim.ui.icons")
local buffer_io = require("zero-nvim.buffer_io")
local type_picker = require("zero-nvim.search.type_picker")

local M = {}

local DEBOUNCE_MS = 350
local ns = vim.api.nvim_create_namespace("ZeroSearchUI")
local cursor_ns = vim.api.nvim_create_namespace("zero_search_cursor")

local WINHL = {
    prompt = "NormalFloat:TelescopePromptNormal,FloatBorder:TelescopePromptBorder",
    results = "NormalFloat:TelescopeResultsNormal,FloatBorder:TelescopeResultsBorder",
    preview = "NormalFloat:TelescopePreviewNormal,FloatBorder:TelescopePreviewBorder",
}

local WIN_FIELD = { path = "path_win", query = "input_win", results = "results_win" }

local function define_highlights()
    for name, val in pairs({
        ZeroSearchMatch = { fg = "#61afef", bold = true },
        ZeroSearchCount = { fg = "#e5c07b" },
        ZeroSearchLineNr = { fg = "#5c6370" },
        ZeroSearchSep = { fg = "#5c6370" },
    }) do
        val.default = true
        vim.api.nvim_set_hl(0, name, val)
    end
end

-- =============================================================================
-- 窗口 / 按键
-- =============================================================================

--- 聚焦某个输入/结果窗口并记录到 session.focus
---@param name "path"|"query"|"results"
function M.focus(session, name)
    local win = session[WIN_FIELD[name]]
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        session.focus = name
    end
end

--- 按 session.toggle_state 刷新 path（类型）和 query（Aa / word）两个 footer
local function update_footers(session)
    local ts = session.toggle_state
    if vim.api.nvim_win_is_valid(session.input_win) then
        vim.api.nvim_win_set_config(session.input_win,
            { footer = float.toggle_footer(ts.case_sensitive, ts.whole_word), footer_pos = "right" })
    end
    if vim.api.nvim_win_is_valid(session.path_win) then
        local label = #ts.file_types == 0 and "*" or table.concat(ts.file_types, ",")
        vim.api.nvim_win_set_config(session.path_win,
            { footer = string.format("  [%s] C-t:Type  ", label), footer_pos = "right" })
    end
end

local function open_win(buf, enter, cfg, winhl)
    local win = vim.api.nvim_open_win(buf, enter, vim.tbl_extend("force", {
        relative = "editor",
        style = "minimal",
        border = "rounded",
        title_pos = "center",
    }, cfg))
    vim.wo[win].winhl = winhl
    return win
end

--- 输入 buffer 改动后防抖回调。timer 由 search.close_ui teardown 时关闭；
--- 关闭后 on_lines 返回 true 自动 detach。
local function debounce_on_lines(buf, cb)
    local timer = (vim.uv or vim.loop).new_timer()
    vim.api.nvim_buf_attach(buf, false, {
        on_lines = function()
            if timer:is_closing() then return true end
            timer:stop()
            timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
                if not timer:is_closing() then cb() end
            end))
        end,
    })
    return timer
end

--- 创建并打开搜索 UI，窗口 / buffer / timer / augroup 字段直接写进 session。
---@param session table 需已含 toggle_state = { case_sensitive, whole_word, file_types }
---@param opts { title: string, path: string, query: string }
---@param cb table { on_change, on_close, on_enter, on_select_next, on_select_prev, on_toggle_fold }
function M.open(session, opts, cb)
    define_highlights()
    local ew, eh = util.editor_size()
    local w, h = math.floor(ew * 0.85), math.floor(eh * 0.85)
    local r, c = math.floor((eh - h) / 2), math.floor((ew - w) / 2)
    local rw = math.floor(w * 0.4)
    local body_h = h - 6

    session.path_buf = vim.api.nvim_create_buf(false, true)
    session.input_buf = vim.api.nvim_create_buf(false, true)
    session.results_buf = vim.api.nvim_create_buf(false, true)
    session.preview_buf = vim.api.nvim_create_buf(false, true)

    session.path_win = open_win(session.path_buf, true, {
        row = r, col = c, width = w, height = 1,
        title = string.format(" 📂 Search Path (%s) ", opts.title),
    }, WINHL.prompt)
    session.input_win = open_win(session.input_buf, false, {
        row = r + 3, col = c, width = w, height = 1,
        title = " 🔍 Keywords ",
    }, WINHL.prompt)
    session.results_win = open_win(session.results_buf, false, {
        row = r + 6, col = c, width = rw, height = body_h,
        title = " Results ",
        footer = " j/k/h/l:Nav | C-w:Word | C-c:Case ", footer_pos = "left",
    }, WINHL.results)
    vim.wo[session.results_win].cursorline = false
    session.preview_win = open_win(session.preview_buf, false, {
        row = r + 6, col = c + rw + 2, width = w - rw - 2, height = body_h,
        title = " Preview ",
        footer = " CR:Open | i:Insert | q/Esc:Quit ", footer_pos = "right",
    }, WINHL.preview)

    vim.bo[session.results_buf].modifiable = false
    vim.bo[session.preview_buf].modifiable = false
    vim.api.nvim_buf_set_lines(session.path_buf, 0, -1, false, { opts.path })
    vim.api.nvim_buf_set_lines(session.input_buf, 0, -1, false, { opts.query })
    vim.api.nvim_win_set_cursor(session.input_win, { 1, #opts.query })
    update_footers(session)

    -- 先写入初始内容再 attach，避免恢复上次 query 时触发一次防抖搜索
    session.timer1 = debounce_on_lines(session.path_buf, cb.on_change)
    session.timer2 = debounce_on_lines(session.input_buf, cb.on_change)

    local ts = session.toggle_state
    local function toggle(field)
        return function()
            ts[field] = not ts[field]
            update_footers(session)
            cb.on_change()
        end
    end
    local function open_type_picker()
        vim.cmd("stopinsert")
        type_picker.open({
            row = r + 3,
            col = c + w - 30,
            selected = ts.file_types,
            on_close = function(types)
                ts.file_types = types
                update_footers(session)
                M.focus(session, "query")
                cb.on_change()
            end,
        })
    end
    local function focus(name) return function() M.focus(session, name) end end
    local function prev_or_query()
        if cb.on_select_prev() then M.focus(session, "query") end
    end

    -- 三个 buffer 共用的按键
    for _, buf in ipairs({ session.path_buf, session.input_buf, session.results_buf }) do
        local o = { buffer = buf, silent = true }
        local now = { buffer = buf, silent = true, nowait = true }
        vim.keymap.set("n", "q", cb.on_close, o)
        vim.keymap.set("n", "<Esc>", cb.on_close, o)
        -- C-c 切大小写（不是关闭）
        vim.keymap.set({ "i", "n" }, "<C-c>", toggle("case_sensitive"), now)
        vim.keymap.set({ "i", "n" }, "<C-w>", toggle("whole_word"), now)
        vim.keymap.set({ "i", "n" }, "<C-t>", open_type_picker, now)
        -- 只有 path / query 输入框里 i 才进 insert
        vim.keymap.set("n", "i", function()
            local cur = vim.api.nvim_get_current_win()
            if cur == session.path_win or cur == session.input_win then vim.cmd("startinsert") end
        end, o)
        -- insert 里 Esc → 跳到结果
        vim.keymap.set("i", "<Esc>", function()
            vim.cmd("stopinsert")
            M.focus(session, "results")
        end, o)
        vim.keymap.set({ "i", "n" }, "<CR>", cb.on_enter, o)
    end

    -- 各窗口的导航：path ↓ query ↓ results；results 顶部再 k 回 query
    local nav = {
        [session.path_buf] = { j = focus("query"), ["<Down>"] = focus("query"), J = focus("query") },
        [session.input_buf] = {
            k = focus("path"), ["<Up>"] = focus("path"), K = focus("path"),
            j = focus("results"), ["<Down>"] = focus("results"), J = focus("results"),
        },
        [session.results_buf] = {
            k = prev_or_query, ["<Up>"] = prev_or_query,
            j = cb.on_select_next, ["<Down>"] = cb.on_select_next,
            K = focus("query"), J = focus("path"),
            h = cb.on_toggle_fold, l = cb.on_toggle_fold,
            ["<Left>"] = cb.on_toggle_fold, ["<Right>"] = cb.on_toggle_fold,
        },
    }
    for buf, maps in pairs(nav) do
        for lhs, fn in pairs(maps) do
            vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true })
        end
    end

    -- 任一浮窗被关闭（非 q/<Esc> 路径）→ 整个 UI 一起关；augroup 由 search.close_ui 删除
    session.augroup = float.on_any_closed(
        { session.path_win, session.input_win, session.results_win, session.preview_win }, cb.on_close)

    M.focus(session, "query")
    vim.cmd("startinsert!")
end

--- 新一轮搜索前清空结果 / 预览两个 buffer
function M.clear(session)
    util.set_lines(session.results_buf, {})
    util.set_lines(session.preview_buf, {})
    if vim.api.nvim_buf_is_valid(session.results_buf) then
        vim.api.nvim_buf_clear_namespace(session.results_buf, ns, 0, -1)
    end
end

-- =============================================================================
-- 结果树
-- =============================================================================

--- 从第 start_char 个字符（0-based）起，取显示宽度 <= budget 的最长子串。
--- 整串调用 strdisplaywidth，不再逐字符切分。
local function fit_chars(text, start_char, budget)
    if budget <= 0 then return "" end
    local n = budget
    local sub = vim.fn.strcharpart(text, start_char, n)
    local w = vim.fn.strdisplaywidth(sub)
    while w > budget and n > 0 do
        n = n - math.max(1, math.floor((w - budget) / 2))
        sub = vim.fn.strcharpart(text, start_char, n)
        w = vim.fn.strdisplaywidth(sub)
    end
    return sub
end

--- 取 text 尾部显示宽度 <= budget 的最长后缀（目录前缀截断用）。
local function fit_tail(text, budget)
    if budget <= 0 then return "" end
    local total = vim.fn.strchars(text)
    local start = math.max(0, total - budget)
    local sub = vim.fn.strcharpart(text, start)
    local w = vim.fn.strdisplaywidth(sub)
    while w > budget and start < total do
        start = start + math.max(1, math.floor((w - budget) / 2))
        sub = vim.fn.strcharpart(text, start)
        w = vim.fn.strdisplaywidth(sub)
    end
    return sub
end

--- 把匹配行截到 max_w 显示宽度，尽量让 col0（0-based 字节）处的匹配可见。
---@return string display_text
---@return integer text_offset  原文字节偏移 - 显示串字节偏移（用于高亮换算）
local function truncate_around(text, col0, max_w)
    local ellipsis = "..."
    local budget = max_w - 2 * #ellipsis
    if budget < 1 then
        return fit_chars(text, 0, math.max(0, max_w)), 0
    end
    local total = vim.fn.strchars(text)
    local mc = vim.fn.strchars(text:sub(1, col0))
    -- 匹配前保留约 1/3 预算的上下文
    local left = math.max(0, mc - math.floor(budget / 3))
    local sub = fit_chars(text, left, budget)
    if left > 0 and left + vim.fn.strchars(sub) >= total then
        -- 右侧已到行尾：向左回填，但不越过匹配起点
        local tail = fit_tail(text, budget)
        local tail_left = total - vim.fn.strchars(tail)
        if tail_left < left then
            left = math.min(tail_left, mc)
            sub = fit_chars(text, left, budget)
        end
    end
    local need_left = left > 0
    local need_right = left + vim.fn.strchars(sub) < total
    local display = (need_left and ellipsis or "") .. sub .. (need_right and ellipsis or "")
    local left_byte = #vim.fn.strcharpart(text, 0, left)
    return display, left_byte - (need_left and #ellipsis or 0)
end

--- 文件头行："<fold> <icon> name dir/...   [N matches]"，目录过长时截左边
local function file_header(file_obj, win_width, add, marks)
    local filepath = file_obj.file
    local filename = vim.fs.basename(filepath)
    local dirpath = filepath:sub(1, #filepath - #filename)
    local count = #file_obj.matches

    local head = string.format("%s %s ", file_obj.expanded and "" or "",
        icons.for_ext(filename:match("%.([^%.]+)$")))
    local name_part = head .. filename .. " "
    local count_text = string.format("[%d match%s]", count, count > 1 and "es" or "")
    local name_w = vim.fn.strdisplaywidth(name_part)
    local count_w = vim.fn.strdisplaywidth(count_text)
    local display_dir = dirpath
    local max_dir_w = win_width - name_w - count_w - 2
    if vim.fn.strdisplaywidth(dirpath) > max_dir_w and max_dir_w > 3 then
        display_dir = "..." .. fit_tail(dirpath, max_dir_w - 3)
    end
    local padding = string.rep(" ", math.max(1, win_width - name_w - vim.fn.strdisplaywidth(display_dir) - count_w - 1))
    local line = name_part .. display_dir .. padding .. count_text

    local row = add(line, { type = "file", file = filepath, ref = file_obj })
    table.insert(marks, { row, 0, #head + #filename, "Title" })
    table.insert(marks, { row, #name_part, #name_part + #display_dir, "Comment" })
    table.insert(marks, { row, #line - #count_text, #line, "ZeroSearchCount" })
end

--- 匹配行："  12 │ text"，超宽时围绕匹配位置截断
local function match_row(file, match, win_width, fallback_len, add, marks)
    local lnum_str = string.format("%4d", match.lnum)
    local prefix = lnum_str .. " │ "
    local max_text_width = win_width - vim.fn.strdisplaywidth(prefix)
    local text = match.text
    local col0 = math.max(0, match.col - 1) -- col 是 1-based

    local display_text, text_offset = text, 0
    if #text > max_text_width and vim.fn.strdisplaywidth(text) > max_text_width then
        display_text, text_offset = truncate_around(text, col0, max_text_width)
    end
    local line = prefix .. display_text
    local row = add(line, { type = "match", file = file, lnum = match.lnum, col = match.col })

    table.insert(marks, { row, 0, #lnum_str, "ZeroSearchLineNr" })
    table.insert(marks, { row, #lnum_str + 1, #lnum_str + 1 + #"│", "ZeroSearchSep" })
    local match_start = #prefix + col0 - text_offset
    local match_end = math.min(match_start + (match.match_len or fallback_len), #line)
    if match.col > 0 and match_start >= #prefix and match_end > match_start then
        table.insert(marks, { row, match_start, match_end, "ZeroSearchMatch" })
    end
end

--- 把 session.files 画进结果窗口。
---@param truncated_at? integer 非 nil 时末尾追加 "truncated at N" 提示
---@return table[] nodes 每行一个：{type="file"|"match"|"spacer", file, lnum, col, ref}
function M.render_results(session, truncated_at)
    local nodes, lines, marks = {}, {}, {} -- marks: { row, col, end_col, hl_group }
    local function add(line, node)
        table.insert(lines, line)
        table.insert(nodes, node)
        return #lines - 1
    end

    local win_width = vim.api.nvim_win_is_valid(session.results_win)
        and vim.api.nvim_win_get_width(session.results_win) or 60

    for fi, file_obj in ipairs(session.files) do
        file_header(file_obj, win_width, add, marks)
        if file_obj.expanded then
            for _, match in ipairs(file_obj.matches) do
                match_row(file_obj.file, match, win_width, #session.query, add, marks)
            end
        end
        if fi < #session.files then add("", { type = "spacer" }) end
    end

    if truncated_at and #lines > 0 then
        add("", { type = "spacer" })
        local row = add(string.format("  ... truncated at %d matches (refine the query)", truncated_at),
            { type = "spacer" })
        table.insert(marks, { row, 0, #lines[#lines], "Comment" })
    end

    local buf = session.results_buf
    if vim.api.nvim_buf_is_valid(buf) then
        util.set_lines(buf, #lines == 0 and { "  0 results found." } or lines)
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        for _, m in ipairs(marks) do
            pcall(vim.api.nvim_buf_set_extmark, buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
        end
    end
    return nodes
end

--- 结果窗口光标 + CursorLine 高亮移到第 idx 行
function M.highlight_row(session, idx)
    if vim.api.nvim_win_is_valid(session.results_win) then
        pcall(vim.api.nvim_win_set_cursor, session.results_win, { idx, 0 })
    end
    local buf = session.results_buf
    if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, cursor_ns, 0, -1)
        pcall(vim.api.nvim_buf_add_highlight, buf, cursor_ns, "CursorLine", idx - 1, 0, -1)
    end
end

-- =============================================================================
-- 预览
-- =============================================================================

--- 把文件内容画进预览窗口；match 节点定位到匹配行并高亮整行。
---@param node table  render_results 产出的 file / match 节点
---@param content string|false|nil  非 string（没有选中 / 读取失败）= 清空预览
function M.show_preview(session, node, content)
    local buf = session.preview_buf
    if type(content) ~= "string" then return util.set_lines(buf, {}) end
    if not vim.api.nvim_buf_is_valid(buf) then return end

    util.set_lines(buf, (buffer_io.content_to_lines(content)))
    local ft = vim.filetype.match({ filename = node.file })
    if ft then pcall(vim.api.nvim_set_option_value, "filetype", ft, { buf = buf }) end

    local win = session.preview_win
    if not vim.api.nvim_win_is_valid(win) then return end
    local is_match = node.type == "match"
    pcall(vim.api.nvim_win_set_cursor, win, { is_match and node.lnum or 1, is_match and math.max(0, node.col - 1) or 0 })
    vim.api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if is_match then
        pcall(vim.api.nvim_buf_add_highlight, buf, ns, "Search", node.lnum - 1, 0, -1)
    end
end

return M
