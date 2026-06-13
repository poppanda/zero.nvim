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

print("LSP restart state test passed")
