--- 通用浮窗组件：居中浮窗、单行输入框、JSON 编辑窗、开关 footer 文案。
local util = require("zero-nvim.util")

local M = {}

--- Create a centered floating window
---@param opts { title?: string, footer?: string, width?: number, height?: number }
---@return integer buf, integer win
function M.create(opts)
    opts = opts or {}
    local width = opts.width or 60
    local height = opts.height or 15
    local ew, eh = util.editor_size()
    local row = math.floor((eh - height) / 2)
    local col = math.floor((ew - width) / 2)

    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = opts.title and (" " .. opts.title .. " ") or nil,
        title_pos = opts.title and "center" or nil,
        footer = opts.footer and (" " .. opts.footer .. " ") or nil,
        footer_pos = opts.footer and "center" or nil,
    })

    -- Window styling
    vim.api.nvim_set_option_value("winhl", "Normal:NormalFloat,FloatBorder:FloatBorder", { win = win })
    vim.api.nvim_set_option_value("cursorline", true, { win = win })

    return buf, win
end

--- Close a floating window safely
---@param win integer?
---@param buf integer?
function M.close(win, buf)
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
    end
end

--- Show a floating single-line input prompt
---@param opts { title: string, default?: string }
---@param on_confirm fun(text: string) 仅在输入非空时调用
function M.prompt(opts, on_confirm)
    local buf, win = M.create({
        title = opts.title,
        width = 40,
        height = 1,
        footer = "<Enter>: Confirm",
    })

    if opts.default then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { opts.default })
    end

    local function close()
        M.close(win, buf)
        vim.cmd("stopinsert")
    end

    local function confirm()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
        local text = vim.trim(lines[1] or "")
        close()
        if text ~= "" then
            on_confirm(text)
        end
    end

    vim.keymap.set("i", "<CR>", confirm, { buffer = buf })
    vim.keymap.set("n", "<CR>", confirm, { buffer = buf })
    vim.keymap.set("n", "<Esc>", close, { buffer = buf })
    vim.keymap.set("i", "<Esc>", close, { buffer = buf })
    vim.keymap.set("n", "q", close, { buffer = buf })

    vim.cmd("startinsert")
    -- Ensure cursor is at end of line
    if opts.default then
        vim.api.nvim_win_set_cursor(win, { 1, #opts.default })
    end
end

--- Edit a JSON object in a floating window. Save (`:w`) parses, validates, and
--- invokes on_save with the decoded table; closing the window cancels.
---@param name string Buffer-name suffix, e.g. project name
---@param tbl table
---@param on_save fun(new_tbl: table)
function M.edit_json(name, tbl, on_save)
    local formatted_json = require("zero-nvim.project.store").format_json(tbl) or "{}"
    local content = vim.split(formatted_json, "\n")

    local buf, win = M.create({ title = "Edit Config: " .. name, width = 80, height = 20 })

    -- Set buffer name and type for correct write behavior
    -- Use a simple name to avoid special character issues
    pcall(vim.api.nvim_buf_set_name, buf, string.format("zero-project-%s.json", name))

    vim.api.nvim_set_option_value("buftype", "acwrite", { buf = buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = buf })

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    vim.api.nvim_set_option_value("filetype", "json", { buf = buf })
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

    vim.notify("Edit config and write (:w) to save. Close window to cancel.", vim.log.levels.INFO)

    -- Auto-save on write
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function()
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
            if not ok then
                vim.notify("Invalid JSON: " .. tostring(decoded), vim.log.levels.ERROR)
                return
            end

            on_save(decoded)
            vim.api.nvim_set_option_value("modified", false, { buf = buf })
            M.close(win, buf)
        end,
    })
end

--- 搜索输入框的开关 footer 文案："  [x]Aa  [ ]word  "
---@param case_sensitive boolean
---@param whole_word boolean
---@return string
function M.toggle_footer(case_sensitive, whole_word)
    return string.format("  %sAa  %sword  ",
        case_sensitive and "[x]" or "[ ]",
        whole_word and "[x]" or "[ ]")
end

return M
