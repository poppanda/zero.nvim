local M = {}

local client_select = require("zero-nvim.lsp.client_select")

M.MAX_RESTART_ATTEMPTS = 3
M.BACKOFF_SECS = { 1, 2, 4, 8, 16, 30, 60 }
M.MAX_DORMANT_SECS = 30 * 60

local state = {
    active_lsps = {},
    intentional_stops = {},
    pending_transport_restarts = {},
    stale_restart_exits = {},
    dormant_lsps = {},
}

local function has_key(t, key)
    return t[key] ~= nil
end

function M.track(client_id, entry)
    state.active_lsps[client_id] = entry
end

function M.entry(client_id)
    return state.active_lsps[client_id]
end

function M.remove_active(client_id)
    local entry = state.active_lsps[client_id]
    state.active_lsps[client_id] = nil
    return entry
end

function M.reset_attempts(client_id)
    local entry = state.active_lsps[client_id]
    if entry then
        entry.attempts = 0
    end
end

function M.mark_intentional_stop(client_id)
    state.intentional_stops[client_id] = true
end

function M.is_intentional_stop(client_id)
    return has_key(state.intentional_stops, client_id)
end

function M.consume_intentional_stop(client_id)
    local marked = has_key(state.intentional_stops, client_id)
    state.intentional_stops[client_id] = nil
    return marked
end

function M.mark_stale_exit(client_id)
    state.stale_restart_exits[client_id] = true
end

function M.consume_stale_exit(client_id)
    local marked = has_key(state.stale_restart_exits, client_id)
    state.stale_restart_exits[client_id] = nil
    return marked
end

function M.set_pending_transport_restart(client_id, pending)
    state.pending_transport_restarts[client_id] = pending
end

function M.pending_transport_restart(client_id)
    return state.pending_transport_restarts[client_id]
end

function M.consume_pending_transport_restart(client_id)
    local pending = state.pending_transport_restarts[client_id]
    state.pending_transport_restarts[client_id] = nil
    return pending
end

function M.resolve_exit(client_id, entry, attached, code)
    M.remove_active(client_id)

    if M.consume_stale_exit(client_id) then
        M.consume_pending_transport_restart(client_id)
        M.consume_intentional_stop(client_id)
        return { kind = "ignore" }
    end

    local pending = M.consume_pending_transport_restart(client_id)
    if pending then
        return {
            kind = "restart",
            entry = pending.entry or entry,
            attached = pending.attached or attached,
            reason = pending.reason,
        }
    end

    if M.consume_intentional_stop(client_id) then
        return {
            kind = "notify_exit",
            intentional = true,
            level = "info",
        }
    end

    if not entry then
        return {
            kind = "notify_exit",
            level = (code == 0 or code == nil) and "info" or "warn",
        }
    end

    return {
        kind = "restart",
        entry = entry,
        attached = attached,
        reason = code == 0 and "连接断开 (EOF)" or "异常退出",
    }
end

function M.queue_transport_restart(client_id, entry, attached, reason)
    if not entry or M.is_intentional_stop(client_id) then
        return false
    end

    M.set_pending_transport_restart(client_id, {
        entry = entry,
        attached = attached,
        reason = reason,
    })
    return true
end

function M.resolve_transport_fallback(client_id)
    if not M.entry(client_id) or not M.pending_transport_restart(client_id) then
        return { kind = "ignore" }
    end

    local pending = M.consume_pending_transport_restart(client_id)
    return {
        kind = "restart",
        entry = pending.entry,
        attached = pending.attached,
        reason = pending.reason,
    }
end

function M.dormant_key_for(entry)
    return "zero-" .. entry.server_name .. "@"
        .. client_select.target_key(entry.user, entry.host, entry.port) .. ":" .. entry.root_dir
end

function M.cancel_timer(timer)
    if not timer then return end
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
end

function M.get_dormant(key)
    return state.dormant_lsps[key]
end

function M.set_dormant(key, dormant)
    state.dormant_lsps[key] = dormant
end

function M.clear_dormant(key)
    local dormant = state.dormant_lsps[key]
    if dormant then
        M.cancel_timer(dormant.timer)
    end
    state.dormant_lsps[key] = nil
end

function M.dormant_keys()
    if vim and vim.tbl_keys then
        return vim.tbl_keys(state.dormant_lsps)
    end

    local keys = {}
    for key, _ in pairs(state.dormant_lsps) do
        table.insert(keys, key)
    end
    return keys
end

function M.dormant_count()
    if vim and vim.tbl_count then
        return vim.tbl_count(state.dormant_lsps)
    end

    local count = 0
    for _, _ in pairs(state.dormant_lsps) do
        count = count + 1
    end
    return count
end

function M._reset_for_tests()
    for _, dormant in pairs(state.dormant_lsps) do
        M.cancel_timer(dormant.timer)
    end
    state.active_lsps = {}
    state.intentional_stops = {}
    state.pending_transport_restarts = {}
    state.stale_restart_exits = {}
    state.dormant_lsps = {}
end

return M
