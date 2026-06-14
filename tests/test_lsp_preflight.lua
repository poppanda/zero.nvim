package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local zero = require("zero-nvim")
local lsp = require("zero-nvim.lsp")

local calls = {}
local notifications = {}
zero.ensure_connection = function(user, host, port)
    table.insert(calls, { kind = "ensure", user = user, host = host, port = port })
    return 42
end
zero.uses_password_auth = function(_, host, _)
    return host == "password-host"
end
vim.fn.rpcrequest = function(chan, method, ...)
    table.insert(calls, { kind = "rpc", chan = chan, method = method, args = { ... } })
    local args = { ... }
    if method == "lsp_probe" and args[2] == "old-daemon" then
        error("Vim:Invoking 'lsp_probe' on channel 42:\nUnknown method: lsp_probe")
    end
    return { ok = true, message = "" }
end
vim.notify = function(msg, level)
    table.insert(notifications, { msg = msg, level = level })
end

local ok, msg = lsp.preflight("alice", "password-host", 22, { "pyright-langserver", "--stdio" })
if ok ~= false then
    error("password-auth preflight should fail")
end
if not msg:match("SSH key/agent") then
    error("password-auth message should explain key/agent requirement: " .. tostring(msg))
end

ok, msg = lsp.preflight("alice", "dev", 22, { "pyright-langserver", "--stdio" })
if ok ~= true then
    error("expected successful preflight, got: " .. tostring(msg))
end

local rpc_call
for _, call in ipairs(calls) do
    if call.kind == "rpc" then
        rpc_call = call
    end
end
if not rpc_call then
    error("expected lsp_probe RPC")
end
if rpc_call.method ~= "lsp_probe" then
    error("expected lsp_probe RPC, got " .. tostring(rpc_call.method))
end
if rpc_call.args[4][1] ~= "pyright-langserver" then
    error("expected argv array to be passed to lsp_probe")
end

ok, msg = lsp.preflight("alice", "old-daemon", 22, { "rust-analyzer" })
if ok ~= true then
    error("old daemon without lsp_probe should fall back to best-effort startup, got: " .. tostring(msg))
end

local warned = false
for _, note in ipairs(notifications) do
    if note.msg:match("does not support lsp_probe") then
        warned = true
    end
end
if not warned then
    error("expected warning for daemon without lsp_probe")
end

print("LSP preflight test passed")
