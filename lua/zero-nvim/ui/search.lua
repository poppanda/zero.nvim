local M = {}

--- Create and open the multi-window search UI
---@param title_prefix string
---@param initial_path string
---@param callbacks table { on_query_change, on_path_change, on_close, on_enter, on_select_next, on_select_prev, on_toggle_fold }
---@return table session_ui { path_win, input_win, results_win, preview_win, path_buf, input_buf, results_buf, preview_buf, ns }
function M.open_search_ui(title_prefix, initial_path, callbacks)
    local nvim_ui = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }
    local w = math.floor(nvim_ui.width * 0.85)
    local h = math.floor(nvim_ui.height * 0.85)
    local r = math.floor((nvim_ui.height - h) / 2)
    local c = math.floor((nvim_ui.width - w) / 2)

    local ih = 1
    local rw = math.floor(w * 0.4)
    local pw = w - rw - 1

    local path_buf = vim.api.nvim_create_buf(false, true)
    local path_win = vim.api.nvim_open_win(path_buf, true, {
        relative = "editor",
        row = r,
        col = c,
        width = w,
        height = ih,
        style = "minimal",
        border = "rounded",
        title = string.format(" 📂 Search Path (%s) ", title_prefix),
        title_pos = "center",
        footer = "  [*] C-t:Type  ",
        footer_pos = "right"
    })

    local input_buf = vim.api.nvim_create_buf(false, true)
    local input_win = vim.api.nvim_open_win(input_buf, false, {
        relative = "editor",
        row = r + ih + 2,
        col = c,
        width = w,
        height = ih,
        style = "minimal",
        border = "rounded",
        title = " 🔍 Keywords ",
        title_pos = "center",
        footer = "  [ ]Aa  [ ]word  ",
        footer_pos = "right"
    })

    local results_buf = vim.api.nvim_create_buf(false, true)
    local results_win = vim.api.nvim_open_win(results_buf, false, {
        relative = "editor",
        row = r + 2 * ih + 4,
        col = c,
        width = rw,
        height = h - 2 * ih - 4,
        style = "minimal",
        border = "rounded",
        title = " Results ",
        title_pos = "center",
        footer = " j/k/h/l:Nav | C-w:Word | C-c:Case ",
        footer_pos = "left"
    })
    vim.api.nvim_set_option_value("cursorline", false, { win = results_win })

    local preview_buf = vim.api.nvim_create_buf(false, true)
    local preview_win = vim.api.nvim_open_win(preview_buf, false, {
        relative = "editor",
        row = r + 2 * ih + 4,
        col = c + rw + 2,
        width = pw - 1,
        height = h - 2 * ih - 4,
        style = "minimal",
        border = "rounded",
        title = " Preview ",
        title_pos = "center",
        footer = " CR:Open | i:Insert | q/Esc:Quit ",
        footer_pos = "right"
    })

    pcall(vim.api.nvim_set_option_value, "winhl", "NormalFloat:TelescopePromptNormal,FloatBorder:TelescopePromptBorder",
        { win = path_win })
    pcall(vim.api.nvim_set_option_value, "winhl", "NormalFloat:TelescopePromptNormal,FloatBorder:TelescopePromptBorder",
        { win = input_win })
    pcall(vim.api.nvim_set_option_value, "winhl", "NormalFloat:TelescopeResultsNormal,FloatBorder:TelescopeResultsBorder",
        { win = results_win })
    pcall(vim.api.nvim_set_option_value, "winhl", "NormalFloat:TelescopePreviewNormal,FloatBorder:TelescopePreviewBorder",
        { win = preview_win })

    local ns = vim.api.nvim_create_namespace("ZeroSearchUI")

    vim.api.nvim_buf_set_lines(path_buf, 0, -1, false, { initial_path or "/" })
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })

    local toggle_state = { case_sensitive = false, whole_word = false, file_types = {} }

    -- Common file types supported by ripgrep (sorted)
    local builtin_types = {
        "c", "cpp", "css", "go", "h", "html", "java", "js", "json",
        "lua", "md", "py", "rust", "sh", "sql", "toml", "ts", "txt", "xml", "yaml",
    }

    local function update_input_footer()
        if not vim.api.nvim_win_is_valid(input_win) then return end
        local cs_box = toggle_state.case_sensitive and "[x]" or "[ ]"
        local ww_box = toggle_state.whole_word and "[x]" or "[ ]"

        local new_footer = string.format("  %sAa  %sword  ", cs_box, ww_box)
        vim.api.nvim_win_set_config(input_win, { footer = new_footer, footer_pos = "right" })
    end

    local function update_path_footer()
        if not vim.api.nvim_win_is_valid(path_win) then return end
        local type_label
        if #toggle_state.file_types == 0 then
            type_label = "*"
        else
            type_label = table.concat(toggle_state.file_types, ",")
        end
        local new_footer = string.format("  [%s] C-t:Type  ", type_label)
        vim.api.nvim_win_set_config(path_win, { footer = new_footer, footer_pos = "right" })
    end

    local function focus_window(name)
        if name == "path" and vim.api.nvim_win_is_valid(path_win) then
            vim.api.nvim_set_current_win(path_win)
        elseif name == "query" and vim.api.nvim_win_is_valid(input_win) then
            vim.api.nvim_set_current_win(input_win)
        elseif name == "results" and vim.api.nvim_win_is_valid(results_win) then
            vim.api.nvim_set_current_win(results_win)
        end
    end

    local function open_type_picker()
        local picker_width = 28
        local max_list_height = 15
        local picker_row = r + ih + 2
        local picker_col = c + w - picker_width - 2

        local selected_set = {}
        for _, t in ipairs(toggle_state.file_types) do selected_set[t] = true end

        local builtin_set = {}
        for _, t in ipairs(builtin_types) do builtin_set[t] = true end
        local custom_types = {}
        for _, t in ipairs(toggle_state.file_types) do
            if not builtin_set[t] then table.insert(custom_types, t) end
        end

        local filter_query = ""
        local searching = false
        local filtered_items = {}

        local function rebuild_filtered()
            filtered_items = {}
            local all = {}
            for _, t in ipairs(builtin_types) do table.insert(all, t) end
            for _, t in ipairs(custom_types) do table.insert(all, t) end
            table.sort(all)
            local seen = {}
            for _, t in ipairs(all) do
                if not seen[t] then
                    seen[t] = true
                    if filter_query == "" or t:find(filter_query, 1, true) then
                        table.insert(filtered_items, t)
                    end
                end
            end
        end
        rebuild_filtered()

        -- Single list window
        local list_buf = vim.api.nvim_create_buf(false, true)
        local list_height = math.min(max_list_height, math.max(1, #filtered_items))
        local list_win = vim.api.nvim_open_win(list_buf, true, {
            relative = "editor",
            row = picker_row,
            col = picker_col,
            width = picker_width,
            height = list_height,
            style = "minimal",
            border = "rounded",
            title = { { " File Type ", "FloatTitle" } },
            title_pos = "left",
            footer = " Space:Toggle /:Search Tab:Add ",
            footer_pos = "center",
            zindex = 100,
        })
        pcall(vim.api.nvim_set_option_value, "winhl",
            "NormalFloat:TelescopeResultsNormal,FloatBorder:TelescopeResultsBorder", { win = list_win })
        pcall(vim.api.nvim_set_option_value, "cursorline", true, { win = list_win })

        local picker_ns = vim.api.nvim_create_namespace("ZeroSearchTypePicker")

        local function update_title()
            if not vim.api.nvim_win_is_valid(list_win) then return end
            local title
            if searching or filter_query ~= "" then
                title = {
                    { " File Type ", "FloatTitle" },
                    { " Search: ", "Comment" },
                    { filter_query .. (searching and "│" or ""), "String" },
                    { " ", "FloatBorder" },
                }
            else
                title = { { " File Type ", "FloatTitle" } }
            end
            vim.api.nvim_win_set_config(list_win, { title = title, title_pos = "left" })
        end

        local function render_list()
            local lines = {}
            for _, t in ipairs(filtered_items) do
                local box = selected_set[t] and "[x]" or "[ ]"
                table.insert(lines, string.format(" %s %s", box, t))
            end
            if #lines == 0 then
                lines = { "  (no match)" }
            end
            vim.api.nvim_set_option_value("modifiable", true, { buf = list_buf })
            vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
            vim.api.nvim_set_option_value("modifiable", false, { buf = list_buf })
            local new_h = math.min(max_list_height, math.max(1, #lines))
            if vim.api.nvim_win_is_valid(list_win) then
                vim.api.nvim_win_set_height(list_win, new_h)
            end
            vim.api.nvim_buf_clear_namespace(list_buf, picker_ns, 0, -1)
            for i, t in ipairs(filtered_items) do
                if selected_set[t] then
                    vim.api.nvim_buf_add_highlight(list_buf, picker_ns, "String", i - 1, 0, -1)
                end
            end
            update_title()
        end

        render_list()

        local function close_picker()
            if vim.api.nvim_win_is_valid(list_win) then vim.api.nvim_win_close(list_win, true) end
            if vim.api.nvim_buf_is_valid(list_buf) then vim.api.nvim_buf_delete(list_buf, { force = true }) end
            toggle_state.file_types = {}
            for t, _ in pairs(selected_set) do
                table.insert(toggle_state.file_types, t)
            end
            table.sort(toggle_state.file_types)
            update_path_footer()
            focus_window("query")
            callbacks.on_query_change(toggle_state.case_sensitive, toggle_state.whole_word)
        end

        local function stop_search()
            searching = false
            -- Keep filter_query and filtered results as-is
            update_title()
            if vim.api.nvim_win_is_valid(list_win) then
                vim.api.nvim_set_current_win(list_win)
            end
        end

        local function add_custom_type()
            local input = vim.trim(filter_query)
            if input == "" then return end
            input = input:gsub("^%*?%.?", "")
            if input == "" then return end
            if not builtin_set[input] then
                local already = false
                for _, t in ipairs(custom_types) do
                    if t == input then already = true; break end
                end
                if not already then table.insert(custom_types, input) end
            end
            selected_set[input] = true
            -- Clear search and refresh
            filter_query = ""
            searching = false
            rebuild_filtered()
            render_list()
            if vim.api.nvim_win_is_valid(list_win) then
                vim.api.nvim_set_current_win(list_win)
            end
        end

        local function start_search()
            if searching then return end
            searching = true
            filter_query = ""
            rebuild_filtered()
            render_list()

            local function search_loop()
                while true do
                    vim.cmd("redraw")
                    local ok, ch = pcall(vim.fn.getcharstr)
                    if not ok then break end

                    local byte = string.byte(ch)
                    if ch == "\27" or ch == "\r" then
                        -- Esc or Enter: stop search, keep results
                        break
                    elseif ch == "\t" then
                        -- Tab: add custom type
                        add_custom_type()
                        return
                    elseif byte == 20 then
                        -- Ctrl-T: close picker
                        close_picker()
                        return
                    elseif byte == 127 or byte == 8 or ch == vim.api.nvim_replace_termcodes("<BS>", true, false, true) then
                        -- Backspace
                        if #filter_query > 0 then
                            -- Remove last UTF-8 char
                            local chars = vim.fn.split(filter_query, "\\zs")
                            table.remove(chars)
                            filter_query = table.concat(chars)
                        else
                            -- Empty backspace: exit search
                            break
                        end
                    elseif byte >= 32 then
                        -- Printable character
                        filter_query = filter_query .. ch
                    else
                        break
                    end
                    rebuild_filtered()
                    render_list()
                end
                stop_search()
            end

            search_loop()
        end

        -- List keymaps
        local list_opts = { buffer = list_buf, silent = true, nowait = true }

        vim.keymap.set("n", "<Space>", function()
            local row = vim.api.nvim_win_get_cursor(list_win)[1]
            local t = filtered_items[row]
            if t then
                if selected_set[t] then selected_set[t] = nil else selected_set[t] = true end
                render_list()
            end
        end, list_opts)

        vim.keymap.set("n", "/", start_search, list_opts)

        vim.keymap.set("n", "<Tab>", function()
            if filter_query ~= "" then
                add_custom_type()
            end
        end, list_opts)

        -- Clear search filter
        vim.keymap.set("n", "<BS>", function()
            if filter_query ~= "" then
                filter_query = ""
                vim.api.nvim_buf_set_lines(search_buf, 0, -1, false, { "" })
                rebuild_filtered()
                render_list()
            end
        end, list_opts)

        vim.keymap.set("n", "<CR>", close_picker, list_opts)
        vim.keymap.set("n", "<Esc>", close_picker, list_opts)
        vim.keymap.set("n", "q", close_picker, list_opts)
        vim.keymap.set("n", "<C-t>", close_picker, list_opts)
    end

    local function notify_change(cb)
        cb(toggle_state.case_sensitive, toggle_state.whole_word)
    end

    -- Attach debounce listeners
    local function setup_on_lines(buf, cb)
        local timer = vim.loop.new_timer()
        vim.api.nvim_buf_attach(buf, false, {
            on_lines = function(_, _, _, _, _, _)
                timer:stop()
                timer:start(350, 0, vim.schedule_wrap(function()
                    notify_change(cb)
                end))
            end
        })
        return timer
    end

    local timer1 = setup_on_lines(path_buf, callbacks.on_path_change)
    local timer2 = setup_on_lines(input_buf, callbacks.on_query_change)

    -- Shared mappings
    for _, buf in ipairs({ path_buf, input_buf, results_buf }) do
        local opts = { buffer = buf, silent = true }
        vim.keymap.set("n", "q", callbacks.on_close, opts)
        vim.keymap.set("n", "<Esc>", callbacks.on_close, opts)

        -- Override C-c to toggle case sensitivity instead of close
        vim.keymap.set({ "i", "n" }, "<C-c>", function()
            toggle_state.case_sensitive = not toggle_state.case_sensitive
            update_input_footer()
            notify_change(callbacks.on_query_change)
        end, { buffer = buf, silent = true, nowait = true })

        vim.keymap.set({ "i", "n" }, "<C-w>", function()
            toggle_state.whole_word = not toggle_state.whole_word
            update_input_footer()
            notify_change(callbacks.on_query_change)
        end, { buffer = buf, silent = true, nowait = true })

        vim.keymap.set({ "i", "n" }, "<C-t>", function()
            vim.cmd("stopinsert")
            open_type_picker()
        end, { buffer = buf, silent = true, nowait = true })

        -- Automatically enter insert mode when focusing path or query inputs
        vim.keymap.set("n", "i", function()
            local cur_win = vim.api.nvim_get_current_win()
            if cur_win == path_win or cur_win == input_win then
                vim.cmd("startinsert")
            end
        end, opts)

        -- Esc out of insert -> automatically jump to results
        vim.keymap.set("i", "<Esc>", function()
            vim.cmd("stopinsert")
            focus_window("results")
        end, opts)

        vim.keymap.set({ "i", "n" }, "<CR>", callbacks.on_enter, opts)
    end

    -- path_buf specific normal-mode navigation
    vim.keymap.set("n", "j", function() focus_window("query") end, { buffer = path_buf, silent = true })
    vim.keymap.set("n", "<Down>", function() focus_window("query") end, { buffer = path_buf, silent = true })

    -- input_buf specific normal-mode navigation
    vim.keymap.set("n", "k", function() focus_window("path") end, { buffer = input_buf, silent = true })
    vim.keymap.set("n", "<Up>", function() focus_window("path") end, { buffer = input_buf, silent = true })
    vim.keymap.set("n", "j", function() focus_window("results") end, { buffer = input_buf, silent = true })
    vim.keymap.set("n", "<Down>", function() focus_window("results") end, { buffer = input_buf, silent = true })

    -- results_buf specific normal-mode navigation
    vim.keymap.set("n", "k", function()
        if callbacks.on_select_prev() then
            focus_window("query")
        end
    end, { buffer = results_buf, silent = true })
    vim.keymap.set("n", "<Up>", function()
        if callbacks.on_select_prev() then
            focus_window("query")
        end
    end, { buffer = results_buf, silent = true })

    vim.keymap.set("n", "j", callbacks.on_select_next, { buffer = results_buf, silent = true })
    vim.keymap.set("n", "<Down>", callbacks.on_select_next, { buffer = results_buf, silent = true })

    -- results_buf specific folding navigation
    vim.keymap.set("n", "h", callbacks.on_toggle_fold, { buffer = results_buf, silent = true })
    vim.keymap.set("n", "l", callbacks.on_toggle_fold, { buffer = results_buf, silent = true })
    vim.keymap.set("n", "<Left>", callbacks.on_toggle_fold, { buffer = results_buf, silent = true })
    vim.keymap.set("n", "<Right>", callbacks.on_toggle_fold, { buffer = results_buf, silent = true })

    -- Start in query window, insert mode
    focus_window("query")
    vim.cmd("startinsert!")

    return {
        path_win = path_win,
        input_win = input_win,
        results_win = results_win,
        preview_win = preview_win,
        path_buf = path_buf,
        input_buf = input_buf,
        results_buf = results_buf,
        preview_buf = preview_buf,
        ns = ns,
        timer1 = timer1,
        timer2 = timer2,
        toggle_state = toggle_state,
    }
end

return M
