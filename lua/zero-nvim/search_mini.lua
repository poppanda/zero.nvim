local ui = require("zero-nvim.ui.search_mini")

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
    local line_count = vim.api.nvim_buf_line_count(buf)
    for i = 1, line_count do
        local start_idx = 0
        local line_text = nil
        local regex = base
        while true do
            local s, e = regex:match_line(buf, i - 1)
            if not (s and e and e > s) then break end
            if not line_text then
                line_text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
            end
            table.insert(matches, { lnum = i, col = s, end_col = e, text = line_text })
            if #matches >= max then return matches end
            start_idx = e
            if start_idx >= #line_text then break end
            local ok2, next_re = pcall(vim.regex, M._build_pattern(query, opts, start_idx))
            if not ok2 then break end
            regex = next_re
        end
    end
    return matches
end

local function execute_search()
    if not state.active then return end
    if not vim.api.nvim_buf_is_valid(state.input_buf) then return end

    local query = vim.api.nvim_buf_get_lines(state.input_buf, 0, 1, false)[1] or ""

    if vim.api.nvim_buf_is_valid(state.source_buf) then
        per_buf_queries[state.source_buf] = query
    end

    if query == "" then
        state.matches = {}
        state.selected_index = 0
        ui.render_results(state)
        return
    end

    if not vim.api.nvim_buf_is_valid(state.source_buf) then return end
    local matches = M._find_matches(state.source_buf, query, {
        case_sensitive = state.case_sensitive,
        whole_word = state.whole_word,
    })
    if not matches then
        state.matches = {}
        state.selected_index = 0
        ui.render_results(state)
        return
    end

    state.matches = matches
    if #matches > 0 then
        if state.selected_index == 0 or state.selected_index > #matches then
            state.selected_index = 1
        end
    else
        state.selected_index = 0
    end

    ui.render_results(state)
end

local function do_replace()
    if not state.active or state.selected_index == 0 or #state.matches == 0 then return end
    local match = state.matches[state.selected_index]

    local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
    local replacement = lines[2] or ""

    if not vim.api.nvim_buf_is_valid(state.source_buf) then return end

    local source_line = vim.api.nvim_buf_get_lines(state.source_buf, match.lnum - 1, match.lnum, false)[1]
    if source_line then
        local new_line = source_line:sub(1, match.col) .. replacement .. source_line:sub(match.end_col + 1)
        vim.api.nvim_buf_set_lines(state.source_buf, match.lnum - 1, match.lnum, false, { new_line })

        -- After replacement, re-run search to update matches and cursor positions
        -- It naturally advances if the cursor was on the first one and it got consumed
        execute_search()
    end
end

