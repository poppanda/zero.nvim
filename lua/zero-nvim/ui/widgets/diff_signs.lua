-- =============================================================================
-- ui/widgets/diff_signs.lua — git diff sign + virt_text 渲染（P0 占位，P2 填）
-- =============================================================================
-- attach(bufnr, repo_root, relpath)  → 启动 sign 渲染
-- detach(bufnr)                      → 清掉所有 sign 和 autocmd
-- refresh(bufnr)                     → 重跑 git diff 并渲染

local M = {}

function M.attach(_bufnr, _repo_root, _relpath)
    error("widgets.diff_signs.attach 未实现 — Phase 2 填")
end

function M.detach(_bufnr)
    error("widgets.diff_signs.detach 未实现 — Phase 2 填")
end

function M.refresh(_bufnr)
    error("widgets.diff_signs.refresh 未实现 — Phase 2 填")
end

return M
