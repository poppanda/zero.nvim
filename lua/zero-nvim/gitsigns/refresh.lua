-- =============================================================================
-- zero-nvim/gitsigns/refresh.lua — 远程 buffer 的 sign 刷新触发器
-- =============================================================================
-- 本地 gitsigns 用 uv.fs_event 监听 .git/HEAD；远程没法直接监听文件系统。
-- 这里用两层补偿：
--   (1) 事件触发（默认开）：BufEnter / FocusGained / BufWritePost 命中 zero://
--       buffer 时，debounce 300ms 后跑一次 :Gitsigns refresh。覆盖了"切回 buffer
--       /回到 nvim 窗口/自己改完保存"这几条最常见的"HEAD 可能变了"路径。
--   (2) 可选轮询：poll_ms > 0 时启动一个 uv timer，按节奏跑——但仅当当前 win
--       列表里至少有一个 zero:// buffer 时才发。focus 不在 nvim 上时 vim 自己
--       不会调度，timer callback 也就空跑无害。
--
-- :Gitsigns refresh 是 gitsigns 的公开 API：清 sign、重附所有 attached buffer、
-- 重抓 baseline、重算 hunks。我们用全局 debounce + in-flight gate 防止短时间
-- 内多个 autocmd 把它跑成 N 次。

local M = {}

local uv = vim.uv or vim.loop

local debounce_ms = 300
local poll_ms = 0

local debounce_timer
local poll_timer
local in_flight = false

--- 当前是否至少有一个 zero:// buffer 摆在某个 window 上。
--- 用 win 列表而非 buffer 列表：未显示的 buffer 即使 attached 也不必为它轮询。
---@return boolean
local function any_zero_window_visible()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) then
            local buf = vim.api.nvim_win_get_buf(win)
            local name = vim.api.nvim_buf_get_name(buf)
            if name:sub(1, 7) == "zero://" then
                return true
            end
        end
    end
    return false
end

--- 真正跑刷新；in-flight gate 确保上一次没回来时新请求被丢弃（防 thrash）。
local function do_refresh()
    if in_flight then return end
    in_flight = true
    -- :Gitsigns refresh 内部是 async 的（attach + 多条 git 命令），同步触发即返；
    -- 真正完成由 gitsigns 内部 coroutine 决定。我们只能用启发式：等够 1 个
    -- debounce 周期再放开 in_flight，避免连续触发把 daemon 打爆。
    local ok = pcall(vim.cmd, "silent! Gitsigns refresh")
    if not ok then
        -- gitsigns 没装 / refresh 报错都不该让 in_flight 卡死
        in_flight = false
        return
    end
    vim.defer_fn(function() in_flight = false end, debounce_ms)
end

--- 入口：autocmd / timer 都走这里。debounce 把同时段的多次触发合成一次。
local function schedule_refresh()
    if not debounce_timer then
        debounce_timer = uv.new_timer()
    end
    debounce_timer:stop()
    debounce_timer:start(debounce_ms, 0, vim.schedule_wrap(do_refresh))
end

--- 配置轮询。poll_ms <= 0 时彻底不创建 timer——零开销。
---
--- 注意：poll 不走 debounce_timer，而是直接调 do_refresh（带 in-flight gate）。
--- 道理：debounce 用来合并"短时间内多个事件"；poll 自身就是固定节奏，再 debounce
--- 反而会导致 poll_ms < debounce_ms 时 debounce timer 被反复重置永远不触发。
local function configure_poll()
    if poll_timer then
        poll_timer:stop()
        poll_timer:close()
        poll_timer = nil
    end
    if poll_ms <= 0 then return end
    poll_timer = uv.new_timer()
    poll_timer:start(poll_ms, poll_ms, vim.schedule_wrap(function()
        if any_zero_window_visible() then
            do_refresh()
        end
    end))
end

--- 公开入口；幂等。opts: { debounce_ms?, poll_ms? }
---@param opts table?
function M.setup(opts)
    opts = opts or {}
    debounce_ms = opts.debounce_ms or 300
    poll_ms = opts.poll_ms or 0

    local group = vim.api.nvim_create_augroup("ZeroNvimGitsignsRefresh", { clear = true })

    -- BufEnter: 切到一个 zero:// buffer 时立刻预约一次刷新（debounce 会合并）
    -- BufWritePost: 自己写完，hunks 一定变了
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
        group = group,
        pattern = "zero://*",
        callback = schedule_refresh,
    })

    -- FocusGained: 整个 nvim 窗口失焦后回来——期间用户可能在终端跑了 git pull
    -- 等改 HEAD 的命令。仅在当前 buffer 是 zero:// 时触发，避免本地 buffer 也吃刷新。
    vim.api.nvim_create_autocmd("FocusGained", {
        group = group,
        callback = function()
            local name = vim.api.nvim_buf_get_name(0)
            if name:sub(1, 7) == "zero://" then
                schedule_refresh()
            end
        end,
    })

    configure_poll()
end

return M
