--- 远端 LSP：经 daemon 的 TCP proxy 启动 zero-<key> client，负责自动启动 /
--- 附着 / 停止；退出后的自动重启与退避重连见 lsp/restart.lua。
local remote = require("zero-nvim.remote")
local uri = require("zero-nvim.uri")
local log = require("zero-nvim.log")
local manager = require("zero-nvim.project.manager")
local client_select = require("zero-nvim.lsp.client_select")
local restart = require("zero-nvim.lsp.restart")

local M = {}

-- In-flight start lock keyed by client_key. Prevents racing starts
-- when prewarm and FileType-autostart both fire for the same root.
local starting = {}
local lsp_probe_unsupported_warned = false

local client_name = client_select.client_name

--- Default command for a project LSP entry: its `cmd`, else {key, "--stdio"}.
--- Always returns a fresh copy (callers may mutate / keep it).
---@param key string project-config key
---@param cfg? table project lsp entry
---@return string[]
function M.server_cmd(key, cfg)
    if cfg and type(cfg.cmd) == "table" and #cfg.cmd > 0 then
        return vim.deepcopy(cfg.cmd)
    end
    return { key, "--stdio" }
end

--- Map a binary / user-supplied server name to its project-config key.
--- :ZeroLspStart pyright-langserver --stdio → "pyright" when the project
--- declares lsp.pyright.cmd = { "pyright-langserver", ... }.
---@param project_config? table
---@param name string
---@return string
local function resolve_server_key(project_config, name)
    local lsp = project_config and project_config.lsp
    if type(lsp) ~= "table" or not name then return name end
    if lsp[name] then return name end
    for key, cfg in pairs(lsp) do
        if type(cfg) == "table" and type(cfg.cmd) == "table" and cfg.cmd[1] == name then
            return key
        end
    end
    return name
end

-- ───── mason bins（:ZeroLspStart / :ZeroLspAdd 补全） ─────────────────────

--- Scan <remote-home>/.local/share/nvim/mason/bin/ and cache the bin names
--- in remote.host_cache. 结果（包括"没有 mason"）都会缓存。
function M.scan_mason_bins(user, host, port)
    local home = remote.remote_home(user, host, port)
    if not home then return end
    local ok, entries = remote.request(user, host, port, "read_dir", home .. "/.local/share/nvim/mason/bin")
    local bins = {}
    -- Mason 没装时 read_dir 失败 → 空表，补全里只是没有 mason bins
    for _, entry in ipairs(ok and type(entries) == "table" and entries or {}) do
        if entry.type == "file" then table.insert(bins, entry.name) end
    end
    remote.host_cache(user, host, port).mason_bins = bins
end

--- Cached mason bins for one remote; scanned lazily on first use when the
--- host is already connected. 缺参数时返回空表。
---@return string[]
function M.mason_bins(user, host, port)
    if not (user and host and port) then return {} end
    local cache = remote.host_cache(user, host, port)
    if cache.mason_bins == nil and remote.is_connected(user, host, port) then
        M.scan_mason_bins(user, host, port)
    end
    return cache.mason_bins or {}
end

-- ───── 内部工具 ─────────────────────────────────────────────────────────────

--- Attach `client_id` to `buf` unless already attached.
---@return boolean attached_now
local function attach(buf, client_id)
    if not vim.api.nvim_buf_is_valid(buf) then return false end
    if #vim.lsp.get_clients({ bufnr = buf, id = client_id }) > 0 then return false end
    return (pcall(vim.lsp.buf_attach_client, buf, client_id))
end

