local M = {}
local zero = require("zero-nvim")
local manager = require("zero-nvim.project.manager")


--- Attempt to start a remote LSP via the TCP proxy daemon.
--- Works on `zero://` buffers (both file and directory).
---@param bufnr? integer Buffer number (defaults to current buffer)
---@param cmd_args string[] Language server command and args (e.g. {"basedpyright", "--stdio"})
---@param settings? table Optional settings for the language server (e.g. { python = { pythonPath = ... } })
function M.start_lsp(bufnr, cmd_args, settings)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(bufnr)

    local user, host, port, path = zero.parse_uri(name)
    if not user then
        vim.notify("ZeroNvim: Current buffer is not a zero:// buffer (got: " .. name .. ")",
            vim.log.levels.ERROR)
        return
    end

    -- [NEW] Project Configuration Merging
    local server_name = cmd_args[1]
    local project_name, project_config = manager.match_project(host, path)

    -- Prefer the registered project root so the language server has full
    -- visibility of the project. Falling back to the file's parent directory
    -- means cross-directory jumps may produce results outside root_dir.
    -- root_dir MUST be a plain path (not a zero:// URI): vim.uri_from_fname
    -- would produce file://zero://... which crashes LSP servers on rootPath.
    local root_dir
    if project_config and project_config.root then
        root_dir = project_config.root:gsub("/+$", "")
    else
        local is_dir = (path:sub(-1) == "/")
        root_dir = is_dir and path or vim.fs.dirname(path)
        root_dir = root_dir:gsub("/$", "")
    end

    local lsp_name = "zero-" .. server_name

    -- Check if there's already an active client for this project root
    -- DO THIS EARLY to avoid starting duplicate SSH proxy processes!
    for _, client in ipairs(vim.lsp.get_clients({ name = lsp_name })) do
        if client.config and client.config.root_dir == root_dir then
            -- Found existing client for this root, just attach and return
            local already = vim.lsp.get_clients({ bufnr = bufnr, id = client.id })
            if #already == 0 then
                vim.notify(string.format("ZeroNvim: LSP %s already active for root %s, attaching to buffer %d.", lsp_name, root_dir, bufnr), vim.log.levels.DEBUG)
                vim.lsp.buf_attach_client(bufnr, client.id)
            end
            return
        end
    end

    if project_config and project_config.lsp and project_config.lsp[server_name] then
        local p_conf = project_config.lsp[server_name]

        -- Override Command
        if p_conf.cmd and #p_conf.cmd > 0 then
            cmd_args = p_conf.cmd
            vim.notify("ZeroNvim: Using project-specific LSP command for " .. server_name, vim.log.levels.DEBUG)
        end

        -- Merge Settings
        if p_conf.settings then
            settings = vim.tbl_deep_extend("force", settings or {}, p_conf.settings)
            vim.notify("ZeroNvim: Merged project-specific LSP settings for " .. server_name, vim.log.levels.DEBUG)
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

    local client_prefix = string.format("zero://%s@%s:%d", user, host, port)

    -- Auto-detect pythonPath for pyright/basedpyright if not explicitly configured.
    -- Without a valid pythonPath, basedpyright's analysis thread can deadlock and stop
    -- responding to hover/definition requests even after a successful initialize.
    if server_name:match("pyright") and not (settings and settings.python and settings.python.pythonPath) then
        local ok_exec, python_path = pcall(vim.fn.rpcrequest, chan, "exec_remote", user, host, port,
            "which python3 2>/dev/null || which python 2>/dev/null || echo ''")
        if ok_exec and type(python_path) == "string" and #vim.trim(python_path) > 0 then
            settings = vim.tbl_deep_extend("force", settings or {}, { python = { pythonPath = vim.trim(python_path) } })
            vim.notify("ZeroNvim: Auto-detected pythonPath: " .. vim.trim(python_path), vim.log.levels.DEBUG)
        end
    end

    local ok, local_port = pcall(vim.fn.rpcrequest, chan, "lsp_start", user, host, port, cmd_str, client_prefix)
    if not ok or type(local_port) ~= "number" then
        vim.notify("ZeroNvim: Failed to start LSP proxy: " .. tostring(local_port), vim.log.levels.ERROR)
        return
    end

    vim.notify("ZeroNvim: LSP Proxy started on port " .. local_port .. " for " .. server_name, vim.log.levels.DEBUG)

    -- Use start_client (not start) to ALWAYS create a fresh TCP connection.
    -- vim.lsp.start would deduplicate and return the old dead client's id without
    -- connecting to our new listener port.
    local capabilities = vim.lsp.protocol.make_client_capabilities()
    -- Disable didChangeWatchedFiles since Neovim's fs.watch (libuv) doesn't work on zero:// URIs
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
            -- M6 Task 1: Workspace Root — explicitly force rootUri/rootPath to the
            -- remote file:// path so the LSP always sees the correct project root.
            -- root_dir is already a plain remote path (e.g. /home/user/project),
            -- but setting it here guards against any edge case where Neovim's
            -- machinery might derive a zero:// URI (which language servers do not
            -- understand) from an open buffer name.
            params.rootPath = root_dir
            params.rootUri = vim.uri_from_fname(root_dir)
            -- workspaceFolders: fix any zero:// URIs that Neovim may have added
            -- before our before_init ran.
            if params.workspaceFolders then
                for _, wf in ipairs(params.workspaceFolders) do
                    if wf.uri and wf.uri:match("^zero://") then
                        wf.uri = vim.uri_from_fname(root_dir)
                        wf.name = vim.fn.fnamemodify(root_dir, ":t")
                    end
                end
            end
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
            string.format("ZeroNvim: LSP %s attached to buffer", lsp_name),
            vim.log.levels.DEBUG
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
                    vim.log.levels.DEBUG
                )
            end
        end, 3000)
    else
        vim.notify("ZeroNvim: vim.lsp.start_client returned nil — client could not be created", vim.log.levels.ERROR)
    end
end

return M