function M.open()
    local source_buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
    local source_win = vim.api.nvim_get_current_win()

    -- Check if empty
    local is_empty = true
    for _, line in ipairs(lines) do
        if line ~= "" then
            is_empty = false
            break
        end
    end

    if is_empty then
        vim.notify("ZeroSearchMini: Buffer is empty", vim.log.levels.INFO)
        return
    end

    if state.active then ui.close_ui(state) end

    local preserved_query = per_buf_queries[source_buf] or ""
    if preserved_query == "" then
        preserved_query = vim.fn.expand("<cword>")
    end

    state = {
        active = true,
        source_buf = source_buf,
        source_win = source_win,
        show_replace = false,
        case_sensitive = false,
        whole_word = false,
        last_query = preserved_query,
        matches = {},
        selected_index = 0,
        ns_id = vim.api.nvim_create_namespace("ZeroSearchMini"),
    }

    ui.create_ui(state)

    local input_buf = state.input_buf
    local results_buf = state.results_buf

    if state.last_query ~= "" then
        vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { state.last_query })
        vim.api.nvim_win_set_cursor(state.input_win, { 1, #state.last_query })
    end

    -- setup events
    for _, buf in ipairs({ input_buf, results_buf }) do
        local opts = { buffer = buf, silent = true }
        vim.keymap.set("n", "q", function() ui.close_ui(state) end, opts)
        vim.keymap.set("n", "<Esc>", function() ui.close_ui(state) end, opts)

        vim.keymap.set({ "i", "n" }, "<C-c>", function()
            state.case_sensitive = not state.case_sensitive
            ui.render_input(state)
            execute_search()
        end, opts)

        vim.keymap.set({ "i", "n" }, "<C-w>", function()
            state.whole_word = not state.whole_word
            ui.render_input(state)
            execute_search()
        end, { buffer = buf, silent = true, nowait = true })

        vim.keymap.set({ "i", "n" }, "<C-r>", function()
            ui.toggle_replace(state)
        end, opts)
    end

    -- Normal mode specific behaviors
    vim.keymap.set({ "i", "n" }, "<CR>", function()
        local cursor = vim.api.nvim_win_get_cursor(0)
        if cursor[1] == 1 then
            -- Find line: Advance selection
            if #state.matches > 0 then
                state.selected_index = state.selected_index + 1
                if state.selected_index > #state.matches then
                    state.selected_index = 1
                end
                ui.jump_to_match(state)
            end
        elseif cursor[1] == 2 then
            -- Replace line: Replace current and move
            do_replace()
        end
    end, { buffer = input_buf, silent = true })

    vim.keymap.set("n", "j", function()
        local pos = vim.api.nvim_win_get_cursor(0)
        local line_count = vim.api.nvim_buf_line_count(0)
        if pos[1] < line_count then
            vim.api.nvim_win_set_cursor(0, { pos[1] + 1, pos[2] })
        else
            if vim.api.nvim_win_is_valid(state.results_win) then
                vim.api.nvim_set_current_win(state.results_win)
            end
        end
    end, { buffer = input_buf, silent = true })

    vim.keymap.set("n", "k", function()
        local pos = vim.api.nvim_win_get_cursor(0)
        if pos[1] > 1 then
            vim.api.nvim_win_set_cursor(0, { pos[1] - 1, pos[2] })
        end
    end, { buffer = input_buf, silent = true })

    vim.keymap.set("n", "j", function()
        if state.selected_index < #state.matches then
            state.selected_index = state.selected_index + 1
            ui.jump_to_match(state)
        end
    end, { buffer = results_buf, silent = true })

    vim.keymap.set("n", "k", function()
        if state.selected_index > 1 then
            state.selected_index = state.selected_index - 1
            ui.jump_to_match(state)
        else
            if vim.api.nvim_win_is_valid(state.input_win) then
                vim.api.nvim_set_current_win(state.input_win)
                local line_count = vim.api.nvim_buf_line_count(state.input_buf)
                pcall(vim.api.nvim_win_set_cursor, state.input_win, { line_count, 0 })
            end
        end
    end, { buffer = results_buf, silent = true })

    vim.keymap.set("n", "r", function()
        if state.show_replace then
            do_replace()
        end
    end, { buffer = results_buf, silent = true })

    vim.keymap.set("n", "<CR>", function()
        if state.selected_index > 0 and state.selected_index <= #state.matches then
            local match = state.matches[state.selected_index]
            local source_win = state.source_win

            ui.close_ui(state)

            if source_win and vim.api.nvim_win_is_valid(source_win) then
                vim.api.nvim_set_current_win(source_win)
                pcall(vim.api.nvim_win_set_cursor, source_win, { match.lnum, match.col })
                vim.api.nvim_win_call(source_win, function()
                    vim.cmd("normal! zvzz")
                end)
            end
        end
    end, { buffer = results_buf, silent = true })

    vim.keymap.set("n", "i", function()
        vim.cmd("startinsert")
    end, { buffer = input_buf, silent = true })

    vim.keymap.set("i", "<Esc>", function()
        vim.cmd("stopinsert")
    end, { buffer = input_buf, silent = true })

    -- Keep the two fields separate when editing at their boundaries.
    vim.keymap.set("i", "<BS>", function()
        local pos = vim.api.nvim_win_get_cursor(state.input_win)
        return pos[1] == 2 and pos[2] == 0 and "" or "<BS>"
    end, { buffer = input_buf, expr = true, silent = true })
    vim.keymap.set("i", "<Del>", function()
        local pos = vim.api.nvim_win_get_cursor(state.input_win)
        local line = vim.api.nvim_buf_get_lines(input_buf, pos[1] - 1, pos[1], false)[1] or ""
        return pos[1] == 1 and pos[2] == #line and "" or "<Del>"
    end, { buffer = input_buf, expr = true, silent = true })

    state.timer = vim.loop.new_timer()
    local session = state
    vim.api.nvim_buf_attach(input_buf, false, {
        on_lines = function(_, _, _, first, last, new_last)
            if not session.active or not session.timer then return true end
            session.timer:stop()
            -- on_lines runs under textlock: repair pasted line breaks later.
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
        end
    })

    ui.render_input(state)
    execute_search()

    vim.cmd("startinsert!")
end

return M
