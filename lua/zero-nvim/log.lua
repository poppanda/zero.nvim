--- 统一的通知出口：前缀 + 级别过滤都来自 config.log。
local config = require("zero-nvim.config")

local M = {}

---@param msg string
---@param level integer vim.log.levels.*
function M.notify(msg, level)
    level = level or vim.log.levels.INFO
    local opts = config.get().log
    if level >= opts.level then
        vim.notify(opts.prefix .. msg, level)
    end
end

function M.debug(msg) M.notify(msg, vim.log.levels.DEBUG) end
function M.info(msg) M.notify(msg, vim.log.levels.INFO) end
function M.warn(msg) M.notify(msg, vim.log.levels.WARN) end
function M.error(msg) M.notify(msg, vim.log.levels.ERROR) end

return M
