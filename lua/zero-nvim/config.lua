--- 插件配置：默认值 + setup(opts) 合并结果。
--- 其他模块一律通过 config.get() 读取（setup 之前也能拿到默认值，
--- 方便测试 / 提前 require 的模块）。
local M = {}

local defaults = {
    daemon = {
        path = nil,
        build_type = "debug",
    },
    log = {
        level = vim.log.levels.INFO,
        prefix = "ZeroNvim: ",
    },
    explorer = "builtin",
    gitsigns = {
        -- 远端没有 .git/HEAD 文件监听，靠事件 + 可选轮询代偿。详见
        -- lua/zero-nvim/gitsigns/refresh.lua 头部注释。
        refresh = {
            debounce_ms = 300, -- 事件触发的 debounce + in-flight 释放节奏
            poll_ms = 0,       -- 0 = 关闭轮询；> 0 时每 poll_ms 检查一次
        },
    },
    neogit = {
        -- 与 neogit/watcher.lua 的内建默认值一致
        watcher = {
            debounce_ms = 200,
            poll_ms = 0,
        },
    },
}

local options = vim.deepcopy(defaults)
local configured = false

---@param opts? table
---@return table options
function M.setup(opts)
    options = vim.tbl_deep_extend("force", defaults, opts or {})
    configured = true
    return options
end

---@return table
function M.get()
    return options
end

--- True once setup() has run.
---@return boolean
function M.is_configured()
    return configured
end

return M
