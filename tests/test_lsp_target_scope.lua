package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local client_select = require("zero-nvim.lsp.client_select")

local clients = {
    {
        id = 1,
        name = "zero-pyright",
        config = { root_dir = "/repo", _zero_target = "alice@dev-a:22" },
        is_stopped = function() return false end,
    },
    {
        id = 2,
        name = "zero-pyright",
        config = { root_dir = "/repo", _zero_target = "bob@dev-b:22" },
        is_stopped = function() return false end,
    },
}

local selected = client_select.select_attach_clients_for_path(clients, "bob@dev-b:22", "/repo/pkg/main.py")

if not selected["zero-pyright"] then
    error("expected zero-pyright to be selected")
end
if selected["zero-pyright"].id ~= 2 then
    error("selected client from wrong target: " .. vim.inspect(selected["zero-pyright"]))
end

print("LSP target scope test passed")
