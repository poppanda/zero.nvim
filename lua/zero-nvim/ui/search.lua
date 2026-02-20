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
        title_pos = "center"
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

    local toggle_state = { case_sensitive = false, whole_word = false }

    local function update_input_footer()
        if not vim.api.nvim_win_is_valid(input_win) then return end
        local cs_box = toggle_state.case_sensitive and "[x]" or "[ ]"
        local ww_box = toggle_state.whole_word and "[x]" or "[ ]"

        local new_footer = string.format("  %sAa  %sword  ", cs_box, ww_box)
        vim.api.nvim_win_set_config(input_win, { footer = new_footer, footer_pos = "right" })
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

    local function focus_window(name)
        if name == "path" and vim.api.nvim_win_is_valid(path_win) then
            vim.api.nvim_set_current_win(path_win)
        elseif name == "query" and vim.api.nvim_win_is_valid(input_win) then
            vim.api.nvim_set_current_win(input_win)
        elseif name == "results" and vim.api.nvim_win_is_valid(results_win) then
            vim.api.nvim_set_current_win(results_win)
        end
    end

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
        timer2 = timer2
    }
end

return M
