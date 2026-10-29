--- 远端 LSP：经 daemon 的 TCP proxy 启动 zero-<key> client，负责自动启动 /
--- 附着 / 停止 / 自动重启与长期断网后的退避重连。
local remote = require("zero-nvim.remote")
local uri = require("zero-nvim.uri")
local log = require("zero-nvim.log")
local util = require("zero-nvim.util")
local manager = require("zero-nvim.project.manager")
local client_select = require("zero-nvim.lsp.client_select")
local restart = require("zero-nvim.lsp.restart")

local M = {}

-- In-flight start lock keyed by client_key. Prevents racing starts
-- when prewarm and FileType-autostart both fire for the same root.
local starting = {}
local lsp_probe_unsupported_warned = false

M.client_name = client_select.client_name
--- 一个 (server, remote, root) 的唯一 key（启动锁 / dormant 表共用）。
M.client_key = client_select.client_key

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
function M.resolve_server_key(project_config, name)
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

--- Command-line completion: mason bins of the current buffer's remote.
---@param arg_lead string
---@return string[]
function M.complete_mason_bins(arg_lead)
    local out = {}
    for _, name in ipairs(M.mason_bins(uri.parse(vim.api.nvim_buf_get_name(0)))) do
        if name:find(arg_lead, 1, true) == 1 then table.insert(out, name) end
    end
    return out
end

-- ───── 内部工具 ─────────────────────────────────────────────────────────────

local TRANSPORT_ERROR_PATTERNS = { "read_error", "write_error", "econnreset", "epipe", "connection reset", "closed", "eof" }

local function is_transport_error(code, err)
    -- Prefer the symbolic name. err text varies wildly across transports
    -- (TCP socket vs ssh subprocess vs LSP proxy) and is unreliable for
    -- string matching alone — Neovim normalises the rpc-layer cause via
    -- vim.lsp.client_errors.
    if type(code) == "number" and vim.lsp.client_errors then
        local name = vim.lsp.client_errors[code]
        if name == "READ_ERROR" or name == "WRITE_ERROR"
            or name == "SERVER_REQUEST_HANDLER_ERROR"
            or name == "NOTIFICATION_HANDLER_ERROR" then
            return true
        end
    end
    local msg = (tostring(code or "") .. " " .. tostring(err or "")):lower()
    for _, pat in ipairs(TRANSPORT_ERROR_PATTERNS) do
        if msg:find(pat, 1, true) then return true end
    end
    return false
end

local function attached_buffers(client_id)
    local attached = {}
    local client = vim.lsp.get_client_by_id(client_id)
    for b in pairs(client and client.attached_buffers or {}) do
        if vim.api.nvim_buf_is_valid(b) then table.insert(attached, b) end
    end
    return attached
end

--- Attach `client_id` to `buf` unless already attached.
---@return boolean attached_now
local function attach(buf, client_id)
    if not vim.api.nvim_buf_is_valid(buf) then return false end
    if #vim.lsp.get_clients({ bufnr = buf, id = client_id }) > 0 then return false end
    return (pcall(vim.lsp.buf_attach_client, buf, client_id))
end

--- 重启 / 退避恢复成功后：停掉同 (server, remote, root) 的旧 client，并把
--- 原来附着的 buffer 挂到新 client 上。
---@return integer count reattached buffers
local function adopt_replacement(entry, new_id, attached)
    local tkey = uri.target_key(entry.user, entry.host, entry.port)
    for _, client in ipairs(vim.lsp.get_clients({ name = M.client_name(entry.server_name) })) do
        if client.id ~= new_id and client.config
            and client.config._zero_target == tkey
            and client.config.root_dir == entry.root_dir then
            restart.mark_stale_exit(client.id)
            pcall(client.stop, true)
        end
    end
    local count = 0
    for _, b in ipairs(attached or {}) do
        if vim.api.nvim_buf_is_valid(b) then
            pcall(vim.lsp.buf_attach_client, b, new_id)
            count = count + 1
        end
    end
    return count
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

-- ───── 启动 / 自动重启 / 退避重连 ───────────────────────────────────────────
-- ensure_lsp_client → on_exit → restart_from_entry → ensure_lsp_client /
-- schedule_revive 互相递归，靠这两个前向声明解开。
local ensure_lsp_client, schedule_revive

local function restart_with_entry(entry)
    return ensure_lsp_client(entry.user, entry.host, entry.port, entry.root_dir,
        entry.server_name, entry.cmd_args, entry.settings, { force_new = true })
end

