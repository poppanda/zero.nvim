--- :ZeroSearch 的文件类型多选浮窗（C-t 打开）。
local util = require("zero-nvim.util")

local M = {}

-- ripgrep 内置 type（已排序）；其余类型走 --glob '*.<ext>'
M.BUILTIN = {
    "c", "cpp", "css", "go", "h", "html", "java", "js", "json",
    "lua", "md", "py", "rust", "sh", "sql", "toml", "ts", "txt", "xml", "yaml",
}
local builtin_set = {}
for _, t in ipairs(M.BUILTIN) do builtin_set[t] = true end

---@param t string
---@return boolean
function M.is_builtin(t)
    return builtin_set[t] == true
end

local WIDTH = 28
local MAX_HEIGHT = 15

--- 打开类型选择器。
---@param opts { row: integer, col: integer, selected: string[], on_close: fun(types: string[]) }
function M.open(opts)
    local selected_set = {}
    local custom_types = {}
    for _, t in ipairs(opts.selected) do
        selected_set[t] = true
        if not builtin_set[t] then table.insert(custom_types, t) end
    end

    local filter_query = ""
    local searching = false
    local items = {}

    local function rebuild()
        local all = vim.list_extend(vim.list_extend({}, M.BUILTIN), custom_types)
        table.sort(all)
        items = {}
        for _, t in ipairs(all) do
            if items[#items] ~= t and (filter_query == "" or t:find(filter_query, 1, true)) then
                table.insert(items, t)
            end
        end
    end
    rebuild()

    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = opts.row,
        col = opts.col,
        width = WIDTH,
        height = math.min(MAX_HEIGHT, math.max(1, #items)),
        style = "minimal",
        border = "rounded",
        title = { { " File Type ", "FloatTitle" } },
        title_pos = "left",
        footer = " Space:Toggle /:Search Tab:Add ",
        footer_pos = "center",
        zindex = 100,
    })
    vim.wo[win].winhl = "NormalFloat:TelescopeResultsNormal,FloatBorder:TelescopeResultsBorder"
    vim.wo[win].cursorline = true
    local ns = vim.api.nvim_create_namespace("ZeroSearchTypePicker")

    local function render()
        local lines = {}
        for _, t in ipairs(items) do
            table.insert(lines, string.format(" %s %s", selected_set[t] and "[x]" or "[ ]", t))
        end
        if #lines == 0 then lines = { "  (no match)" } end
        util.set_lines(buf, lines)
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        for i, t in ipairs(items) do
            if selected_set[t] then vim.api.nvim_buf_add_highlight(buf, ns, "String", i - 1, 0, -1) end
        end
        if not vim.api.nvim_win_is_valid(win) then return end
        vim.api.nvim_win_set_height(win, math.min(MAX_HEIGHT, #lines))
        local title = { { " File Type ", "FloatTitle" } }
        if searching or filter_query ~= "" then
            vim.list_extend(title, {
                { " Search: ", "Comment" },
                { filter_query .. (searching and "│" or ""), "String" },
                { " ", "FloatBorder" },
            })
        end
        vim.api.nvim_win_set_config(win, { title = title, title_pos = "left" })
    end
    vim.bo[buf].modifiable = false
    render()

    local function close()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
        if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
        local types = vim.tbl_keys(selected_set)
        table.sort(types)
        opts.on_close(types)
    end

    local function refresh()
        rebuild()
        render()
    end

    local function add_custom_type()
        local input = vim.trim(filter_query):gsub("^%*?%.?", "")
        if input == "" then return end
        if not builtin_set[input] and not vim.tbl_contains(custom_types, input) then
            table.insert(custom_types, input)
        end
        selected_set[input] = true
        filter_query, searching = "", false
        refresh()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
    end

    --- "/"：同步读键过滤（getcharstr 循环），Esc/Enter/空退格结束过滤但保留结果
    local function start_search()
        if searching then return end
        searching, filter_query = true, ""
        refresh()
        local bs = vim.api.nvim_replace_termcodes("<BS>", true, false, true)
        while true do
            vim.cmd("redraw")
            local ok, ch = pcall(vim.fn.getcharstr)
            if not ok then break end
            local byte = string.byte(ch)
            if ch == "\t" then return add_custom_type() end
            if byte == 20 then return close() end -- Ctrl-T
            if byte == 127 or byte == 8 or ch == bs then
                if filter_query == "" then break end
                filter_query = vim.fn.strcharpart(filter_query, 0, vim.fn.strchars(filter_query) - 1)
            elseif byte >= 32 then -- 可打印字符；Esc / Enter / 其他控制键结束过滤
                filter_query = filter_query .. ch
            else
                break
            end
            refresh()
        end
        searching = false
        render()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
    end

    local map_opts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("n", "<Space>", function()
        local t = items[vim.api.nvim_win_get_cursor(win)[1]]
        if not t then return end
        selected_set[t] = not selected_set[t] or nil
        render()
    end, map_opts)
    vim.keymap.set("n", "/", start_search, map_opts)
    vim.keymap.set("n", "<Tab>", function()
        if filter_query ~= "" then add_custom_type() end
    end, map_opts)
    -- 清空过滤
    vim.keymap.set("n", "<BS>", function()
        if filter_query == "" then return end
        filter_query = ""
        refresh()
    end, map_opts)
    for _, lhs in ipairs({ "<CR>", "<Esc>", "q", "<C-t>" }) do
        vim.keymap.set("n", lhs, close, map_opts)
    end
end

return M
