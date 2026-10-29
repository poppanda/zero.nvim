--- :ZeroSearchMini：当前 buffer 内的字面查找 / 替换（右下角小浮窗）。
local ui = require("zero-nvim.search_mini.view")
local log = require("zero-nvim.log")

local M = {}

local state = {
    active = false,
}

local per_buf_queries = {}

M.MAX_MATCHES = 2000

--- 把用户输入转成 vim 正则：very-nomagic（\V）下只有 `\` 是特殊字符，
--- `[` `.` `*` `~` `/` 全部按字面匹配。
---@param query string
---@param opts { case_sensitive?: boolean, whole_word?: boolean }
---@param min_col? integer  0-based 字节列：要求匹配起点 >= min_col
---@return string
function M._build_pattern(query, opts, min_col)
    local body = (query:gsub("\\", "\\\\"))
    if opts.whole_word then
        body = "\\<" .. body .. "\\>"
    end
    local col = ""
    if min_col and min_col > 0 then
        -- \%>Nc：1-based 列 > N ⇔ 0-based 起点 >= N
        col = "\\%>" .. min_col .. "c"
    end
    return "\\V" .. (opts.case_sensitive and "\\C" or "\\c") .. col .. body
end

--- 在 buf 中查找 query 的全部字面匹配。
--- 注意：regex:match_line(buf, lnum, start) 的 start 会把行首截掉再匹配，
--- `\<` 在截断点上会误判成词边界（"foofoo" 第二个 foo 被当成整词）。
--- 所以同一行的后续匹配改为整行匹配 + `\%>Nc` 列约束。
---@return table[]? matches  { lnum, col, end_col, text }；pattern 非法返回 nil
function M._find_matches(buf, query, opts, max)
    max = max or M.MAX_MATCHES
    local ok, base = pcall(vim.regex, M._build_pattern(query, opts))
    if not ok then return nil end

    local matches = {}
    for i = 1, vim.api.nvim_buf_line_count(buf) do
        local line_text = nil
        local regex = base
        while true do
            local s, e = regex:match_line(buf, i - 1)
            if not (s and e and e > s) then break end
            line_text = line_text or vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
            table.insert(matches, { lnum = i, col = s, end_col = e, text = line_text })
            if #matches >= max then return matches end
            if e >= #line_text then break end
            local ok2, next_re = pcall(vim.regex, M._build_pattern(query, opts, e))
            if not ok2 then break end
            regex = next_re
        end
    end
    return matches
end

local function execute_search()
    if not state.active or not vim.api.nvim_buf_is_valid(state.input_buf) then return end
    if not vim.api.nvim_buf_is_valid(state.source_buf) then return end

    local query = vim.api.nvim_buf_get_lines(state.input_buf, 0, 1, false)[1] or ""
    per_buf_queries[state.source_buf] = query

    local matches = query ~= "" and M._find_matches(state.source_buf, query, {
        case_sensitive = state.case_sensitive,
        whole_word = state.whole_word,
    }) or {}
    state.matches = matches
    if #matches == 0 then
        state.selected_index = 0
    elseif state.selected_index == 0 or state.selected_index > #matches then
        state.selected_index = 1
    end
    ui.render_results(state)
end

local function do_replace()
    if not state.active or not vim.api.nvim_buf_is_valid(state.source_buf) then return end
    local match = state.matches[state.selected_index]
    if not match then return end
    local replacement = vim.api.nvim_buf_get_lines(state.input_buf, 1, 2, false)[1] or ""
    local line = vim.api.nvim_buf_get_lines(state.source_buf, match.lnum - 1, match.lnum, false)[1]
    if not line then return end
    vim.api.nvim_buf_set_lines(state.source_buf, match.lnum - 1, match.lnum, false,
        { line:sub(1, match.col) .. replacement .. line:sub(match.end_col + 1) })
    -- 重新搜索刷新匹配位置；当前匹配被替换掉后自然前进到下一个
    execute_search()
end

--- 选中第 idx 个匹配（越界不动）并跳过去
local function select(idx)
    if idx < 1 or idx > #state.matches then return false end
    state.selected_index = idx
    ui.jump_to_match(state)
    return true
end

local function set_cursor_line(win, delta)
    local pos = vim.api.nvim_win_get_cursor(win)
    vim.api.nvim_win_set_cursor(win, { pos[1] + delta, pos[2] })
end

--- 挂上两个 buffer 的按键
local function setup_keymaps()
    local input_buf, results_buf = state.input_buf, state.results_buf
    local function close() ui.close_ui(state) end
    local function toggle(field)
        return function()
            state[field] = not state[field]
            ui.render_input(state)
            execute_search()
        end
    end

    for _, buf in ipairs({ input_buf, results_buf }) do
        local o = { buffer = buf, silent = true, nowait = true }
        vim.keymap.set("n", "q", close, o)
        vim.keymap.set("n", "<Esc>", close, o)
        vim.keymap.set({ "i", "n" }, "<C-c>", toggle("case_sensitive"), o)
        vim.keymap.set({ "i", "n" }, "<C-w>", toggle("whole_word"), o)
        vim.keymap.set({ "i", "n" }, "<C-r>", function() ui.toggle_replace(state) end, o)
    end

    local input_maps = {
        -- 查找行：循环前进；替换行：替换当前并前进
        { { "i", "n" }, "<CR>", function()
            if vim.api.nvim_win_get_cursor(0)[1] == 2 then return do_replace() end
            if #state.matches > 0 then select(state.selected_index % #state.matches + 1) end
        end },
        -- 最后一行再 j 进入结果窗口
        { "n", "j", function()
            if vim.api.nvim_win_get_cursor(0)[1] < vim.api.nvim_buf_line_count(0) then
                set_cursor_line(0, 1)
            elseif vim.api.nvim_win_is_valid(state.results_win) then
                vim.api.nvim_set_current_win(state.results_win)
            end
        end },
        { "n", "k", function()
            if vim.api.nvim_win_get_cursor(0)[1] > 1 then set_cursor_line(0, -1) end
        end },
        { "n", "i", function() vim.cmd("startinsert") end },
        { "i", "<Esc>", function() vim.cmd("stopinsert") end },
    }
    local results_maps = {
        { "n", "j", function() select(state.selected_index + 1) end },
        -- 第一项再 k 回到输入框最后一行
        { "n", "k", function()
            if select(state.selected_index - 1) or not vim.api.nvim_win_is_valid(state.input_win) then return end
            vim.api.nvim_set_current_win(state.input_win)
            pcall(vim.api.nvim_win_set_cursor, state.input_win, { vim.api.nvim_buf_line_count(input_buf), 0 })
        end },
        { "n", "r", function() if state.show_replace then do_replace() end end },
        { "n", "<CR>", function()
            local match = state.matches[state.selected_index]
            if not match then return end
            local win = state.source_win
            close()
            if win and vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_set_current_win(win)
                pcall(vim.api.nvim_win_set_cursor, win, { match.lnum, match.col })
                vim.api.nvim_win_call(win, function() vim.cmd("normal! zvzz") end)
            end
        end },
    }
    for buf, maps in pairs({ [input_buf] = input_maps, [results_buf] = results_maps }) do
        for _, m in ipairs(maps) do
            vim.keymap.set(m[1], m[2], m[3], { buffer = buf, silent = true })
        end
    end

    -- 两个字段在边界处编辑时不能合并：第 2 行行首 <BS> / 第 1 行行尾 <Del> 吞掉
    vim.keymap.set("i", "<BS>", function()
        local pos = vim.api.nvim_win_get_cursor(state.input_win)
        return pos[1] == 2 and pos[2] == 0 and "" or "<BS>"
    end, { buffer = input_buf, expr = true, silent = true })
    vim.keymap.set("i", "<Del>", function()
        local pos = vim.api.nvim_win_get_cursor(state.input_win)
        local line = vim.api.nvim_buf_get_lines(input_buf, pos[1] - 1, pos[1], false)[1] or ""
        return pos[1] == 1 and pos[2] == #line and "" or "<Del>"
    end, { buffer = input_buf, expr = true, silent = true })
end

--- 输入防抖 + 粘贴换行修复（字段数必须保持 1 或 2 行）
local function attach_input(session)
    local input_buf = session.input_buf
    session.timer = (vim.uv or vim.loop).new_timer()
    vim.api.nvim_buf_attach(input_buf, false, {
        on_lines = function(_, _, _, first, last, new_last)
            if not session.active or not session.timer then return true end
            session.timer:stop()
            -- on_lines 处于 textlock：粘贴进来的换行延后修复
            local extra = new_last - last
            vim.schedule(function()
                if not session.active or not vim.api.nvim_buf_is_valid(input_buf) then return end
                local expected = session.show_replace and 2 or 1
                if extra > 0 and vim.api.nvim_buf_line_count(input_buf) > expected then
                    local pasted = vim.api.nvim_buf_get_lines(input_buf, first, new_last, false)
                    vim.api.nvim_buf_set_lines(input_buf, first, new_last, false, { table.concat(pasted, " ") })
                end
                local count = vim.api.nvim_buf_line_count(input_buf)
                if count < expected then
                    vim.api.nvim_buf_set_lines(input_buf, count, count, false, { "" })
                end
            end)
            session.timer:start(150, 0, vim.schedule_wrap(function()
                if not session.active then return end
                ui.render_input(session)
                execute_search()
            end))
        end,
    })
end

function M.open()
    local source_buf = vim.api.nvim_get_current_buf()
    local has_text = false
    for _, line in ipairs(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)) do
        if line ~= "" then
            has_text = true
            break
        end
    end
    if not has_text then
        log.info("SearchMini: buffer is empty")
        return
    end

    if state.active then ui.close_ui(state) end

    local query = per_buf_queries[source_buf] or ""
    if query == "" then query = vim.fn.expand("<cword>") end

    state = {
        active = true,
        source_buf = source_buf,
        source_win = vim.api.nvim_get_current_win(),
        show_replace = false,
        case_sensitive = false,
        whole_word = false,
        matches = {},
        selected_index = 0,
        ns_id = vim.api.nvim_create_namespace("ZeroSearchMini"),
    }

    ui.create_ui(state)
    if query ~= "" then
        vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { query })
        vim.api.nvim_win_set_cursor(state.input_win, { 1, #query })
    end
    setup_keymaps()
    attach_input(state)

    ui.render_input(state)
    execute_search()
    vim.cmd("startinsert!")
end

return M
