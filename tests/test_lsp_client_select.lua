package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local select = require("zero-nvim.lsp.client_select")

local function client(id, name, target, root)
    return {
        id = id,
        name = name,
        config = { _zero_target = target, root_dir = root },
        is_stopped = function() return false end,
    }
end

local reusable = select.select_reusable_client({
    client(1, "zero-pyright", "alice@dev-a:22", "/repo"),
    client(2, "zero-pyright", "bob@dev-b:22", "/repo"),
    client(3, "zero-pyright", "bob@dev-b:22", "/repo/pkg"),
}, "zero-pyright", "bob@dev-b:22", "/repo/pkg/sub")

if not reusable or reusable.id ~= 3 then
    error("expected most-specific same-target reusable client, got " .. vim.inspect(reusable))
end

local attach = select.select_attach_clients_for_path({
    client(1, "zero-pyright", "alice@dev-a:22", "/repo"),
    client(2, "zero-pyright", "bob@dev-b:22", "/workspace/app"),
    client(3, "zero-gopls", "bob@dev-b:22", "/workspace/go"),
}, "bob@dev-b:22", "/home/bob/.cache/pypoetry/virtualenvs/pkg/site.py")

if not attach["zero-pyright"] or attach["zero-pyright"].id ~= 2 then
    error("expected same-target fallback attach for pyright, got " .. vim.inspect(attach))
end
if attach["zero-pyright"].config._zero_target ~= "bob@dev-b:22" then
    error("fallback attach crossed target boundary")
end

print("LSP client selection test passed")
