local M = {}
local zero = require("zero-nvim")
local manager = require("zero-nvim.project.manager")

--- Attempt to start a remote LSP via the TCP proxy daemon.
--- Works on both `remote://` file buffers and `oil-zero://` directory buffers.
---@param bufnr? integer Buffer number (defaults to current buffer)
---@param cmd_args string[] Language server command and args (e.g. {"basedpyright", "--stdio"})
---@param settings? table Optional settings for the language server (e.g. { python = { pythonPath = ... } })
function M.start_lsp(bufnr, cmd_args, settings)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(bufnr)

    local user, host, port, path = zero.parse_uri(name)
    if not user then
        vim.notify("ZeroNvim: Current buffer is not a remote:// or oil-zero:// buffer (got: " .. name .. ")",
            vim.log.levels.ERROR)
        return
    end

    -- [NEW] Project Configuration Merging
    local server_name = cmd_args[1]
    local project_name, project_config = manager.match_project(host, path)

    if project_config and project_config.lsp and project_config.lsp[server_name] then
        local p_conf = project_config.lsp[server_name]

        -- Override Command
        if p_conf.cmd and #p_conf.cmd > 0 then
            cmd_args = p_conf.cmd
            vim.notify("ZeroNvim: Using project-specific LSP command for " .. server_name, vim.log.levels.INFO)
        end

        -- Merge Settings
        if p_conf.settings then
            settings = vim.tbl_deep_extend("force", settings or {}, p_conf.settings)
            vim.notify("ZeroNvim: Merged project-specific LSP settings for " .. server_name, vim.log.levels.INFO)
        end
    end

    local cmd_str = table.concat(cmd_args, " ")
    if not cmd_str or cmd_str == "" then
        vim.notify("ZeroNvim: Missing LSP command", vim.log.levels.ERROR)
        return
    end

    local chan, err = zero.ensure_connection(user, host, port)
    if not chan then
        vim.notify("ZeroNvim: Daemon not connected: " .. tostring(err), vim.log.levels.ERROR)
        return
    end

    local ok, local_port = pcall(vim.fn.rpcrequest, chan, "lsp_start", user, host, port, cmd_str)
    if not ok or type(local_port) ~= "number" then
        vim.notify("ZeroNvim: Failed to start LSP proxy: " .. tostring(local_port), vim.log.levels.ERROR)
        return
    end

    vim.notify("ZeroNvim: LSP Proxy started on port " .. local_port .. " for " .. cmd_args[1], vim.log.levels.INFO)

    local is_dir = (path:sub(-1) == "/")
    local root_path = is_dir and path or vim.fs.dirname(path)
    root_path = root_path:gsub("/$", "")
    -- the LSP expects a normal local path for root_dir (which gets translated to rootUri and rootPath).
    -- If we use remote:// here, vim.uri_from_fname will produce file://remote://... which the daemon translates to file://file://...
    -- which causes language servers like basedpyright to crash on watch.fs(rootPath).
    local root_dir = root_path

    local lsp_name = "zero-" .. cmd_args[1]

    -- Stop any existing dead client with the same name to avoid vim.lsp.start reuse of corpses
    for _, client in ipairs(vim.lsp.get_clients({ name = lsp_name })) do
        client.stop(true) -- force-stop
    end

    -- Use start_client (not start) to ALWAYS create a fresh TCP connection.
    -- vim.lsp.start would deduplicate and return the old dead client's id without
    -- connecting to our new listener port.
    local capabilities = vim.lsp.protocol.make_client_capabilities()
    -- Disable didChangeWatchedFiles since Neovim's fs.watch (libuv) doesn't work on remote:// URIs
    -- or if the LSP tries to watch on the remote end, it fails with ENOENT and crashes.
    if capabilities.workspace and capabilities.workspace.didChangeWatchedFiles then
        capabilities.workspace.didChangeWatchedFiles.dynamicRegistration = false
    end

    local client_id = vim.lsp.start_client({
        name = lsp_name,
        cmd = vim.lsp.rpc.connect('127.0.0.1', local_port),
        root_dir = root_dir,
        capabilities = capabilities,
        settings = settings,
        before_init = function(params)
            params.processId = vim.NIL
        end,
        on_exit = function(code, signal)
            vim.schedule(function()
                vim.notify(
                    string.format("ZeroNvim: LSP '%s' exited (code=%s, signal=%s)", lsp_name, tostring(code),
                        tostring(signal)),
                    (code == 0 or code == nil) and vim.log.levels.INFO or vim.log.levels.WARN
                )
            end)
        end,
        on_error = function(code, err2)
            vim.schedule(function()
                vim.notify(
                    string.format("ZeroNvim: LSP '%s' error (code=%s): %s", lsp_name, tostring(code), tostring(err2)),
                    vim.log.levels.ERROR
                )
            end)
        end,
    })

    if client_id then
        vim.lsp.buf_attach_client(bufnr, client_id)
        vim.notify(
            string.format("ZeroNvim: LSP %s attached to buffer (id=%d, root=%s)", lsp_name, client_id, root_dir),
            vim.log.levels.INFO
        )
        -- Delayed status check
        vim.defer_fn(function()
            local clients = vim.lsp.get_clients({ bufnr = bufnr, name = lsp_name })
            if #clients == 0 then
                vim.notify("ZeroNvim: !! LSP " .. lsp_name .. " not active after 3s.", vim.log.levels.WARN)
            else
                local c = clients[1]
                vim.notify(
                    string.format("ZeroNvim: LSP %s is active (%s)", lsp_name,
                        c.initialized and "initialized" or "initializing"),
                    vim.log.levels.INFO
                )
            end
        end, 3000)
    else
        vim.notify("ZeroNvim: vim.lsp.start_client returned nil — client could not be created", vim.log.levels.ERROR)
    end
end

return M
