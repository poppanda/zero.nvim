local M = {}

--- Create a centered floating window
---@param opts { title?: string, width?: number, height?: number }
---@return integer buf, integer win
function M.create_float(opts)
    opts = opts or {}
    local width = opts.width or 60
    local height = opts.height or 15
    local ui = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }
    local row = math.floor((ui.height - height) / 2)
    local col = math.floor((ui.width - width) / 2)

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
---@param win integer
---@param buf integer
function M.close_float(win, buf)
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
    end
end

return M
