--- :ZeroSearchMini 的两个浮窗（输入 / 结果）与渲染。状态在 search_mini/init.lua。
local float = require("zero-nvim.ui.float")
local util = require("zero-nvim.util")

local M = {}

local WIDTH = 50

--- 结果行前缀：普通模式一行一个匹配；替换模式每个匹配两行（🟥 原文 / 🟩 替换后）
---@param kind? "old"|"new"  nil = 普通模式
local function row_prefix(kind, lnum)
    local mark = kind == "old" and " 🟥 " or kind == "new" and " 🟩 " or "  "
    return string.format("%s%4d: ", mark, lnum)
end

--- 输入框第 2 行（替换串）；未开替换时为 ""
local function replacement(state)
    if not state.show_replace or not vim.api.nvim_buf_is_valid(state.input_buf) then return "" end
    return vim.api.nvim_buf_get_lines(state.input_buf, 1, 2, false)[1] or ""
end

local function clear(buf, ns)
    if buf and vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1) end
end

local function hl(buf, ns, group, row, s, e)
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, group, row, s, e)
end

--- 可重入 teardown：q/<Esc>/<CR> 或任一浮窗被外部关闭（WinClosed）都走这里。
function M.close_ui(state)
    if state.closed then return end
    state.closed = true
    -- 先删 augroup，下面主动关窗时不再回调
    if state.augroup then
        pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
        state.augroup = nil
    end
    float.close(state.input_win, state.input_buf)
    float.close(state.results_win, state.results_buf)
    clear(state.source_buf, state.ns_id)
    util.close_timer(state.timer)
    state.timer = nil
    vim.cmd("stopinsert")
    state.active = false
end

--- 跳到 state.selected_index 对应的匹配：移动源窗口光标 + 刷新源 / 结果高亮
function M.jump_to_match(state)
    local match = state.matches[state.selected_index]
    if not match then return end
    if vim.api.nvim_win_is_valid(state.source_win) then
        vim.api.nvim_win_set_cursor(state.source_win, { match.lnum, match.col })
        vim.api.nvim_win_call(state.source_win, function() vim.cmd("normal! zz") end)
    end

    if vim.api.nvim_buf_is_valid(state.source_buf) then
        clear(state.source_buf, state.ns_id)
        hl(state.source_buf, state.ns_id, "IncSearch", match.lnum - 1, match.col, match.end_col)
    end

    local per = state.show_replace and 2 or 1
    local sel_row = (state.selected_index - 1) * per
    if vim.api.nvim_win_is_valid(state.results_win) then
        pcall(vim.api.nvim_win_set_cursor, state.results_win, { sel_row + 1, 0 })
    end
    local buf = state.results_buf
    if not vim.api.nvim_buf_is_valid(buf) then return end
    clear(buf, state.ns_id)
    local rep_len = #replacement(state)
    for i, m in ipairs(state.matches) do
        local row = (i - 1) * per
        if state.show_replace then
            local p_old, p_new = #row_prefix("old", m.lnum), #row_prefix("new", m.lnum)
            hl(buf, state.ns_id, "DiagnosticError", row, p_old + m.col, p_old + m.end_col)
            hl(buf, state.ns_id, "DiagnosticOk", row + 1, p_new + m.col, p_new + m.col + rep_len)
        else
            local p = #row_prefix(nil, m.lnum)
            hl(buf, state.ns_id, "IncSearch", row, p + m.col, p + m.end_col)
        end
    end
    -- CursorLine 只给选中的匹配（替换模式两行）
    for r = sel_row, sel_row + per - 1 do
        hl(buf, state.ns_id, "CursorLine", r, 0, -1)
    end
end

