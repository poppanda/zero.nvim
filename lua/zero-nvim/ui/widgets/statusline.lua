-- =============================================================================
-- ui/widgets/statusline.lua — 流式命令状态条（P0 占位，P1 填）
-- =============================================================================
-- 显示当前流式命令的进度："running / N items / throttled" 等。

local M = {}

function M.attach(_bufnr, _session_id)
    -- TODO(P1): 在 session 进度更新时刷新状态行
end

return M
