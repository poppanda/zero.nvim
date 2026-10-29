-- =============================================================================
-- zero-nvim/neogit/watcher.lua — neogit fork 的远端 .git/ 监听适配
-- =============================================================================
-- 本地 neogit 用 vim.uv.new_fs_event() 监听 .git/；远端靠 zero-nvim/refresher.lua
-- 的事件 + 可选轮询代偿。
--
-- 单一 watcher 支撑多个 watch session（多个远端 repo 同时打开 :Neogit）：
-- start() 注册 session，触发时 fan-out 到所有 session 的 on_event（不区分
-- git_dir：远端无法知道哪个仓库变了，neogit 自己的 refresh 很便宜）。
-- 没有 session 时事件 / 轮询都不触发。

local refresher = require("zero-nvim.refresher")
local log = require("zero-nvim.log")

local M = {}

-- 注册中的 watch session：sessions[session_id] = { id, ctx, git_dir, on_event }
local sessions = {}
local sid_counter = 0

local r = refresher.new({
    group = "ZeroNvimNeogitWatcher",
    debounce_ms = 200,
    enabled = function() return next(sessions) ~= nil end,
    run = function()
        for _, s in pairs(sessions) do
            local ok, err = pcall(s.on_event, nil)
            if not ok then
                -- session 自身挂了不该影响别的 session
                log.warn(("neogit watcher: session %s on_event err: %s"):format(s.id, tostring(err)))
            end
        end
    end,
})

local autocmds_installed = false

--- 公开入口：注册一个 watch session。返回 unwatch 函数。
--- 由 zero-nvim/neogit/backend.lua 的 M.watch 调用，间接由 fork neogit 的
--- Watcher:start 触发。
---@param ctx       table
---@param git_dir   string  远端 .git/ 路径（informational only）
---@param on_event  fun(filename: string?)
---@return function unwatch
function M.start(ctx, git_dir, on_event)
    if not autocmds_installed then
        autocmds_installed = true
        r.install_autocmds()
    end

    sid_counter = sid_counter + 1
    local sid = "watch-" .. sid_counter
    sessions[sid] = { id = sid, ctx = ctx, git_dir = git_dir, on_event = on_event }

    -- 注册时立即触发一次：让 :Neogit 打开后第一次 status 数据是新鲜的
    vim.defer_fn(function()
        if sessions[sid] then pcall(on_event, nil) end
    end, 50)

    return function()
        sessions[sid] = nil
    end
end

--- 公开入口：模块级配置（debounce / poll）。可选；不调也走默认值。
---@param opts? { debounce_ms?: integer, poll_ms?: integer }
function M.setup(opts)
    r.configure(opts)
end

--- 调试辅助：当前活跃 session 数
function M.active_count()
    local n = 0
    for _ in pairs(sessions) do n = n + 1 end
    return n
end

return M