function M.render_results(state)
    if not state.active then return end
    local buf = state.results_buf
    if not vim.api.nvim_buf_is_valid(buf) then return end

    local lines = {}
    local rep = replacement(state)
    for _, m in ipairs(state.matches) do
        if state.show_replace then
            table.insert(lines, row_prefix("old", m.lnum) .. m.text)
            table.insert(lines, row_prefix("new", m.lnum) .. m.text:sub(1, m.col) .. rep .. m.text:sub(m.end_col + 1))
        else
            table.insert(lines, row_prefix(nil, m.lnum) .. m.text)
        end
    end
    util.set_lines(buf, #lines > 0 and lines or { "  0 results found." })

    if vim.api.nvim_win_is_valid(state.results_win) then
        vim.api.nvim_win_set_config(state.results_win, { height = state.show_replace and 10 or 5 })
    end

    if #state.matches > 0 then
        M.jump_to_match(state)
    else
        clear(buf, state.ns_id)
        clear(state.source_buf, state.ns_id)
    end
end

function M.render_input(state)
    if not state.active then return end
    clear(state.input_buf, state.ns_id)

    local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
    local placeholders = { "Find:", state.show_replace and "Replace:" or nil }
    for i, text in pairs(placeholders) do
        if (lines[i] or "") == "" then
            pcall(vim.api.nvim_buf_set_extmark, state.input_buf, state.ns_id, i - 1, 0, {
                virt_text = { { text, "Comment" } },
                virt_text_pos = "overlay",
                hl_mode = "combine",
            })
        end
    end

    if vim.api.nvim_win_is_valid(state.input_win) then
        pcall(vim.api.nvim_win_set_config, state.input_win,
            { footer = float.toggle_footer(state.case_sensitive, state.whole_word), footer_pos = "right" })
    end
end

--- 替换模式下输入框上移成两行、结果区变高
local LAYOUT = {
    [false] = { input_dr = 0, input_h = 1, results_dr = 3, results_h = 5,
        footer = " C-r:Replace | C-c:Case | C-w:Word " },
    [true] = { input_dr = -6, input_h = 2, results_dr = -2, results_h = 10,
        footer = " r:Replace | C-r:Replace | C-c:Case | C-w:Word " },
}

function M.toggle_replace(state)
    if not state.active then return end
    state.show_replace = not state.show_replace
    local l = LAYOUT[state.show_replace]

    if vim.api.nvim_win_is_valid(state.input_win) then
        vim.api.nvim_win_set_config(state.input_win,
            { relative = "editor", row = state.base_row + l.input_dr, col = state.base_col, height = l.input_h })
    end
    if vim.api.nvim_win_is_valid(state.results_win) then
        vim.api.nvim_win_set_config(state.results_win, {
            relative = "editor",
            row = state.base_row + l.results_dr,
            col = state.base_col,
            height = l.results_h,
            footer = l.footer,
            footer_pos = "left",
        })
    end
    local count = vim.api.nvim_buf_line_count(state.input_buf)
    if state.show_replace then
        if count < 2 then vim.api.nvim_buf_set_lines(state.input_buf, 1, 1, false, { "" }) end
        pcall(vim.api.nvim_win_set_cursor, state.input_win, { 2, 0 })
    else
        pcall(vim.api.nvim_win_set_cursor, state.input_win, { 1, 0 })
        if count > 1 then vim.api.nvim_buf_set_lines(state.input_buf, 1, -1, false, {}) end
    end

    M.render_input(state)
    M.render_results(state)
end

function M.create_ui(state)
    local ew, eh = util.editor_size()
    local r, c = eh - 10, ew - WIDTH - 2 -- 右下角
    state.base_row, state.base_col = r, c

    state.input_buf = vim.api.nvim_create_buf(false, true)
    state.input_win = vim.api.nvim_open_win(state.input_buf, true, {
        relative = "editor",
        row = r,
        col = c,
        width = WIDTH,
        height = 1,
        style = "minimal",
        border = { "╭", "─", "╮", "│", "┤", "─", "├", "│" },
        title = " 󰍉 Mini Search ",
        title_pos = "center",
        footer = float.toggle_footer(false, false),
        footer_pos = "right",
    })

    state.results_buf = vim.api.nvim_create_buf(false, true)
    state.results_win = vim.api.nvim_open_win(state.results_buf, false, {
        relative = "editor",
        row = r + 3,
        col = c,
        width = WIDTH,
        height = 5,
        style = "minimal",
        border = { "", "", "", "│", "╯", "─", "╰", "│" },
        footer = LAYOUT[false].footer,
        footer_pos = "left",
    })

    -- 任一浮窗被关（:q / <C-w>o 等）→ 两个一起关并清理 timer / 高亮
    state.augroup = float.on_any_closed({ state.input_win, state.results_win }, function() M.close_ui(state) end)

    vim.wo[state.input_win].winhl = "NormalFloat:TelescopePromptNormal,FloatBorder:TelescopePromptBorder"
    vim.wo[state.input_win].wrap = false
    vim.wo[state.results_win].winhl = "NormalFloat:TelescopeResultsNormal,FloatBorder:TelescopeResultsBorder"
    vim.wo[state.results_win].wrap = false
    vim.wo[state.results_win].cursorline = false
    vim.bo[state.results_buf].modifiable = false
end

return M
