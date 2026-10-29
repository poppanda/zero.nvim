local float = require("zero-nvim.ui.float")
local log = require("zero-nvim.log")
local ssh_config = require("zero-nvim.ssh_config")

local M = {}

--- Display SSH Host picker floating window
---@param hosts table[] List from ssh_config.parse()
---@param on_select fun(entry: table) Callback with selected host entry
function M.pick_host(hosts, on_select)
    if #hosts == 0 then
        log.warn("No hosts found in ~/.ssh/config")
        return
    end

    local lines = {}
    local max_width = 40
    for _, entry in ipairs(hosts) do
        local port = tonumber(entry.port) or 22
        local line = string.format("  %-16s  %s@%s%s", entry.host, entry.user or ssh_config.default_user(),
            entry.hostname or entry.host, port ~= 22 and (":" .. port) or "")
        max_width = math.max(max_width, #line + 4)
        table.insert(lines, line)
    end

    -- buffer 只有 host 行，光标天然不会越界，无需自定义 j/k / clamp
    local buf, win, close = float.menu({
        title = "SSH Hosts",
        footer = "j/k:Move | CR:Select | q:Cancel",
        width = math.min(max_width, 70),
        height = math.min(#lines, 20),
    }, lines)
    vim.keymap.set("n", "<CR>", function()
        local entry = hosts[vim.api.nvim_win_get_cursor(win)[1]]
        if not entry then return end
        close()
        vim.schedule(function() on_select(entry) end)
    end, { buffer = buf, silent = true, nowait = true })
end

return M
