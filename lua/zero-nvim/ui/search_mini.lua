local M = {}

function M.close_ui(state)
    if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
        vim.api.nvim_win_close(state.input_win, true)
    end
    if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
        vim.api.nvim_win_close(state.results_win, true)
    end
    if state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf) then
        vim.api.nvim_buf_delete(state.input_buf, { force = true })
    end
    if state.results_buf and vim.api.nvim_buf_is_valid(state.results_buf) then
        vim.api.nvim_buf_delete(state.results_buf, { force = true })
    end
    if state.source_win and vim.api.nvim_win_is_valid(state.source_win) then
        if state.source_buf and vim.api.nvim_buf_is_valid(state.source_buf) then
            pcall(vim.api.nvim_buf_clear_namespace, state.source_buf, state.ns_id, 0, -1)
        end
    end
    if state.timer then
        state.timer:stop()
        state.timer:close()
        state.timer = nil
    end
    vim.cmd("stopinsert")
    state.active = false
end

function M.jump_to_match(state)
    if state.selected_index > 0 and state.selected_index <= #state.matches then
        local match = state.matches[state.selected_index]
        if vim.api.nvim_win_is_valid(state.source_win) then
            vim.api.nvim_win_set_cursor(state.source_win, { match.lnum, match.col })
            -- keep jump centered minimally
            vim.api.nvim_win_call(state.source_win, function()
                vim.cmd("normal! zz")
            end)
        end

        -- Highlighting in source
        if vim.api.nvim_buf_is_valid(state.source_buf) then
            pcall(vim.api.nvim_buf_clear_namespace, state.source_buf, state.ns_id, 0, -1)
            pcall(vim.api.nvim_buf_add_highlight, state.source_buf, state.ns_id, "IncSearch", match.lnum - 1, match.col,
                match.end_col)
        end

        -- Select line in results
        if vim.api.nvim_win_is_valid(state.results_win) then
            local row = state.show_replace and ((state.selected_index - 1) * 2) or (state.selected_index - 1)
            pcall(vim.api.nvim_win_set_cursor, state.results_win, { row + 1, 0 })
        end
        if vim.api.nvim_buf_is_valid(state.results_buf) then
            pcall(vim.api.nvim_buf_clear_namespace, state.results_buf, state.ns_id, 0, -1)
            local res_match = state.matches[state.selected_index]
            pcall(vim.api.nvim_buf_clear_namespace, state.results_buf, state.ns_id, 0, -1) -- Clear all highlights first
            -- Re-apply all Diagnostic highlights
            local replacement = ""
            if state.show_replace and vim.api.nvim_buf_is_valid(state.input_buf) then
                local in_lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
                replacement = in_lines[2] or ""
            end

            for i, match_item in ipairs(state.matches) do
                if state.show_replace then
                    local row1 = (i - 1) * 2
                    local row2 = row1 + 1
                    local prefix1 = string.format(" 🟥 %4d: ", match_item.lnum)
                    pcall(vim.api.nvim_buf_add_highlight, state.results_buf, state.ns_id, "DiagnosticError", row1,
                        #prefix1 + match_item.col, #prefix1 + match_item.end_col)

                    local prefix2 = string.format(" 🟩 %4d: ", match_item.lnum)
                    pcall(vim.api.nvim_buf_add_highlight, state.results_buf, state.ns_id, "DiagnosticOk", row2,
                        #prefix2 + match_item.col, #prefix2 + match_item.col + #replacement)
                else
                    local prefix_len = #string.format("  %4d: ", match_item.lnum)
                    pcall(vim.api.nvim_buf_add_highlight, state.results_buf, state.ns_id, "IncSearch",
                        i - 1, prefix_len + match_item.col, prefix_len + match_item.end_col)
                end
            end

            -- Apply CursorLine only to the selected match
            if state.show_replace then
                local row1 = (state.selected_index - 1) * 2
                local row2 = row1 + 1
                pcall(vim.api.nvim_buf_add_highlight, state.results_buf, state.ns_id, "CursorLine", row1, 0, -1)
                pcall(vim.api.nvim_buf_add_highlight, state.results_buf, state.ns_id, "CursorLine", row2, 0, -1)
            else
                pcall(vim.api.nvim_buf_add_highlight, state.results_buf, state.ns_id, "CursorLine",
                    state.selected_index - 1, 0, -1)
            end
        end
    end
end

function M.render_results(state)
    if not state.active then return end
    local buf = state.results_buf
    if not vim.api.nvim_buf_is_valid(buf) then return end

    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

    local lines = {}
    if #state.matches == 0 then
        table.insert(lines, "  0 results found.")
    else
        local replacement = ""
        if state.show_replace and vim.api.nvim_buf_is_valid(state.input_buf) then
            local in_lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
            replacement = in_lines[2] or ""
        end

        for _, match in ipairs(state.matches) do
            if state.show_replace then
                local prefix1 = string.format(" 🟥 %4d: ", match.lnum)
                table.insert(lines, prefix1 .. match.text)

                local new_text = string.sub(match.text, 1, match.col) ..
                    replacement .. string.sub(match.text, match.end_col + 1)
                local prefix2 = string.format(" 🟩 %4d: ", match.lnum)
                table.insert(lines, prefix2 .. new_text)
            else
                local prefix = string.format("  %4d: ", match.lnum)
                table.insert(lines, prefix .. match.text)
            end
        end
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    if state.show_replace and #state.matches > 0 then
        for i, match in ipairs(state.matches) do
            local row1 = (i - 1) * 2
            local row2 = row1 + 1
            local prefix1 = string.format(" 🟥 %4d: ", match.lnum)
            pcall(vim.api.nvim_buf_add_highlight, buf, state.ns_id, "DiagnosticError", row1, #prefix1, -1)
            local prefix2 = string.format(" 🟩 %4d: ", match.lnum)
            pcall(vim.api.nvim_buf_add_highlight, buf, state.ns_id, "DiagnosticOk", row2, #prefix2, -1)
        end
    end
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

    local h = state.show_replace and 10 or 5
    if vim.api.nvim_win_is_valid(state.results_win) then
        vim.api.nvim_win_set_config(state.results_win, { height = h })
    end

    if #state.matches > 0 then
        M.jump_to_match(state)
    else
        pcall(vim.api.nvim_buf_clear_namespace, buf, state.ns_id, 0, -1)
        if vim.api.nvim_buf_is_valid(state.source_buf) then
            pcall(vim.api.nvim_buf_clear_namespace, state.source_buf, state.ns_id, 0, -1)
        end
    end
end

function M.render_input(state)
    if not state.active then return end
    pcall(vim.api.nvim_buf_clear_namespace, state.input_buf, state.ns_id, 0, -1)

    local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
    local find_text = lines[1] or ""
    if find_text == "" then
        pcall(vim.api.nvim_buf_set_extmark, state.input_buf, state.ns_id, 0, 0, {
            virt_text = { { "Find:", "Comment" } },
            virt_text_pos = "overlay",
            hl_mode = "combine"
        })
    end

    if state.show_replace then
        local replace_text = lines[2] or ""
        if replace_text == "" then
            pcall(vim.api.nvim_buf_set_extmark, state.input_buf, state.ns_id, 1, 0, {
                virt_text = { { "Replace:", "Comment" } },
                virt_text_pos = "overlay",
                hl_mode = "combine"
            })
        end
    end

    if vim.api.nvim_win_is_valid(state.input_win) then
        local cs_box = state.case_sensitive and "[x]" or "[ ]"
        local ww_box = state.whole_word and "[x]" or "[ ]"
        local footer = string.format("  %sAa  %sword  ", cs_box, ww_box)
        pcall(vim.api.nvim_win_set_config, state.input_win, { footer = footer, footer_pos = "right" })
    end
end

function M.toggle_replace(state)
    if not state.active then return end
    state.show_replace = not state.show_replace

    if state.show_replace then
        if vim.api.nvim_win_is_valid(state.input_win) then
            vim.api.nvim_win_set_config(state.input_win,
                { relative = "editor", row = state.base_row - 6, col = state.base_col, height = 2 })
        end
        if vim.api.nvim_win_is_valid(state.results_win) then
            vim.api.nvim_win_set_config(state.results_win,
                {
                    relative = "editor",
                    row = state.base_row - 2,
                    col = state.base_col,
                    height = 10,
                    footer =
                    " r:Replace | C-r:Replace | C-c:Case | C-w:Word ",
                    footer_pos = "left"
                })
        end
        local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
        if #lines < 2 then
            vim.api.nvim_buf_set_lines(state.input_buf, 1, 1, false, { "" })
        end
        pcall(vim.api.nvim_win_set_cursor, state.input_win, { 2, 0 })
    else
        if vim.api.nvim_win_is_valid(state.input_win) then
            vim.api.nvim_win_set_config(state.input_win,
                { relative = "editor", row = state.base_row, col = state.base_col, height = 1 })
            pcall(vim.api.nvim_win_set_cursor, state.input_win, { 1, 0 })
            local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
            if #lines > 1 then
                vim.api.nvim_buf_set_lines(state.input_buf, 1, -1, false, {})
            end
        end
        if vim.api.nvim_win_is_valid(state.results_win) then
            vim.api.nvim_win_set_config(state.results_win,
                {
                    relative = "editor",
                    row = state.base_row + 3,
                    col = state.base_col,
                    height = 5,
                    footer =
                    " C-r:Replace | C-c:Case | C-w:Word ",
                    footer_pos = "left"
                })
        end
    end

    M.render_input(state)
    M.render_results(state)
end

function M.create_ui(state)
    local ui_conf = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }
    local w = 50
    local r = ui_conf.height - 10
    local c = ui_conf.width - w - 2 -- bottom right

    state.base_row = r
    state.base_col = c

    local input_buf = vim.api.nvim_create_buf(false, true)
    local input_win = vim.api.nvim_open_win(input_buf, true, {
        relative = "editor",
        row = r,
        col = c,
        width = w,
        height = 1,
        style = "minimal",
        border = { "╭", "─", "╮", "│", "┤", "─", "├", "│" },
        title = " 󰍉 Mini Search ",
        title_pos = "center",
        footer = "  [ ]Aa  [ ]word  ",
        footer_pos = "right"
    })

    local results_buf = vim.api.nvim_create_buf(false, true)
    local results_win = vim.api.nvim_open_win(results_buf, false, {
        relative = "editor",
        row = r + 3,
        col = c,
        width = w,
        height = 5,
        style = "minimal",
        border = { "", "", "", "│", "╯", "─", "╰", "│" },
        footer = " C-r:Replace | C-c:Case | C-w:Word ",
        footer_pos = "left"
    })

    state.input_buf = input_buf
    state.input_win = input_win
    state.results_buf = results_buf
    state.results_win = results_win

    pcall(vim.api.nvim_set_option_value, "winhl", "NormalFloat:TelescopePromptNormal,FloatBorder:TelescopePromptBorder",
        { win = input_win })
    pcall(vim.api.nvim_set_option_value, "wrap", false, { win = input_win })

    pcall(vim.api.nvim_set_option_value, "winhl", "NormalFloat:TelescopeResultsNormal,FloatBorder:TelescopeResultsBorder",
        { win = results_win })
    pcall(vim.api.nvim_set_option_value, "wrap", false, { win = results_win })
    vim.api.nvim_set_option_value("cursorline", false, { win = results_win })

    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
end

return M