--- 快速重启：最多 MAX_RESTART_ATTEMPTS 次（间隔递增），之后转入慢速退避。
local function restart_from_entry(client_id, entry, attached, reason)
    restart.remove_active(client_id)
    -- 用户主动停的 / 无 entry：只消费标记，不重启
    if restart.consume_intentional_stop(client_id) or not entry then return end

    local lsp_name = M.client_name(entry.server_name)
    if entry.attempts >= restart.MAX_RESTART_ATTEMPTS then
        -- 快速重启上限到了 → 改走慢速指数退避。覆盖长期断网/笔记本休眠：
        -- 用户从外面回来 ~30min 之内任意时刻都能自愈，而不是死掉等手动救。
        vim.schedule(function()
            log.warn(string.format("LSP '%s' 已快速重启 %d 次仍失败，转入退避重试", lsp_name, entry.attempts))
        end)
        entry.attempts = 0 -- 重置：退避循环用自己的尝试计数
        schedule_revive(entry, attached, 0)
        return
    end

    entry.attempts = entry.attempts + 1
    vim.defer_fn(function()
        log.info(string.format("LSP '%s' %s，自动重启 (第 %d 次)...", lsp_name, reason, entry.attempts))
        local new_id, err = restart_with_entry(entry)
        if not new_id then
            -- 返回 nil 多半是 daemon RPC 失败（网络断了 / ssh 连不上）。
            -- 继续走快速循环也是徒劳，直接转入慢速退避。
            log.warn(string.format("LSP '%s' 重启失败 (%s)，转入退避重试", lsp_name, tostring(err)))
            schedule_revive(entry, attached, 0)
            return
        end
        local new_entry = restart.entry(new_id)
        if new_entry then new_entry.attempts = entry.attempts end
        local n = adopt_replacement(entry, new_id, attached)
        if n > 0 then
            log.info(string.format("LSP '%s' 已恢复，重新附着 %d 个 buffer", lsp_name, n))
        end
    end, 500 * entry.attempts)
end

--- Start a remote LSP client for `root_dir`, or return the existing one's id.
--- Buffer-less by design: prewarm and FileType-autostart both go through here.
---@param opts? { force_new?: boolean }
---@return integer? client_id
---@return string? err "STARTING" when another start is in flight
ensure_lsp_client = function(user, host, port, root_dir, server_name, cmd_args, settings, opts)
    root_dir = client_select.norm_root(root_dir)
    local lsp_name = M.client_name(server_name)
    local tkey = uri.target_key(user, host, port)
    local lock_key = M.client_key(server_name, user, host, port, root_dir)

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
            local action = restart.resolve_exit(id, restart.entry(id), attached_buffers(id), code)
            if action.kind == "notify_exit" then
                vim.schedule(function()
                    log.notify(string.format("LSP '%s' exited (code=%s, signal=%s)",
                            lsp_name, tostring(code), tostring(signal)),
                        action.level == "warn" and vim.log.levels.WARN or vim.log.levels.INFO)
                end)
            elseif action.kind == "restart" then
                -- resolve_exit deliberately restarts registered clients even on
                -- code=0: idle SSH disconnects can look like clean EOF locally.
                restart_from_entry(id, action.entry, action.attached, action.reason)
            end
        end,
        on_error = function(code, err)
            if client_id and is_transport_error(code, err)
                and restart.queue_transport_restart(client_id, restart.entry(client_id),
                    attached_buffers(client_id), "连接断开") then
                local client = vim.lsp.get_client_by_id(client_id)
                if client then pcall(client.stop, true) end
                -- on_exit 正常会消费 pending；3s 内没等到 exit 就自己重启
                vim.defer_fn(function()
                    local action = restart.resolve_transport_fallback(client_id)
                    if action.kind == "restart" then
                        restart_from_entry(client_id, action.entry, action.attached, action.reason)
                    end
                end, 3000)
                return
            end
            vim.schedule(function()
                log.error(string.format("LSP '%s' error (code=%s): %s", lsp_name, tostring(code), tostring(err)))
            end)
        end,
    })

    if not client_id then
        clear_lock()
        return nil, "vim.lsp.start_client returned nil"
    end

    -- Register restart metadata; on_exit uses it to restart and on_init resets
    -- attempts. Each automatic restart increments attempts until the limit.
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

-- ───── 长期断网后的慢速重连 ────────────────────────────────────────────────
-- 设计点：
--   • 上限：started_at 起累计 MAX_DORMANT_SECS 后彻底休眠 — 防止长期挂着
--     空发 RPC。`:ZeroLspRestart` 会清掉 started_at，相当于重新开始计时。
--   • 取消语义：revive_dormant_now 把 dormant entry 清掉先于重排，
--     保证旧 timer 即便已经进入回调也能在头部检查时早返回。

