local utils = require("zero-nvim.ui.utils")

local M = {}

--- Display SSH Host picker floating window
---@param hosts table[] List from ssh_config.parse()
---@param on_select fun(entry: table) Callback with selected host entry
function M.pick_host(hosts, on_select)
    if #hosts == 0 then
        vim.notify("ZeroNvim: No hosts found in ~/.ssh/config", vim.log.levels.WARN)
        return
    end

    -- Build display lines
    local display_lines = {}

    -- Calculate how wide we need
    local max_width = 40
    for _, entry in ipairs(hosts) do
        local hostname = entry.hostname or entry.host
        local user = entry.user or vim.env.USER or "?"
        local port_str = entry.port ~= 22 and (":" .. entry.port) or ""
        local line = string.format("  %-16s  %s@%s%s", entry.host, user, hostname, port_str)
        max_width = math.max(max_width, #line + 4)
        table.insert(display_lines, line)
    end

    local final_width = math.min(max_width, 70)

    local win_height = math.min(#display_lines, 20)
    local buf, win = utils.create_float({
        title = "SSH Hosts",
        footer = "j/k:Move | CR:Select | q:Cancel",
        width = final_width,
        height = win_height,
    })

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })

    -- Place cursor on first real entry
    vim.api.nvim_win_set_cursor(win, { 1, 0 })

    local host_count = #hosts

    -- Helper: clamp cursor to host entries only
    local function clamp_cursor()
        local pos = vim.api.nvim_win_get_cursor(win)
        if pos[1] > host_count then
            vim.api.nvim_win_set_cursor(win, { host_count, 0 })
        end
        if pos[1] < 1 then
            vim.api.nvim_win_set_cursor(win, { 1, 0 })
        end
    end

    -- Keymaps
    local close = function()
        utils.close_float(win, buf)
    end

    local select = function()
        local pos = vim.api.nvim_win_get_cursor(win)
        local idx = pos[1]
        if idx >= 1 and idx <= host_count then
            local entry = hosts[idx]
            utils.close_float(win, buf)
            vim.schedule(function() on_select(entry) end)
        end
    end

    local move_down = function()
        local pos = vim.api.nvim_win_get_cursor(win)
        if pos[1] < host_count then
            vim.api.nvim_win_set_cursor(win, { pos[1] + 1, 0 })
        end
    end

    local move_up = function()
        local pos = vim.api.nvim_win_get_cursor(win)
        if pos[1] > 1 then
            vim.api.nvim_win_set_cursor(win, { pos[1] - 1, 0 })
        end
    end

    local map_opts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("n", "<CR>", select, map_opts)
    vim.keymap.set("n", "q", close, map_opts)
    vim.keymap.set("n", "<Esc>", close, map_opts)
    vim.keymap.set("n", "j", move_down, map_opts)
    vim.keymap.set("n", "k", move_up, map_opts)
    vim.keymap.set("n", "<Down>", move_down, map_opts)
    vim.keymap.set("n", "<Up>", move_up, map_opts)

    -- Prevent cursor from entering hints area
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = buf,
        callback = function()
            if not vim.api.nvim_win_is_valid(win) then return true end
            clamp_cursor()
        end,
    })
end

return M
