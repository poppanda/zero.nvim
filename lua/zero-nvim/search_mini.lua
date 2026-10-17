local ui = require("zero-nvim.ui.search_mini")

local M = {}

local state = {
    active = false,
}

local per_buf_queries = {}

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
    local matches = {}

    -- basic escaping for vim regex
    local vim_pattern = query:gsub("\\", "\\\\"):gsub("/", "\\/")
    if not state.case_sensitive then
        vim_pattern = "\\c" .. vim_pattern
    else
        vim_pattern = "\\C" .. vim_pattern
    end
    if state.whole_word then
        vim_pattern = "\\<" .. vim_pattern .. "\\>"
    end

    local ok, regex = pcall(vim.regex, vim_pattern)
    if not ok then
        state.matches = {}
        state.selected_index = 0
        ui.render_results(state)
        return
    end

    local line_count = vim.api.nvim_buf_line_count(state.source_buf)
    local MAX_MATCHES = 2000

    for i = 1, line_count do
        local start_idx = 0
        local line_text = nil
        while true do
            local s, e = regex:match_line(state.source_buf, i - 1, start_idx)
            if s and e and e > s then
                if not line_text then
                    line_text = vim.api.nvim_buf_get_lines(state.source_buf, i - 1, i, false)[1]
                end
                table.insert(matches, {
                    lnum = i,
                    col = start_idx + s,
                    end_col = start_idx + e,
                    text = line_text
                })
                start_idx = start_idx + e

                if #matches >= MAX_MATCHES then
                    break
                end
            else
                break
            end
        end
        if #matches >= MAX_MATCHES then
            break
        end
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
                if extra > 0 then
                    local count = vim.api.nvim_buf_line_count(input_buf)
                    local expected = session.show_replace and 2 or 1
                    if count > expected then
                        local pasted = vim.api.nvim_buf_get_lines(input_buf, first, new_last, false)
                        vim.api.nvim_buf_set_lines(input_buf, first, new_last, false, { table.concat(pasted, " ") })
                    end
                end
                local expected = session.show_replace and 2 or 1
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
