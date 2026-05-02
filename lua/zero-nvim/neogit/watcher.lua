-- =============================================================================
-- zero-nvim/neogit/watcher.lua — neogit fork 的远端 .git/ 监听适配
-- =============================================================================
-- 本地 neogit 用 vim.uv.new_fs_event() 监听 .git/，远端没法直接监听文件系统。
-- 这里用两层补偿（思路完全等同 zero-nvim/gitsigns/refresh.lua）：
--   (1) 事件触发（默认开）：BufWritePost / FocusGained / BufEnter 命中 zero://
--       buffer 时，debounce 200ms 后触发 on_event。覆盖了"自己改完保存 / 切回
--       nvim 窗口 / 切回某 zero buffer"几条最常见的"HEAD 可能变了"路径。
--   (2) 可选轮询：poll_ms > 0 时启动一个 uv timer，按节奏跑——但仅当存在
--       注册中的 watch session 时才发。focus 不在 nvim 上时 vim 自己不调度。
--
-- 单一 watcher 模块支撑多个 watch session（多个远端 repo 同时打开 :Neogit）：
-- start() 注册 session，autocmd / poll 触发时 fan-out 到所有匹配 git_dir 的
-- session 的 on_event。

local M = {}

local uv = vim.uv or vim.loop

local debounce_ms = 200
local poll_ms = 0

local debounce_timer
local poll_timer
local in_flight = false

-- 注册中的 watch session：sessions[session_id] = { ctx, git_dir, on_event }
local sessions = {}
local sid_counter = 0

local function gen_sid()
    sid_counter = sid_counter + 1
    return "watch-" .. sid_counter
end

--- 当前是否至少有一个 zero:// buffer 摆在某个 window 上。
--- 与 gitsigns/refresh 一致：用 win 列表而非 buffer 列表。
local function any_zero_window_visible()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) then
            local buf = vim.api.nvim_win_get_buf(win)
            local name = vim.api.nvim_buf_get_name(buf)
            if name:sub(1, 7) == "zero://" then return true end
        end
    end
    return false
end

--- 真正分发；in-flight gate 确保上一次未结束时新触发被丢弃，防止 thrash。
local function dispatch_all()
    if in_flight then return end
    in_flight = true
    -- on_event 内部会让 neogit watcher 调 dispatch_refresh，那是 async 的，
    -- 我们只能用启发式：等够 1 个 debounce 周期再放开 in-flight。
    for _, s in pairs(sessions) do
        local ok, err = pcall(s.on_event, nil)
        if not ok then
            -- session 自身挂了不该影响别的 session
            require("zero-nvim").log("WARN",
                ("[neogit watcher] session %s on_event err: %s"):format(s.id, tostring(err)))
        end
    end
    vim.defer_fn(function() in_flight = false end, debounce_ms)
end

--- 入口：autocmd / timer 都走这里。debounce 把同时段多次触发合成一次。
local function schedule()
    if not next(sessions) then return end
    if not debounce_timer then debounce_timer = uv.new_timer() end
    debounce_timer:stop()
    debounce_timer:start(debounce_ms, 0, vim.schedule_wrap(dispatch_all))
end

local function configure_poll()
    if poll_timer then
        poll_timer:stop()
        poll_timer:close()
        poll_timer = nil
    end
    if poll_ms <= 0 then return end
    poll_timer = uv.new_timer()
    poll_timer:start(poll_ms, poll_ms, vim.schedule_wrap(function()
        if next(sessions) and any_zero_window_visible() then
            dispatch_all()
        end
    end))
end

local autocmd_group_installed = false
local function ensure_autocmds()
    if autocmd_group_installed then return end
    autocmd_group_installed = true
    local group = vim.api.nvim_create_augroup("ZeroNvimNeogitWatcher", { clear = true })

    -- BufEnter / BufWritePost：切到一个 zero:// buffer / 自己写完
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
        group = group,
        pattern = "zero://*",
        callback = schedule,
    })

    -- FocusGained：整个 nvim 窗口失焦后回来——期间用户可能在终端跑了 git
    -- pull 等改 HEAD 的命令。仅在有 session 时才生效（schedule 自带空 sessions
    -- 的 early return），避免本地 buffer 也吃刷新。
    vim.api.nvim_create_autocmd("FocusGained", {
        group = group,
        callback = schedule,
    })
end

--- 公开入口：注册一个 watch session。返回 unwatch 函数。
--- 由 zero-nvim/neogit/backend.lua 的 M.watch 调用，间接由 fork neogit 的
--- Watcher:start 触发。
---@param ctx       table
---@param git_dir   string  远端 .git/ 路径（informational only）
---@param on_event  fun(filename: string?)
---@return function unwatch
function M.start(ctx, git_dir, on_event)
    ensure_autocmds()

    local sid = gen_sid()
    sessions[sid] = {
        id = sid,
        ctx = ctx,
        git_dir = git_dir,
        on_event = on_event,
    }

    -- 注册时立即触发一次：让 :Neogit 打开后第一次 status 数据是新鲜的
    vim.defer_fn(function()
        if sessions[sid] then
            pcall(on_event, nil)
        end
    end, 50)

    return function()
        sessions[sid] = nil
    end
end

--- 公开入口：模块级配置（debounce / poll）。可选；不调也走默认值。
---@param opts table?  { debounce_ms?, poll_ms? }
function M.setup(opts)
    opts = opts or {}
    debounce_ms = opts.debounce_ms or 200
    poll_ms = opts.poll_ms or 0
    configure_poll()
end

--- 调试辅助：当前活跃 session 数
function M.active_count()
    local n = 0
    for _ in pairs(sessions) do n = n + 1 end
    return n
end

return M
