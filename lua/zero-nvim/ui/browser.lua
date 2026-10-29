local float = require("zero-nvim.ui.float")
local icons = require("zero-nvim.ui.icons")
local remote = require("zero-nvim.remote")
local uri = require("zero-nvim.uri")
local util = require("zero-nvim.util")
local log = require("zero-nvim.log")

local M = {}

local WIDTH = 65

--- 目录路径不带尾 "/"（根目录除外），与 on_confirm 之前的约定一致
local function strip_slash(p)
    return (p:gsub("(.)/+$", "%1"))
end

--- Browse remote directories in a floating window.
--- Press <CR> on a directory to enter it, <C-s> to confirm the current
--- directory, "-" or ".." to go up, "." to toggle hidden, q/<Esc> to cancel.
---
---@param user string
---@param hostname string
---@param port integer
---@param on_confirm fun(path: string) Called with the selected path
---@param opts? { start_path?: string, display_name?: string }
function M.browse_path(user, hostname, port, on_confirm, opts)
    opts = opts or {}
    -- 起始目录：优先远端真实 $HOME（macOS 是 /Users/<u>，root 是 /root），拿不到退回 "/"
    local current_path = opts.start_path or remote.remote_home(user, hostname, port) or "/"
    local display_name = opts.display_name or string.format("%s@%s", user, hostname)
    local show_hidden = false
    local raw_entries = {} -- daemon 返回的完整列表
    local shown = {}       -- 过滤 + 排序后实际显示的条目（第 1 行是 ".."）

    local buf, win, close = float.menu({
        title = display_name .. ":" .. current_path,
        footer = "CR:Enter | -:Parent | C-s:Open | .:Hidden | q:Cancel",
        width = WIDTH,
        height = 10, -- initial; resized in render()
    }, {})

    local function render()
        shown = {}
        for _, entry in ipairs(raw_entries) do
            if show_hidden or entry.name:sub(1, 1) ~= "." then table.insert(shown, entry) end
        end
        table.sort(shown, function(a, b)
            if a.type ~= b.type then return a.type == "directory" end
            return a.name < b.name
        end)

        local lines = { "  ↩️  ../" }
        for _, entry in ipairs(shown) do
            if entry.type == "directory" then
                table.insert(lines, "  📁 " .. entry.name .. "/")
            else
                table.insert(lines, "  " .. icons.for_ext(entry.name:match("%.([^%.]+)$")) .. " " .. entry.name)
            end
        end
        util.set_lines(buf, lines)

        -- 按内容调整高度并重新居中（最高 editor 高度 - 4）
        if vim.api.nvim_win_is_valid(win) then
            local ew, eh = util.editor_size()
            local height = math.min(#lines, eh - 4)
            vim.api.nvim_win_set_config(win, {
                relative = "editor",
                height = height,
                row = math.floor((eh - height) / 2),
                col = math.floor((ew - WIDTH) / 2),
                title = " " .. display_name .. ":" .. current_path .. " ",
                title_pos = "center",
            })
            vim.api.nvim_win_set_cursor(win, { 1, 0 })
        end
    end

    local loaded_once = false
    local function load_dir(path)
        current_path = path
        -- 直接 read_dir，不走 remote.list_dir：后者会顺带触发 scan_project
        -- （深度 3 的后台预取），浏览 / 或 $HOME 时代价太大
        local ok, entries = remote.request(user, hostname, port, "read_dir", path)
        if not ok then
            log.error("Failed to read directory — " .. tostring(entries))
            -- 第一次就失败（多半连不上）：直接关窗
            if not loaded_once then return close() end
        end
        loaded_once = true
        raw_entries = ok and entries or {}
        render()
    end

    local function go_up()
        load_dir(strip_slash(uri.parent_dir(current_path)))
    end

    local map_opts = { buffer = buf, silent = true, nowait = true }
    -- buffer 行数 = 条目数，默认 j/k 不会越界，无需自定义导航
    vim.keymap.set("n", "<CR>", function()
        local row = vim.api.nvim_win_get_cursor(win)[1]
        if row == 1 then return go_up() end
        local entry = shown[row - 1]
        if not entry then return end
        local path = strip_slash(uri.join(current_path, entry.name))
        if entry.type == "directory" then return load_dir(path) end
        close()
        vim.schedule(function() on_confirm(path) end)
    end, map_opts)
    vim.keymap.set("n", "<C-s>", function()
        close()
        vim.schedule(function() on_confirm(current_path) end)
    end, map_opts)
    vim.keymap.set("n", "-", go_up, map_opts)
    vim.keymap.set("n", ".", function()
        show_hidden = not show_hidden
        render() -- 同一份 raw_entries，不重新拉取
    end, map_opts)

    load_dir(current_path)
end

return M
