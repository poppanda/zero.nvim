local utils = require("zero-nvim.ui.utils")
local icons = require("zero-nvim.ui.icons")

local M = {}

--- Browse remote directories in a floating window.
--- Connects to the server, reads directories via the daemon, and allows
--- navigation. Press <CR> on a directory to enter it, <C-s> to confirm
--- the current directory, "-" or ".." to go up, q/<Esc> to cancel.
---
---@param user string
---@param hostname string
---@param port integer
---@param on_confirm fun(path: string) Called with the selected directory path
---@param opts? { start_path?: string, display_name?: string }
function M.browse_path(user, hostname, port, on_confirm, opts)
    local zero = require("zero-nvim")
    opts = opts or {}
    local default_home = "/home/" .. user
    local current_path = opts.start_path or default_home
    local display_name = opts.display_name or string.format("%s@%s", user, hostname)
    local show_hidden = false

    local float_width = 65

    local buf, win = utils.create_float({
        title = display_name .. ":" .. current_path,
        footer = "CR:Enter | -:Parent | C-s:Open | .:Hidden | q:Cancel",
        width = float_width,
        height = 10, -- initial; resized dynamically in render()
    })

    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })

    -- State for the current directory listing
    local raw_entries = {}     -- full unfiltered listing from daemon
    local current_entries = {} -- filtered listing currently displayed
    local entry_count = 0      -- number of selectable rows (.. + filtered entries)

    --- Render the current directory entries into the buffer
    local function render(entries)
        if entries then raw_entries = entries end

        -- Filter hidden files
        current_entries = {}
        for _, entry in ipairs(raw_entries) do
            if show_hidden or entry.name:sub(1, 1) ~= "." then
                table.insert(current_entries, entry)
            end
        end

        table.sort(current_entries, function(a, b)
            if a.type ~= b.type then return a.type == "directory" end
            return a.name < b.name
        end)

        local lines = {}
        table.insert(lines, "  ↩️  ../")

        for _, entry in ipairs(current_entries) do
            if entry.type == "directory" then
                table.insert(lines, "  📁 " .. entry.name .. "/")
            else
                local ext = entry.name:match("%.([^%.]+)$")
                local icon = icons._file_icon(ext)
                table.insert(lines, "  " .. icon .. " " .. entry.name)
            end
        end

        entry_count = 1 + #current_entries -- 1 for "..", rest for filtered entries

        if not vim.api.nvim_buf_is_valid(buf) then return end
        vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

        -- Resize window to fit content (capped at editor height - 4)
        if vim.api.nvim_win_is_valid(win) then
            local editor = vim.api.nvim_list_uis()[1] or { height = 40 }
            local new_height = math.min(#lines, editor.height - 4)
            vim.api.nvim_win_set_config(win, {
                relative = "editor",
                height = new_height,
                row = math.floor((editor.height - new_height) / 2),
                col = math.floor((editor.width - float_width) / 2),
            })
            vim.api.nvim_win_set_cursor(win, { 1, 0 })
        end
    end

    --- Load a remote directory and render it
    local function load_dir(path)
        current_path = path

        local chan, err = zero.ensure_connection(user, hostname, port)
        if not chan then
            vim.notify("ZeroNvim: Connection failed — " .. (err or "unknown"), vim.log.levels.ERROR)
            utils.close_float(win, buf)
            return
        end

        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_set_config(win, {
                relative = "editor",
                row = math.floor(((vim.api.nvim_list_uis()[1] or { height = 40 }).height - vim.api.nvim_win_get_height(win)) /
                    2),
                col = math.floor(((vim.api.nvim_list_uis()[1] or { width = 80 }).width - float_width) / 2),
                title = " " .. display_name .. ":" .. current_path .. " ",
                title_pos = "center",
            })
        end

        local ok, entries = pcall(vim.fn.rpcrequest, chan, "read_dir", user, hostname, port, path)
        if not ok then
            vim.notify("ZeroNvim: Failed to read directory — " .. tostring(entries), vim.log.levels.ERROR)
            render({})
            return
        end

        render(entries)
    end

    local function clamp_cursor()
        if not vim.api.nvim_win_is_valid(win) then return end
        local pos = vim.api.nvim_win_get_cursor(win)
        if pos[1] < 1 then vim.api.nvim_win_set_cursor(win, { 1, 0 }) end
        if pos[1] > entry_count then vim.api.nvim_win_set_cursor(win, { entry_count, 0 }) end
    end

    local function get_cursor_entry()
        if not vim.api.nvim_win_is_valid(win) then return nil end
        local row = vim.api.nvim_win_get_cursor(win)[1]
        if row == 1 then
            return { name = "..", type = "directory" }
        elseif row >= 2 and row <= 1 + #current_entries then
            return current_entries[row - 1]
        end
        return nil
    end

    local map_opts = { buffer = buf, silent = true, nowait = true }

    vim.keymap.set("n", "<CR>", function()
        local entry = get_cursor_entry()
        if not entry then return end
        if entry.name == ".." then
            local parent = vim.fs.dirname(current_path:gsub("/$", ""))
            if parent == "" then parent = "/" end
            load_dir(parent)
        elseif entry.type == "directory" then
            local new_path = current_path:gsub("/$", "") .. "/" .. entry.name
            load_dir(new_path)
        else
            utils.close_float(win, buf)
            local file_path = current_path:gsub("/$", "") .. "/" .. entry.name
            vim.schedule(function() on_confirm(file_path) end)
        end
    end, map_opts)

    vim.keymap.set("n", "<C-s>", function()
        utils.close_float(win, buf)
        vim.schedule(function() on_confirm(current_path) end)
    end, map_opts)

    vim.keymap.set("n", "-", function()
        local parent = vim.fs.dirname(current_path:gsub("/$", ""))
        if parent == "" then parent = "/" end
        load_dir(parent)
    end, map_opts)

    vim.keymap.set("n", ".", function()
        show_hidden = not show_hidden
        render() -- re-render with same raw_entries, no re-fetch
    end, map_opts)

    vim.keymap.set("n", "q", function() utils.close_float(win, buf) end, map_opts)
    vim.keymap.set("n", "<Esc>", function() utils.close_float(win, buf) end, map_opts)

    vim.keymap.set("n", "j", function()
        if not vim.api.nvim_win_is_valid(win) then return end
        local pos = vim.api.nvim_win_get_cursor(win)
        local last_row = entry_count
        if pos[1] < last_row then vim.api.nvim_win_set_cursor(win, { pos[1] + 1, 0 }) end
    end, map_opts)

    vim.keymap.set("n", "k", function()
        if not vim.api.nvim_win_is_valid(win) then return end
        local pos = vim.api.nvim_win_get_cursor(win)
        if pos[1] > 1 then vim.api.nvim_win_set_cursor(win, { pos[1] - 1, 0 }) end
    end, map_opts)

    vim.keymap.set("n", "<Down>", function()
        if not vim.api.nvim_win_is_valid(win) then return end
        local pos = vim.api.nvim_win_get_cursor(win)
        local last_row = entry_count
        if pos[1] < last_row then vim.api.nvim_win_set_cursor(win, { pos[1] + 1, 0 }) end
    end, map_opts)

    vim.keymap.set("n", "<Up>", function()
        if not vim.api.nvim_win_is_valid(win) then return end
        local pos = vim.api.nvim_win_get_cursor(win)
        if pos[1] > 1 then vim.api.nvim_win_set_cursor(win, { pos[1] - 1, 0 }) end
    end, map_opts)

    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = buf,
        callback = function()
            if not vim.api.nvim_win_is_valid(win) then return true end
            clamp_cursor()
        end,
    })

    -- Initial load
    load_dir(current_path)
end

return M