--- Build LSP client capabilities with workspace/didChangeWatchedFiles disabled
--- (Neovim's libuv fs_event watcher does not understand zero:// URIs).
local function make_caps()
    local capabilities = vim.lsp.protocol.make_client_capabilities()
    if capabilities.workspace and capabilities.workspace.didChangeWatchedFiles then
        capabilities.workspace.didChangeWatchedFiles.dynamicRegistration = false
    end
    return capabilities
end

--- Resolve pythonPath for pyright/basedpyright. The first probe round-trips to
--- the remote `which python3`; later starts hit remote.host_cache.
local function maybe_inject_python_path(user, host, port, server_desc, settings)
    if not tostring(server_desc):match("pyright") then return settings end
    if settings and settings.python and settings.python.pythonPath then return settings end

    local cache = remote.host_cache(user, host, port)
    if not cache.python_path then
        local ok, py = remote.request(user, host, port, "exec_remote",
            "which python3 2>/dev/null || which python 2>/dev/null || echo ''")
        if ok and type(py) == "string" and #vim.trim(py) > 0 then
            cache.python_path = vim.trim(py)
            log.debug("auto-detected pythonPath: " .. cache.python_path)
        end
    end

    if cache.python_path then
        return vim.tbl_deep_extend("force", settings or {}, { python = { pythonPath = cache.python_path } })
    end
    return settings
end

--- Check that the remote LSP can start: daemon connected with key/agent auth
--- (the LSP transport is non-interactive system ssh) and the binary exists.
---@return boolean ok
---@return string? err
function M.preflight(user, host, port, cmd_args)
    if type(cmd_args) ~= "table" or #cmd_args == 0 then
        return false, "Missing LSP command"
    end

    -- 走 module table（不缓存 local），测试会 monkeypatch remote.ensure_connection
    local chan, err = remote.ensure_connection(user, host, port)
    if not chan then
        return false, "Daemon not connected: " .. tostring(err)
    end

    if remote.uses_password_auth(user, host, port) then
        return false,
            "Remote LSP requires SSH key/agent auth; current connection used password auth, but the LSP transport runs through non-interactive system ssh"
    end

    local ok, res = remote.request(user, host, port, "lsp_probe", cmd_args)
    if not ok then
        if tostring(res):find("Unknown method: lsp_probe", 1, true) then
            if not lsp_probe_unsupported_warned then
                lsp_probe_unsupported_warned = true
                log.warn("daemon does not support lsp_probe; skipping LSP preflight. Rebuild the daemon and restart Neovim to enable preflight checks.")
            end
            return true
        end
        return false, "LSP preflight RPC failed: " .. tostring(res)
    end
    if type(res) == "table" and res.ok == true then
        return true
    end

    local msg = type(res) == "table" and (res.message or res.error) or tostring(res)
    if msg == nil or msg == "" then
        msg = "system ssh BatchMode probe failed or LSP binary was not found"
    end
    return false, "LSP preflight failed: " .. msg
end

--- Start a remote LSP client for `root_dir`, or return the existing one's id.
--- Buffer-less by design: prewarm and FileType-autostart both go through here.
---@param opts? { force_new?: boolean }
---@return integer? client_id
---@return string? err "STARTING" when another start is in flight
local function ensure_lsp_client(user, host, port, root_dir, server_name, cmd_args, settings, opts)
    -- 项目 root "/" 归一化后是 ""：LSP 的 rootUri 需要真实路径
    root_dir = client_select.norm_root(root_dir)
    if root_dir == "" then root_dir = "/" end
    local lsp_name = client_name(server_name)
    local tkey = uri.target_key(user, host, port)
    local lock_key = client_select.client_key(server_name, user, host, port, root_dir)

    -- Reuse an active client on the SAME remote whose root_dir already covers
    -- root_dir (exact match preferred; otherwise the most-specific ancestor).
    -- 不区分主机或允许仅子路径独立启动，会让 locations_to_items 的 auto-attach
    -- 把同一目标文件同时挂上多个 zero-<server> client，下次跳转就出现重复项。
    -- 排除已经在 stopping 中的客户端，避免自动重启路径里捡到正在退出的旧 client。
    if not (opts and opts.force_new) then
        local best = client_select.select_reusable_client(
            vim.lsp.get_clients({ name = lsp_name }), lsp_name, tkey, root_dir)
        if best then return best.id end
    end

    -- Another start is in flight for this (server, root). Bail; the in-flight
    -- caller will end up with the client and later attaches will reuse it.
    if starting[lock_key] then return nil, "STARTING" end
    starting[lock_key] = true
    local function clear_lock() starting[lock_key] = nil end

    local preflight_ok, preflight_err = M.preflight(user, host, port, cmd_args)
    if not preflight_ok then
        clear_lock()
        return nil, preflight_err
    end

    settings = maybe_inject_python_path(user, host, port,
        server_name .. " " .. tostring(cmd_args[1] or ""), settings)

    local ok, local_port = remote.request(user, host, port, "lsp_start", cmd_args, uri.prefix(user, host, port))
    if not ok or type(local_port) ~= "number" then
        clear_lock()
        return nil, "Failed to start LSP proxy: " .. tostring(local_port)
    end
    log.debug("LSP Proxy started on port " .. local_port .. " for " .. server_name)

    local client_id
    client_id = vim.lsp.start_client({
        name = lsp_name,
        cmd = vim.lsp.rpc.connect("127.0.0.1", local_port),
        root_dir = root_dir,
        capabilities = make_caps(),
        settings = settings,
        -- Stored on client.config so reuse can scope to the same remote.
        _zero_target = tkey,
        before_init = function(params)
            params.processId = vim.NIL
            -- Force rootUri/rootPath to a plain remote file:// path. zero:// URIs
            -- crash language servers; Neovim's machinery may otherwise inject one.
            params.rootPath = root_dir
            params.rootUri = vim.uri_from_fname(root_dir)
            for _, wf in ipairs(params.workspaceFolders or {}) do
                if uri.is_zero(wf.uri) then
                    wf.uri = vim.uri_from_fname(root_dir)
                    wf.name = vim.fn.fnamemodify(root_dir, ":t")
                end
            end
        end,
        on_init = function(client)
            clear_lock()
            -- 握手成功 → 重启计数清零，避免长期运行后偶发断连累积到上限
            if client then restart.reset_attempts(client.id) end
        end,
        on_exit = function(code, signal, id)
            clear_lock()
            restart.on_exit(id, lsp_name, code, signal)
        end,
        on_error = function(code, err) restart.on_error(client_id, lsp_name, code, err) end,
    })

    if not client_id then
        clear_lock()
        return nil, "vim.lsp.start_client returned nil"
    end

    -- 重启元数据：on_exit 据此自动重启，on_init 复位 attempts。
    restart.track(client_id, {
        user = user,
        host = host,
        port = port,
        root_dir = root_dir,
        server_name = server_name,
        cmd_args = cmd_args,
        settings = settings,
        attempts = 0,
    })

    -- Safety net: clear the lock even if on_init never fires (server crashes
    -- mid-handshake). 5s is long enough for a normal initialize.
    vim.defer_fn(clear_lock, 5000)

    return client_id
end

restart.set_starter(function(e)
    return ensure_lsp_client(e.user, e.host, e.port, e.root_dir, e.server_name, e.cmd_args, e.settings,
        { force_new = true })
end)

-- ───── 对外入口 ─────────────────────────────────────────────────────────────

--- Attempt to start a remote LSP via the TCP proxy daemon.
--- Works on `zero://` buffers (both file and directory).
---@param bufnr? integer Buffer number (nil / 0 = current buffer)
---@param cmd_args string[] Language server command and args (e.g. {"basedpyright", "--stdio"})
---@param settings? table Optional settings for the language server
---@param opts? { project_config?: table, root_dir?: string, server_key?: string }
---       Optional precomputed values from the caller (e.g. FileType handler) so
---       we don't redo project lookup. `server_key` is the project-config key
---       (defaults to the key whose name or cmd[1] matches cmd_args[1]).
function M.start_lsp(bufnr, cmd_args, settings, opts)
    if not bufnr or bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
    opts = opts or {}

    local name = vim.api.nvim_buf_get_name(bufnr)
    local user, host, port, path = uri.parse(name)
    if not user then
        log.error("current buffer is not a zero:// buffer (got: " .. name .. ")")
        return
    end
    if type(cmd_args) ~= "table" or not cmd_args[1] then
        log.error("missing LSP command")
        return
    end

    local project_config = opts.project_config
    if project_config == nil then
        project_config = select(2, manager.match_project(host, path, user, port))
    end
    local server_name = opts.server_key or resolve_server_key(project_config, cmd_args[1])

    local root_dir = opts.root_dir
    if not root_dir then
        if project_config and type(project_config.root) == "string" then
            root_dir = project_config.root
        else
            root_dir = path:sub(-1) == "/" and path or vim.fs.dirname(path)
        end
    end

    local p_conf = project_config and project_config.lsp and project_config.lsp[server_name]
    if p_conf then
        if p_conf.cmd and #p_conf.cmd > 0 then
            cmd_args = p_conf.cmd
            log.debug("using project-specific LSP command for " .. server_name)
        end
        if p_conf.settings then
            settings = vim.tbl_deep_extend("force", settings or {}, p_conf.settings)
            log.debug("merged project-specific LSP settings for " .. server_name)
        end
    end

    local lsp_name = client_name(server_name)
    local client_id, err = ensure_lsp_client(user, host, port, root_dir, server_name, cmd_args, settings)
    if client_id then
        if attach(bufnr, client_id) then
            log.debug(string.format("LSP %s attached to buffer %d", lsp_name, bufnr))
        end
    elseif err == "STARTING" then
        -- Another start is in flight for this (server, root). The in-flight
        -- caller will register the client; we just need to attach this buffer
        -- once it shows up. Retry twice (covers fast and slow `initialize`).
        local tkey = uri.target_key(user, host, port)
        local function try_attach()
            if not vim.api.nvim_buf_is_valid(bufnr) then return true end
            local client = client_select.select_reusable_client(
                vim.lsp.get_clients({ name = lsp_name }), lsp_name, tkey, root_dir)
            if client then attach(bufnr, client.id) end
            return client ~= nil
        end
        vim.defer_fn(function()
            if not try_attach() then vim.defer_fn(try_attach, 1500) end
        end, 500)
    else
        log.error(tostring(err))
    end
end

--- Pre-warm every LSP server declared in a project config without attaching to
--- a buffer. By the time the user opens their first file matching a configured
--- filetype, the LSP client is already running and the FileType-autostart path
--- short-circuits to a plain buf_attach_client.
---@param project_config table
function M.prewarm_lsps(user, host, port, project_config)
    if not project_config or type(project_config.lsp) ~= "table" then return end
    if type(project_config.root) ~= "string" then return end
    for server_name, server_cfg in pairs(project_config.lsp) do
        local cmd_args = M.server_cmd(server_name, server_cfg)
        -- Schedule each server independently. Daemon RPC is single-threaded so
        -- they end up serialized anyway, but this keeps the trigger non-blocking.
        vim.schedule(function()
            ensure_lsp_client(user, host, port, project_config.root, server_name, cmd_args, server_cfg.settings)
        end)
    end
end

--- FileType autostart: start (or attach) every project LSP whose `filetypes`
--- include `ft` for a zero:// buffer. 客户端命名统一走 client_name(<config key>)，
--- 并发启动锁只在 ensure_lsp_client 里一把。
---@param buf integer
---@param ft string
function M.autostart(buf, ft)
    local user, host, port, path = uri.parse(vim.api.nvim_buf_get_name(buf))
    if not user then return end
    local _, project_config = manager.match_project(host, path, user, port)
    if not project_config or type(project_config.lsp) ~= "table" then return end

    for server_name, server_cfg in pairs(project_config.lsp) do
        local lsp_name = client_name(server_name)
        if not server_cfg.filetypes then
            log.warn(string.format("LSP %s is configured but missing 'filetypes' array, skipping auto-start", server_name))
        elseif vim.tbl_contains(server_cfg.filetypes, ft)
            and #vim.lsp.get_clients({ bufnr = buf, name = lsp_name }) == 0 then
            log.debug(string.format("auto-starting LSP %s for buffer %d", lsp_name, buf))
            -- Schedule so we don't block FileType processing
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(buf) then
                    M.start_lsp(buf, M.server_cmd(server_name, server_cfg), nil, {
                        project_config = project_config,
                        root_dir = project_config.root,
                        server_key = server_name,
                    })
                end
            end)
        end
    end
