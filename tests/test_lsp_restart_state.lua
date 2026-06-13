package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local restart = require("zero-nvim.lsp.restart")

restart._reset_for_tests()

local entry = {
    user = "alice",
    host = "dev",
    port = 22,
    root_dir = "/repo",
    server_name = "pyright",
    attempts = 2,
}

restart.track(7, entry)
if restart.entry(7) ~= entry then
    error("expected tracked active entry")
end

restart.reset_attempts(7)
if restart.entry(7).attempts ~= 0 then
    error("expected attempts to reset")
end

restart.mark_intentional_stop(7)
if restart.consume_intentional_stop(7) ~= true then
    error("expected intentional stop marker to be consumed")
end
if restart.consume_intentional_stop(7) ~= false then
    error("intentional stop marker should be one-shot")
end

restart.mark_stale_exit(8)
restart.set_pending_transport_restart(8, { reason = "transport" })
if restart.consume_stale_exit(8) ~= true then
    error("expected stale restart marker to be consumed")
end
if restart.consume_pending_transport_restart(8) == nil then
    error("expected pending transport restart payload")
end
if restart.consume_stale_exit(8) ~= false then
    error("stale restart marker should be one-shot")
end

local key = restart.dormant_key_for(entry)
if key ~= "zero-pyright@alice@dev:22:/repo" then
    error("unexpected dormant key: " .. tostring(key))
end

restart.set_dormant(key, { entry = entry, attempts = 1 })
if restart.dormant_count() ~= 1 then
    error("expected one dormant entry")
end
local dormant = restart.get_dormant(key)
if not dormant or dormant.entry ~= entry then
    error("expected dormant entry to be retrievable")
end
restart.clear_dormant(key)
if restart.dormant_count() ~= 0 then
    error("expected dormant entry to be cleared")
end

restart._reset_for_tests()
local exit_entry = vim.tbl_extend("force", entry, { attempts = 1 })
restart.track(11, exit_entry)
local exit_action = restart.resolve_exit(11, exit_entry, { 101 }, 0)
if exit_action.kind ~= "restart" then
    error("expected registered clean exit to restart, got " .. vim.inspect(exit_action))
end
if exit_action.reason ~= "连接断开 (EOF)" then
    error("expected EOF restart reason, got " .. tostring(exit_action.reason))
end
if restart.entry(11) ~= nil then
    error("resolve_exit should remove active entry")
end

restart.track(12, exit_entry)
restart.mark_intentional_stop(12)
local intentional = restart.resolve_exit(12, exit_entry, {}, 1)
if intentional.kind ~= "notify_exit" or intentional.intentional ~= true then
    error("expected intentional stop notification, got " .. vim.inspect(intentional))
end
if restart.consume_intentional_stop(12) ~= false then
    error("intentional stop marker should be consumed by resolve_exit")
end

restart.track(13, exit_entry)
restart.mark_stale_exit(13)
restart.set_pending_transport_restart(13, { reason = "stale pending" })
restart.mark_intentional_stop(13)
local stale = restart.resolve_exit(13, exit_entry, {}, 1)
if stale.kind ~= "ignore" then
    error("expected stale duplicate exit to be ignored, got " .. vim.inspect(stale))
end
if restart.consume_pending_transport_restart(13) ~= nil or restart.consume_intentional_stop(13) ~= false then
    error("stale exit should clear pending and intentional markers")
end

local pending_entry = vim.tbl_extend("force", entry, { server_name = "gopls" })
restart.track(14, exit_entry)
restart.set_pending_transport_restart(14, {
    entry = pending_entry,
    attached = { 202 },
    reason = "连接断开",
})
local pending = restart.resolve_exit(14, exit_entry, { 101 }, 1)
if pending.kind ~= "restart" or pending.entry ~= pending_entry or pending.attached[1] ~= 202 then
    error("expected pending transport restart payload, got " .. vim.inspect(pending))
end

local untracked = restart.resolve_exit(15, nil, {}, 0)
if untracked.kind ~= "notify_exit" or untracked.level ~= "info" then
    error("expected untracked clean exit info notification, got " .. vim.inspect(untracked))
end

restart.track(16, exit_entry)
restart.mark_intentional_stop(16)
if restart.queue_transport_restart(16, exit_entry, { 303 }, "连接断开") ~= false then
    error("transport restart should not queue for intentional stops")
end
restart.consume_intentional_stop(16)
if restart.queue_transport_restart(16, exit_entry, { 303 }, "连接断开") ~= true then
    error("transport restart should queue for active unintentional clients")
end
local fallback = restart.resolve_transport_fallback(16)
if fallback.kind ~= "restart" or fallback.attached[1] ~= 303 then
    error("expected transport fallback restart, got " .. vim.inspect(fallback))
end

print("LSP restart state test passed")
