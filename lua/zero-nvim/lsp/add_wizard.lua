-- =============================================================================
-- lsp/add_wizard.lua — :ZeroLspAdd interactive wizard
-- =============================================================================
-- Three-step state machine:
--   1. Pick server  (mason bins ⊕ Manual entry, [*] tags existing entries)
--   2. Resolve preset / ask filetypes / merge with existing entry
--   3. Preview JSON; <CR> save, <C-e> tweak inline, <Esc> cancel
--
-- After save: deep-merge into the project store and prewarm the LSP so the
-- first matching file the user opens attaches without further wait.

local M = {}

local float         = require("zero-nvim.ui.float")
local util          = require("zero-nvim.util")
local log           = require("zero-nvim.log")
local manager       = require("zero-nvim.project.manager")
local presets       = require("zero-nvim.lsp.presets")
local lsp           = require("zero-nvim.lsp")

-- ---------------------------------------------------------------------------
-- Save + prewarm
-- ---------------------------------------------------------------------------

local function save_and_prewarm(ctx, server_name, server_cfg)
    if not manager.upsert_lsp(ctx.project_name, server_name, server_cfg) then
        return
    end
    log.info(string.format("added LSP %s to project %s", server_name, ctx.project_name))
    vim.schedule(function()
        local fresh = manager.get(ctx.project_name)
        if fresh then lsp.prewarm_lsps(ctx.user, ctx.host, ctx.port, fresh) end
    end)
end

-- ---------------------------------------------------------------------------
-- Step 3: Preview
-- ---------------------------------------------------------------------------

local function step3_preview(ctx, server_name, server_cfg)
    local payload = { [server_name] = server_cfg }
    local lines = vim.split(util.format_json(payload) or "{}", "\n")

    local height = math.min(math.max(#lines + 2, 8), 25)
    local buf, _, close = float.menu({
        title = "Preview LSP entry: " .. ctx.project_name,
        footer = "<CR>:Save | <C-e>:Edit | <Esc>:Cancel",
        width = 80,
        height = height,
    }, lines)
    vim.bo[buf].filetype = "json"

    vim.keymap.set("n", "<CR>", function()
        close()
        save_and_prewarm(ctx, server_name, server_cfg)
    end, { buffer = buf, silent = true })

    vim.keymap.set("n", "<C-e>", function()
        close()
        -- Edit the same { [server] = cfg } shape; on save extract the entry.
        float.edit_json(ctx.project_name .. "-" .. server_name, payload, function(new_payload)
            local new_cfg = new_payload[server_name]
            if type(new_cfg) ~= "table" then
                log.error("edited JSON missing key '" .. server_name .. "'")
                return
            end
            save_and_prewarm(ctx, server_name, new_cfg)
        end)
    end, { buffer = buf, silent = true })
end

-- ---------------------------------------------------------------------------
-- Step 2: resolve preset / ask filetypes / merge with existing
-- ---------------------------------------------------------------------------

local function step2_resolve(ctx, server_name)
    local preset, canonical = presets.lookup(server_name)
    -- If user picked the mason wrapper (e.g. "basedpyright"), keep that name as
    -- the project key so it matches the bin they have on disk; only swap to the
    -- canonical name when there's no existing entry under either key.
    local existing = ctx.project_config.lsp and ctx.project_config.lsp[server_name]
    if not existing and canonical and canonical ~= server_name then
        local under_canonical = ctx.project_config.lsp and ctx.project_config.lsp[canonical]
        if under_canonical then
            server_name = canonical
            existing = under_canonical
        end
    end

    -- Edit mode: server already configured; preset (if any) supplies defaults
    -- but existing values win on conflicts.
    if existing then
        local merged = vim.tbl_deep_extend("force", preset and vim.deepcopy(preset) or {}, existing)
        return step3_preview(ctx, server_name, merged)
    end

    -- Preset hit, no existing entry: use preset directly.
    if preset then
        return step3_preview(ctx, server_name, vim.deepcopy(preset))
    end

    -- Preset miss + no existing entry: ask for filetypes.
    float.prompt({ title = "Filetypes for " .. server_name .. " (comma-separated)" }, function(input)
        local fts = {}
        for ft in input:gmatch("[^,%s]+") do
            table.insert(fts, ft)
        end
        if #fts == 0 then
            log.warn("cancelled (no filetypes)")
            return
        end
        step3_preview(ctx, server_name, { filetypes = fts, cmd = lsp.server_cmd(server_name) })
    end)
end

-- ---------------------------------------------------------------------------
-- Step 1: server picker
-- ---------------------------------------------------------------------------

local function step1_pick(ctx)
    local function build_rows()
        local bins = lsp.mason_bins(ctx.user, ctx.host, ctx.port)
        table.sort(bins)
        local rows = {}
        local existing_set = {}
        if ctx.project_config.lsp then
            for k, _ in pairs(ctx.project_config.lsp) do existing_set[k] = true end
        end
        for _, name in ipairs(bins) do
            local mark = existing_set[name] and " [*]" or ""
            table.insert(rows, { kind = "bin", name = name, label = "  " .. name .. mark })
        end
        if #rows == 0 then
            table.insert(rows, { kind = "empty", label = "  <no mason bins cached — press r to refresh>" })
        end
        table.insert(rows, { kind = "manual", label = "  + Manual entry…" })
        return rows
    end

    local rows = build_rows()
    local lines = vim.tbl_map(function(r) return r.label end, rows)

    local height = math.min(math.max(#lines, 8), 20)
    local buf, win, close = float.menu({
        title = "Add LSP to " .. ctx.project_name,
        footer = "<CR>:Select | r:Refresh bins | <Esc>:Cancel",
        width = 60,
        height = height,
    }, lines)

    local function selected_row()
        local idx = vim.api.nvim_win_get_cursor(win)[1]
        return rows[idx]
    end

    local function commit(row)
        if not row or row.kind == "empty" then return end
        if row.kind == "bin" then
            close()
            step2_resolve(ctx, row.name)
        elseif row.kind == "manual" then
            close()
            float.prompt({ title = "LSP binary name" }, function(name)
                step2_resolve(ctx, name)
            end)
        end
    end

    vim.keymap.set("n", "<CR>", function() commit(selected_row()) end, { buffer = buf, silent = true })

    vim.keymap.set("n", "r", function()
        -- Force a re-scan; scan_mason_bins is sync (RPC request + readdir).
        lsp.scan_mason_bins(ctx.user, ctx.host, ctx.port)
        rows = build_rows()
        util.set_lines(buf, vim.tbl_map(function(r) return r.label end, rows))
        if rows[1].kind ~= "bin" then
            log.warn("no mason bins found, manual entry only")
        end
    end, { buffer = buf, silent = true })

    -- Position cursor at first non-empty row if possible.
    if rows[1] and rows[1].kind ~= "empty" then
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
    elseif #rows >= 2 then
        vim.api.nvim_win_set_cursor(win, { 2, 0 })
    end
end

-- ---------------------------------------------------------------------------
-- Public entry
-- ---------------------------------------------------------------------------

--- Open the wizard for a given project context.
---@param ctx { user:string, host:string, port:integer, project_name:string,
---            project_config:table, prefill_server?:string }
function M.open(ctx)
    if not ctx or not ctx.project_name or not ctx.project_config then
        log.error("wizard called without project context")
        return
    end
    if ctx.prefill_server and ctx.prefill_server ~= "" then
        step2_resolve(ctx, ctx.prefill_server)
    else
        step1_pick(ctx)
    end
end

return M