local function do_revive_attempt(entry, attached, prior_attempts)
    local new_id = restart_with_entry(entry)
    if not new_id then
        schedule_revive(entry, attached, prior_attempts)
        return
    end
    restart.clear_dormant(restart.dormant_key_for(entry))
    adopt_replacement(entry, new_id, attached)
    vim.schedule(function()
        log.info(string.format("LSP '%s' 已恢复 (退避第 %d 次)", M.client_name(entry.server_name), prior_attempts + 1))
    end)
end

schedule_revive = function(entry, attached, prior_attempts)
    local key = restart.dormant_key_for(entry)
    local existing = restart.get_dormant(key)
    if existing then util.close_timer(existing.timer) end

    local started_at = (existing and existing.started_at) or os.time()
    local elapsed = os.time() - started_at
    if elapsed >= restart.MAX_DORMANT_SECS then
        restart.clear_dormant(key)
        vim.schedule(function()
            log.error(string.format(
                "LSP 'zero-%s' 已重试 %d 分钟仍未恢复，进入休眠。`:ZeroLspRestart` 可手动唤起。",
                entry.server_name, math.floor(elapsed / 60)))
        end)
        return
    end

    local attempts = (prior_attempts or 0) + 1
    local delay_ms = restart.BACKOFF_SECS[math.min(attempts, #restart.BACKOFF_SECS)] * 1000
    local timer = vim.defer_fn(function()
        local d = restart.get_dormant(key)
        if not d then return end -- canceled by revive_dormant_now or success elsewhere
        d.timer = nil
        do_revive_attempt(entry, d.attached, attempts)
    end, delay_ms)

    restart.set_dormant(key, {
        entry = entry,
        attached = attached,
        attempts = attempts,
        started_at = started_at,
        timer = timer,
    })

    -- 进入退避时打一条 INFO，避免静默重试。
    if prior_attempts == 0 then
        vim.schedule(function()
            log.info(string.format("LSP 'zero-%s' 进入退避重连 (%d-60s 间隔，最多 %d 分钟)",
                entry.server_name, restart.BACKOFF_SECS[1], math.floor(restart.MAX_DORMANT_SECS / 60)))
        end)
    end
end

--- Cancel pending backoff timers and fire all dormant retries immediately.
--- Hook to VimResume / FocusGained / :ZeroLspRestart — when the user comes
--- back to a suspended laptop, network is usually up by the time the autocmd
--- fires, so we shouldn't wait out the backoff.
---@return integer count number of dormant entries revived
function M.revive_dormant_now()
    local count = 0
    for _, key in ipairs(restart.dormant_keys()) do
        local d = restart.get_dormant(key)
        if d then
            -- 清掉 dormant entry，让 old timer 的回调如果跑到了能在头部早返回，
            -- 也让 schedule_revive 把 started_at 当作 now 重新计时（用户回来 →
            -- 30min 时窗刷新）。
            restart.clear_dormant(key)
            vim.defer_fn(function() do_revive_attempt(d.entry, d.attached, 0) end, 50)
            count = count + 1
        end
    end
    return count
end

---@return integer count
function M.dormant_count()
    return restart.dormant_count()
end

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
    local server_name = opts.server_key or M.resolve_server_key(project_config, cmd_args[1])

    local root_dir = opts.root_dir
    if not root_dir then
        if project_config and type(project_config.root) == "string" then
            root_dir = client_select.norm_root(project_config.root)
        else
            root_dir = client_select.norm_root(path:sub(-1) == "/" and path or vim.fs.dirname(path))
        end
        if root_dir == "" then root_dir = "/" end
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

    local lsp_name = M.client_name(server_name)
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
    local root_dir = client_select.norm_root(project_config.root)

    for server_name, server_cfg in pairs(project_config.lsp) do
        local cmd_args = M.server_cmd(server_name, server_cfg)
        -- Schedule each server independently. Daemon RPC is single-threaded so
        -- they end up serialized anyway, but this keeps the trigger non-blocking.
        vim.schedule(function()
            ensure_lsp_client(user, host, port, root_dir, server_name, cmd_args, server_cfg.settings)
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
        local lsp_name = M.client_name(server_name)
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
                        root_dir = client_select.norm_root(project_config.root),
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
        clients = vim.lsp.get_clients({ name = arg:match("^zero%-") and arg or M.client_name(arg) })
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
