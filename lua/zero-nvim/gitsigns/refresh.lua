-- =============================================================================
-- zero-nvim/gitsigns/refresh.lua — 远程 buffer 的 sign 刷新触发器
-- =============================================================================
-- 本地 gitsigns 用 uv.fs_event 监听 .git/HEAD；远端靠 zero-nvim/refresher.lua
-- 的事件 + 可选轮询代偿，触发时跑 :Gitsigns refresh（公开 API：清 sign、重附
-- 所有 attached buffer、重抓 baseline、重算 hunks）。

local refresher = require("zero-nvim.refresher")
local uri = require("zero-nvim.uri")

local M = {}

local r = refresher.new({
    group = "ZeroNvimGitsignsRefresh",
    debounce_ms = 300,
    -- gitsigns 没装 / refresh 报错时返回 false，不让 in-flight gate 卡住
    run = function() return (pcall(vim.cmd, "silent! Gitsigns refresh")) end,
    -- 只在当前 buffer 是 zero:// 时响应 FocusGained，本地 buffer 不吃刷新
    on_focus = function() return uri.is_zero(vim.api.nvim_buf_get_name(0)) end,
})

--- 公开入口；幂等。
---@param opts? { debounce_ms?: integer, poll_ms?: integer }
function M.setup(opts)
    r.install_autocmds()
    r.configure(opts)
end

return M
