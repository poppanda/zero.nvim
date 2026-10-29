--- 零散的通用小工具（不依赖插件其他状态）。
local uri = require("zero-nvim.uri")

local M = {}

--- 停止并关闭一个 libuv timer；nil / 已关闭都安全。
---@param t uv.uv_timer_t?
function M.close_timer(t)
    if not t then return end
    pcall(function()
        t:stop()
        if not t:is_closing() then t:close() end
    end)
end

--- 整体替换 buffer 内容，临时打开 'modifiable'，结束后恢复原值。
---@param buf integer
---@param lines string[]
function M.set_lines(buf, lines)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local was = vim.bo[buf].modifiable
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = was
end

--- 编辑器尺寸（headless 下没有 UI 时给 80x24 兜底）。
---@return integer width
---@return integer height
function M.editor_size()
    local ui = vim.api.nvim_list_uis()[1]
    if ui then return ui.width, ui.height end
    return vim.o.columns > 0 and vim.o.columns or 80, vim.o.lines > 0 and vim.o.lines or 24
end

--- 当前是否至少有一个 zero:// buffer 摆在某个 window 上。
--- 用 win 列表而非 buffer 列表：未显示的 buffer 不必为它轮询。
---@return boolean
function M.any_zero_window_visible()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win)
            and uri.is_zero(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))) then
            return true
        end
    end
    return false
end

return M