end

--- Attach running zero-* LSP clients that cover `buf`'s remote path.
---
--- Per server name we attach AT MOST ONE client: the most-specific (longest
--- covering root_dir). If a client of the same name is already attached, we
--- skip. Attaching every covering client would, on overlapping configs (e.g.
--- one prewarm + one manual :ZeroLspStart for a sub-tree), leave the buffer
--- with two zero-<server> clients and produce duplicate locations.
---
--- Same-host fallback: rust-analyzer / pyright / gopls 都把自己的依赖
--- （~/.cargo/...、site-packages、$GOPATH/pkg/mod）加载到内部 vfs，但这些路径
--- 在文件系统上不在 project root 之下。如果同一台远程上正好有同名 server 在跑，
--- 就拿它兜底；多个时取与目标路径公共目录组件最多的（"最近的项目"）。
---@param buf integer
function M.attach_matching(buf)
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then return end
    local u, h, p, fpath = uri.parse(vim.api.nvim_buf_get_name(buf))
    if not u or fpath:match("/$") then return end
    local best_by_name = client_select.select_attach_clients_for_path(
        vim.lsp.get_clients(), uri.target_key(u, h, p), fpath)
    for cname, client in pairs(best_by_name) do
        if #vim.lsp.get_clients({ bufnr = buf, name = cname }) == 0 then
            log.debug(string.format("auto-attaching LSP %s to buffer %d", cname, buf))
            pcall(vim.lsp.buf_attach_client, buf, client.id)
        end
    end
end

--- Stop zero-* clients (intentional: no auto-restart). Stopping the Neovim
--- client closes the TCP socket, which ends the daemon's ssh subprocess.
---@param arg? string "pyright" / "zero-pyright"; nil/"" = all zero-* on bufnr
---@param bufnr? integer defaults to current buffer
---@return table[] clients the stopped clients
function M.stop(arg, bufnr)
    local clients
    if arg and arg ~= "" then
        clients = vim.lsp.get_clients({ name = arg:match("^zero%-") and arg or client_name(arg) })
    else
        clients = vim.tbl_filter(function(c) return c.name:match("^zero%-") ~= nil end,
            vim.lsp.get_clients({ bufnr = bufnr or vim.api.nvim_get_current_buf() }))
    end
    for _, client in ipairs(clients) do
        restart.mark_intentional_stop(client.id)
        client.stop()
    end
    return clients
end

return M
