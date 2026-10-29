--- zero-* LSP client 的复用 / 附着选择（纯函数，便于测试）。
local uri = require("zero-nvim.uri")

local M = {}

--- Neovim LSP client name for a server. ALWAYS keyed by the project-config
--- key (e.g. "pyright"), never by the binary in cmd[1] — autostart, prewarm,
--- :ZeroLspStart and restart must agree or duplicate clients get started.
function M.client_name(server_key)
    return "zero-" .. server_key
end

--- 一个 (server, remote, root) 的唯一 key："zero-<key>@user@host:port:<root>"。
--- 启动锁与 dormant 表共用。
function M.client_key(server_key, user, host, port, root_dir)
    return M.client_name(server_key) .. "@" .. uri.target_key(user, host, port) .. ":" .. uri.norm_root(root_dir)
end

local function root_covers(parent, child)
    parent, child = uri.norm_root(parent), uri.norm_root(child)
    if parent == "" then return false end
    if parent == child then return true end
    return child:sub(1, #parent + 1) == parent .. "/"
end

local function common_path_components(a, b)
    local n, pa, pb = 0, 1, 1
    while pa <= #a and pb <= #b do
        local ea = a:find("/", pa, true) or (#a + 1)
        local eb = b:find("/", pb, true) or (#b + 1)
        if a:sub(pa, ea - 1) ~= b:sub(pb, eb - 1) then break end
        n = n + 1
        pa, pb = ea + 1, eb + 1
    end
    return n
end

local function usable_zero_client(client, target)
    local cfg = client and client.config
    return client
        and client.name
        and client.name:match("^zero%-")
        and cfg
        and cfg._zero_target == target
        and not (client.is_stopped and client.is_stopped())
end

function M.select_reusable_client(clients, lsp_name, target, root_dir)
    root_dir = uri.norm_root(root_dir)
    local best
    local best_len = -1

    for _, client in ipairs(clients or {}) do
        if client.name == lsp_name and usable_zero_client(client, target) then
            local croot = uri.norm_root(client.config.root_dir)
            if croot == root_dir then
                return client
            end
            if root_covers(croot, root_dir) and #croot > best_len then
                best, best_len = client, #croot
            end
        end
    end

    return best
end

function M.select_attach_clients_for_path(clients, target, path)
    local best_by_name = {}
    local best_root_len = {}
    local fallback_by_name = {}
    local fallback_score = {}

    for _, client in ipairs(clients or {}) do
        if usable_zero_client(client, target) then
            local croot = uri.norm_root(client.config.root_dir)
            if croot ~= "" then
                if root_covers(croot, path) then
                    if (best_root_len[client.name] or -1) < #croot then
                        best_by_name[client.name] = client
                        best_root_len[client.name] = #croot
                    end
                else
                    local score = common_path_components(croot, path)
                    if (fallback_score[client.name] or -1) < score then
                        fallback_by_name[client.name] = client
                        fallback_score[client.name] = score
                    end
                end
            end
        end
    end

    for name, client in pairs(fallback_by_name) do
        if not best_by_name[name] then
            best_by_name[name] = client
        end
    end

    return best_by_name
end

return M
