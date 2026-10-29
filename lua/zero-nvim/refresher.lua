-- =============================================================================
-- zero-nvim/refresher.lua — 远端 "HEAD 可能变了" 刷新触发器（gitsigns / neogit 共用）
-- =============================================================================
-- 本地插件用 uv.fs_event 监听 .git/；远端没法直接监听文件系统。这里用两层补偿：
--   (1) 事件触发：BufEnter / BufWritePost 命中 zero:// buffer、或 FocusGained
--       时，debounce 后跑一次 run()。覆盖"切回 buffer / 回到 nvim 窗口 / 自己
--       改完保存"几条最常见的路径。
--   (2) 可选轮询：poll_ms > 0 时起一个 uv timer，仅当某个 window 上摆着
--       zero:// buffer 时才 run()。poll_ms <= 0 时根本不创建 timer。
--
-- run() 触发的刷新通常是 async 的，完成时机不可知；用启发式 in-flight gate：
-- run 之后等够一个 debounce 周期再放开，期间的新触发直接丢弃（防 thrash）。

local util = require("zero-nvim.util")

local M = {}

local uv = vim.uv or vim.loop

---@class ZeroRefresherOpts
---@field group string                 augroup 名
---@field debounce_ms integer          默认 debounce（configure 未给时）
---@field run fun(): boolean?          执行刷新；返回 false 表示失败，立即放开 gate
---@field enabled? fun(): boolean      false 时事件 / 轮询都不触发（默认恒 true）
---@field on_focus? fun(): boolean     FocusGained 时是否触发（默认恒 true）

---@param opts ZeroRefresherOpts
function M.new(opts)
    local enabled = opts.enabled or function() return true end
    local on_focus = opts.on_focus or function() return true end
    local default_debounce = opts.debounce_ms
    local debounce_ms = default_debounce
    local debounce_timer, poll_timer
    local in_flight = false

    local function fire()
        if in_flight then return end
        in_flight = true
        if opts.run() == false then
            in_flight = false
            return
        end
        vim.defer_fn(function() in_flight = false end, debounce_ms)
    end

    local self = {}

    --- 事件入口：debounce 把同时段多次触发合成一次。
    function self.schedule()
        if not enabled() then return end
        if not debounce_timer then debounce_timer = uv.new_timer() end
        debounce_timer:stop()
        debounce_timer:start(debounce_ms, 0, vim.schedule_wrap(fire))
    end

    --- 安装 autocmd（幂等：同名 augroup clear 后重建）。
    function self.install_autocmds()
        local group = vim.api.nvim_create_augroup(opts.group, { clear = true })
        vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
            group = group,
            pattern = "zero://*",
            callback = function() self.schedule() end,
        })
        -- 失焦期间用户可能在终端跑了 git pull 等改 HEAD 的命令
        vim.api.nvim_create_autocmd("FocusGained", {
            group = group,
            callback = function()
                if on_focus() then self.schedule() end
            end,
        })
    end

    --- 设置 debounce / poll 并（重）建轮询 timer。
    --- 轮询不走 debounce：它本身就是固定节奏，再 debounce 的话 poll_ms <
    --- debounce_ms 时 timer 会被反复重置永远不触发。
    ---@param o? { debounce_ms?: integer, poll_ms?: integer }
    function self.configure(o)
        o = o or {}
        debounce_ms = o.debounce_ms or default_debounce
        local poll_ms = o.poll_ms or 0
        util.close_timer(poll_timer)
        poll_timer = nil
        if poll_ms <= 0 then return end
        poll_timer = uv.new_timer()
        poll_timer:start(poll_ms, poll_ms, vim.schedule_wrap(function()
            if enabled() and util.any_zero_window_visible() then fire() end
        end))
    end

    return self
end

return M
