-- =============================================================================
-- ui/widgets/tree.lua — 可折叠树 widget（P0 占位，P1 填实现）
-- =============================================================================
-- 节点结构：{ id, label, expanded?, children?, render = fn(node) }
-- P1 时从 lua/zero-nvim/ui/search.lua 的 render_tree 抽取通用部分。

local M = {}

function M.create(_buf, _opts)
    error("widgets.tree 未实现 — Phase 1 填")
end

return M
