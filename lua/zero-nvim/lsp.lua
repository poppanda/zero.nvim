local M = {}
local zero = require("zero-nvim")
local manager = require("zero-nvim.project.manager")

-- In-flight start lock keyed by "lsp_name:root_dir". Prevents racing starts
-- when prewarm and FileType-autostart both fire for the same root.
local starting = {}

-- 已启动的 LSP 注册表 — key 是 client_id，value 含重启所需的全部参数。
-- on_exit 时查表自动重启；on_init 成功时清零 attempts。
local active_lsps = {}
local MAX_RESTART_ATTEMPTS = 3

--- Build LSP client capabilities with workspace/didChangeWatchedFiles disabled
--- (Neovim's libuv fs_event watcher does not understand zero:// URIs).
local function make_caps()
    local capabilities = vim.lsp.protocol.make_client_capabilities()
    if capabilities.workspace and capabilities.workspace.didChangeWatchedFiles then
        capabilities.workspace.didChangeWatchedFiles.dynamicRegistration = false
    end
    return capabilities
end

--- Resolve pythonPath for pyright/basedpyright with caching.
--- The first probe round-trips to the remote `which python3`; later calls
--- hit the in-memory cache on init.lua state.
local function maybe_inject_python_path(chan, user, host, port, server_name, settings)
    if not server_name:match("pyright") then return settings end
    if settings and settings.python and settings.python.pythonPath then return settings end

    local cached = zero.get_python_path(user, host, port)
    if not cached then
        local ok, py = pcall(vim.fn.rpcrequest, chan, "exec_remote", user, host, port,
            "which python3 2>/dev/null || which python 2>/dev/null || echo ''")
        if ok and type(py) == "string" and #vim.trim(py) > 0 then
            cached = vim.trim(py)
            zero.set_python_path(user, host, port, cached)
            vim.notify("ZeroNvim: Auto-detected pythonPath: " .. cached, vim.log.levels.DEBUG)
        end
    end

    if cached then
        return vim.tbl_deep_extend("force", settings or {}, { python = { pythonPath = cached } })
    end
    return settings
end

--- Start a remote LSP client for `root_dir`, or return the existing one's id.
--- Buffer-less by design: prewarm and FileType-autostart both go through here.
---@param user string
---@param host string
---@param port integer
---@param root_dir string
---@param server_name string
---@param cmd_args string[]
---@param settings? table
---@return integer? client_id
---@return string? err
local function ensure_lsp_client(user, host, port, root_dir, server_name, cmd_args, settings)
    local lsp_name = "zero-" .. server_name
    local lock_key = lsp_name .. ":" .. root_dir

    -- Reuse an active client for this exact root_dir.
    -- 排除已经在 stopping 中的客户端，避免自动重启路径里捡到正在退出的旧 client。
    for _, client in ipairs(vim.lsp.get_clients({ name = lsp_name })) do
        if client.config and client.config.root_dir == root_dir
            and not (client.is_stopped and client.is_stopped()) then
            return client.id
        end
    end

    -- Another start is in flight for this (server, root). Bail; the in-flight
    -- caller will end up with the client and later attaches will reuse it.
    if starting[lock_key] then
        return nil, "STARTING"
    end
    starting[lock_key] = true

    local function clear_lock()
        starting[lock_key] = nil
    end

    local cmd_str = table.concat(cmd_args, " ")
    if not cmd_str or cmd_str == "" then
        clear_lock()
        return nil, "Missing LSP command"
    end

    local chan, err = zero.ensure_connection(user, host, port)
    if not chan then
        clear_lock()
        return nil, "Daemon not connected: " .. tostring(err)
    end

    settings = maybe_inject_python_path(chan, user, host, port, server_name, settings)

    local client_prefix = string.format("zero://%s@%s:%d", user, host, port)
    local ok, local_port = pcall(vim.fn.rpcrequest, chan, "lsp_start", user, host, port, cmd_str, client_prefix)
    if not ok or type(local_port) ~= "number" then
        clear_lock()
        return nil, "Failed to start LSP proxy: " .. tostring(local_port)
    end

    vim.notify("ZeroNvim: LSP Proxy started on port " .. local_port .. " for " .. server_name, vim.log.levels.DEBUG)

    local client_id = vim.lsp.start_client({
        name = lsp_name,
        cmd = vim.lsp.rpc.connect('127.0.0.1', local_port),
        root_dir = root_dir,
        capabilities = make_caps(),
        settings = settings,
        before_init = function(params)
            params.processId = vim.NIL
            -- Force rootUri/rootPath to a plain remote file:// path. zero:// URIs
            -- crash language servers; Neovim's machinery may otherwise inject one.
            params.rootPath = root_dir
            params.rootUri = vim.uri_from_fname(root_dir)
            if params.workspaceFolders then
                for _, wf in ipairs(params.workspaceFolders) do
                    if wf.uri and wf.uri:match("^zero://") then
                        wf.uri = vim.uri_from_fname(root_dir)
                        wf.name = vim.fn.fnamemodify(root_dir, ":t")
                    end
                end
            end
        end,
        on_init = function(client, _)
            clear_lock()
            -- 握手成功 → 重启计数清零，避免长期运行后偶发断连累积到上限
            if client and active_lsps[client.id] then
                active_lsps[client.id].attempts = 0
            end
        end,
        on_exit = function(code, signal, client_id_arg)
            clear_lock()
            local entry = active_lsps[client_id_arg]
            active_lsps[client_id_arg] = nil

            -- 抓住 client 还没销毁前已附着的 buffer 列表，重启后重新 attach
            local attached = {}
            local dying = vim.lsp.get_client_by_id(client_id_arg)
            if dying and dying.attached_buffers then
                for b, _ in pairs(dying.attached_buffers) do
                    if vim.api.nvim_buf_is_valid(b) then
                        table.insert(attached, b)
                    end
                end
            end

            -- 主动 stop / 没注册过 / 重启次数耗尽 → 不重启，仅通知
            if not entry or code == 0 or entry.attempts >= MAX_RESTART_ATTEMPTS then
                vim.schedule(function()
                    local level = (code == 0 or code == nil) and vim.log.levels.INFO or vim.log.levels.WARN
                    if entry and entry.attempts >= MAX_RESTART_ATTEMPTS then
                        level = vim.log.levels.ERROR
                        vim.notify(string.format(
                            "ZeroNvim: LSP '%s' 已重启 %d 次仍失败，停止自动重连。可手动 :ZeroLspStart 恢复。",
                            lsp_name, entry.attempts), level)
                    else
                        vim.notify(string.format(
                            "ZeroNvim: LSP '%s' exited (code=%s, signal=%s)",
                            lsp_name, tostring(code), tostring(signal)), level)
                    end
                end)
                return
            end

            -- 自动重启：递增退避 500ms / 1s / 1.5s
            entry.attempts = entry.attempts + 1
            local delay = 500 * entry.attempts
            vim.defer_fn(function()
                vim.notify(string.format(
                    "ZeroNvim: LSP '%s' 异常退出，自动重启 (第 %d 次)...",
                    lsp_name, entry.attempts), vim.log.levels.INFO)
                local new_id, err2 = ensure_lsp_client(
                    entry.user, entry.host, entry.port,
                    entry.root_dir, entry.server_name,
                    entry.cmd_args, entry.settings
                )
                if new_id then
                    -- 把新 client 重新 attach 到原来那些 buffer 上
                    for _, b in ipairs(attached) do
                        if vim.api.nvim_buf_is_valid(b) then
                            pcall(vim.lsp.buf_attach_client, b, new_id)
                        end
                    end
                    if #attached > 0 then
                        vim.notify(string.format(
                            "ZeroNvim: LSP '%s' 已恢复，重新附着 %d 个 buffer",
                            lsp_name, #attached), vim.log.levels.INFO)
                    end
                else
                    vim.notify(string.format(
                        "ZeroNvim: LSP '%s' 重启失败: %s",
                        lsp_name, tostring(err2)), vim.log.levels.ERROR)
                end
            end, delay)
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

    if not client_id then
        clear_lock()
        return nil, "vim.lsp.start_client returned nil"
    end

    -- 注册到 active_lsps，供 on_exit 自动重启使用。
    -- attempts 在 on_init 成功时清零，每次自动重启自增，到 MAX_RESTART_ATTEMPTS 停止。
    active_lsps[client_id] = {
        user = user,
        host = host,
        port = port,
        root_dir = root_dir,
        server_name = server_name,
        cmd_args = cmd_args,
        settings = settings,
        attempts = 0,
    }

    -- Safety net: clear the lock even if on_init never fires (server crashes
    -- mid-handshake). 5s is long enough for a normal initialize.
    vim.defer_fn(clear_lock, 5000)

    return client_id
end

--- Attempt to start a remote LSP via the TCP proxy daemon.
--- Works on `zero://` buffers (both file and directory).
---@param bufnr? integer Buffer number (defaults to current buffer)
---@param cmd_args string[] Language server command and args (e.g. {"basedpyright", "--stdio"})
---@param settings? table Optional settings for the language server
---@param opts? { project_config?: table, root_dir?: string }
---       Optional precomputed values from the caller (e.g. FileType handler) so
---       we don't redo project lookup. Both must come together if provided.
function M.start_lsp(bufnr, cmd_args, settings, opts)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    opts = opts or {}

    local name = vim.api.nvim_buf_get_name(bufnr)
    local user, host, port, path = zero.parse_uri(name)
    if not user then
        vim.notify("ZeroNvim: Current buffer is not a zero:// buffer (got: " .. name .. ")",
            vim.log.levels.ERROR)
        return
    end

    local server_name = cmd_args[1]
    local project_config = opts.project_config
    if project_config == nil then
        local _, pc = manager.match_project(host, path)
        project_config = pc
    end

    local root_dir = opts.root_dir
    if not root_dir then
        if project_config and project_config.root then
            root_dir = project_config.root:gsub("/+$", "")
        else
            local is_dir = (path:sub(-1) == "/")
            root_dir = is_dir and path or vim.fs.dirname(path)
            root_dir = root_dir:gsub("/$", "")
        end
    end

    if project_config and project_config.lsp and project_config.lsp[server_name] then
        local p_conf = project_config.lsp[server_name]
        if p_conf.cmd and #p_conf.cmd > 0 then
            cmd_args = p_conf.cmd
            vim.notify("ZeroNvim: Using project-specific LSP command for " .. server_name, vim.log.levels.DEBUG)
        end
        if p_conf.settings then
            settings = vim.tbl_deep_extend("force", settings or {}, p_conf.settings)
            vim.notify("ZeroNvim: Merged project-specific LSP settings for " .. server_name, vim.log.levels.DEBUG)
        end
    end

    local client_id, err = ensure_lsp_client(user, host, port, root_dir, server_name, cmd_args, settings)
    if not client_id then
        if err == "STARTING" then
            -- Another start is in flight for this (server, root). The in-flight
            -- caller will register the client; we just need to attach this buffer
            -- once it shows up. Retry twice (covers fast and slow `initialize`).
            local _bufnr, _root = bufnr, root_dir
            local lsp_name = "zero-" .. server_name
            local function try_attach()
                if not vim.api.nvim_buf_is_valid(_bufnr) then return true end
                for _, client in ipairs(vim.lsp.get_clients({ name = lsp_name })) do
                    if client.config and client.config.root_dir == _root then
                        local already = vim.lsp.get_clients({ bufnr = _bufnr, id = client.id })
                        if #already == 0 then
                            vim.lsp.buf_attach_client(_bufnr, client.id)
                        end
                        return true
                    end
                end
                return false
            end
            vim.defer_fn(function()
                if not try_attach() then vim.defer_fn(try_attach, 1500) end
            end, 500)
            return
        end
        vim.notify("ZeroNvim: " .. tostring(err), vim.log.levels.ERROR)
        return
    end

    if vim.api.nvim_buf_is_valid(bufnr) then
        local already = vim.lsp.get_clients({ bufnr = bufnr, id = client_id })
        if #already == 0 then
            vim.lsp.buf_attach_client(bufnr, client_id)
            vim.notify(
                string.format("ZeroNvim: LSP zero-%s attached to buffer %d", server_name, bufnr),
                vim.log.levels.DEBUG
            )
        end
    end
end

--- Pre-warm every LSP server declared in a project config without attaching to
--- a buffer. By the time the user opens their first file matching a configured
--- filetype, the LSP client is already running and the FileType-autostart path
--- short-circuits to a plain buf_attach_client.
---@param user string
---@param host string
---@param port integer
---@param project_config table
function M.prewarm_lsps(user, host, port, project_config)
    if not project_config or type(project_config.lsp) ~= "table" then return end
    if not project_config.root then return end
    local root_dir = project_config.root:gsub("/+$", "")

    for server_name, server_cfg in pairs(project_config.lsp) do
        local cmd_args = (server_cfg.cmd and #server_cfg.cmd > 0) and server_cfg.cmd or { server_name, "--stdio" }
        local settings = server_cfg.settings
        -- Schedule each server independently. Daemon RPC is single-threaded so
        -- they end up serialized anyway, but this keeps the trigger non-blocking.
        vim.schedule(function()
            ensure_lsp_client(user, host, port, root_dir, server_name, vim.deepcopy(cmd_args), settings)
        end)
    end
end

return M
