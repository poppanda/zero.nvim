-- =============================================================================
-- ui/widgets/list.lua — 通用 list widget（P0 占位，P1/P2 填实现）
-- =============================================================================
-- 标准化 list UI：项目数据 + 标准 keymap (j/k/<CR>/q/?) + 选中回调。
-- 目前只是占位文件；具体实现跟 Phase 1/2 的真实需求一起补全（避免过度抽象）。

local M = {}

--- TODO(P1): 把 host_picker / search_mini 中的 list 模式提取到这里
function M.create(_opts)
    error("widgets.list 未实现 — Phase 0 占位")
end

return M
