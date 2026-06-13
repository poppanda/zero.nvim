local M = {}
local zero = require("zero-nvim")
local manager = require("zero-nvim.project.manager")
local client_select = require("zero-nvim.lsp.client_select")
local restart = require("zero-nvim.lsp.restart")

-- In-flight start lock keyed by "lsp_name:root_dir". Prevents racing starts
-- when prewarm and FileType-autostart both fire for the same root.
local starting = {}

-- LSP restart bookkeeping is centralized in lsp.restart. Keep the restart
-- callbacks here for now because they depend on ensure_lsp_client.

-- 前向声明 — restart_from_entry 是 ensure_lsp_client 内部闭包，需要在那里引用
-- 模块层的 schedule_revive；schedule_revive 又需要调用 ensure_lsp_client，
-- 而 ensure_lsp_client 自己也是 module-local，所以三者循环引用，靠 forward-decl 解开。
local schedule_revive
local ensure_lsp_client

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
    return msg:find("read_error", 1, true)
        or msg:find("write_error", 1, true)
        or msg:find("econnreset", 1, true)
        or msg:find("epipe", 1, true)
        or msg:find("connection reset", 1, true)
        or msg:find("closed", 1, true)
        or msg:find("eof", 1, true)
end

local function attached_buffers(client_id)
    local attached = {}
    local client = vim.lsp.get_client_by_id(client_id)
    if client and client.attached_buffers then
        for b, _ in pairs(client.attached_buffers) do
            if vim.api.nvim_buf_is_valid(b) then
                table.insert(attached, b)
            end
        end
    end
    return attached
end

local function stop_duplicate_clients(lsp_name, root_dir, keep_id, tkey)
    for _, client in ipairs(vim.lsp.get_clients({ name = lsp_name })) do
        if client.id ~= keep_id and client.config
            and (not tkey or client.config._zero_target == tkey)
            and client.config.root_dir == root_dir then
            restart.mark_stale_exit(client.id)
            if client.stop then
                pcall(client.stop, true)
            end
        end
    end
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

local function preflight_lsp(user, host, port, cmd_args)
    if type(cmd_args) ~= "table" or #cmd_args == 0 then
        return false, "Missing LSP command"
    end

    local chan, err = zero.ensure_connection(user, host, port)
    if not chan then
        return false, "Daemon not connected: " .. tostring(err)
    end

    if zero.uses_password_auth and zero.uses_password_auth(user, host, port) then
        return false,
            "Remote LSP requires SSH key/agent auth; current connection used password auth, but the LSP transport runs through non-interactive system ssh"
    end

    local ok, res = pcall(vim.fn.rpcrequest, chan, "lsp_probe", user, host, port, cmd_args)
    if not ok then
        return false, "LSP preflight RPC failed: " .. tostring(res)
    end
    if type(res) == "table" and res.ok == true then
        return true, nil, chan
    end

    local msg = type(res) == "table" and (res.message or res.error) or tostring(res)
    if msg == nil or msg == "" then
        msg = "system ssh BatchMode probe failed or LSP binary was not found"
    end
    return false, "LSP preflight failed: " .. msg
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
---@param opts? { force_new?: boolean }
---@return integer? client_id
---@return string? err
ensure_lsp_client = function(user, host, port, root_dir, server_name, cmd_args, settings, opts)
    opts = opts or {}
    root_dir = client_select.norm_root(root_dir)
    local lsp_name = "zero-" .. server_name
    local tkey = client_select.target_key(user, host, port)
    local lock_key = lsp_name .. "@" .. tkey .. ":" .. root_dir

    -- Reuse an active client on the SAME remote whose root_dir already covers
    -- root_dir (exact match preferred; otherwise the most-specific ancestor).
    -- 不区分主机或允许仅子路径独立启动，会让 locations_to_items 的 auto-attach
    -- 把同一目标文件同时挂上多个 zero-<server> client，下次跳转就出现重复项。
    -- 排除已经在 stopping 中的客户端，避免自动重启路径里捡到正在退出的旧 client。
    if not opts.force_new then
        local best = client_select.select_reusable_client(
            vim.lsp.get_clients({ name = lsp_name }),
            lsp_name,
            tkey,
            root_dir
        )
        if best then return best.id end
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

    local preflight_ok, preflight_err, chan = preflight_lsp(user, host, port, cmd_args)
    if not preflight_ok then
        clear_lock()
        return nil, preflight_err
    end

    settings = maybe_inject_python_path(chan, user, host, port, server_name, settings)

    local client_prefix = string.format("zero://%s@%s:%d", user, host, port)
    local ok, local_port = pcall(vim.fn.rpcrequest, chan, "lsp_start", user, host, port, cmd_args, client_prefix)
    if not ok or type(local_port) ~= "number" then
        clear_lock()
        return nil, "Failed to start LSP proxy: " .. tostring(local_port)
    end

    vim.notify("ZeroNvim: LSP Proxy started on port " .. local_port .. " for " .. server_name, vim.log.levels.DEBUG)

    local function restart_from_entry(client_id_arg, entry, attached, reason)
        restart.remove_active(client_id_arg)

        if not entry then
            restart.consume_intentional_stop(client_id_arg)
            return
        end

        if restart.consume_intentional_stop(client_id_arg) then
            return
        end

        if entry.attempts >= restart.MAX_RESTART_ATTEMPTS then
            -- 快速重启上限到了 → 改走慢速指数退避。覆盖长期断网/笔记本休眠：
            -- 用户从外面回来 ~30min 之内任意时刻都能自愈，而不是死掉等手动救。
            vim.schedule(function()
                vim.notify(string.format(
                    "ZeroNvim: LSP '%s' 已快速重启 %d 次仍失败，转入退避重试",
                    lsp_name, entry.attempts), vim.log.levels.WARN)
            end)
            entry.attempts = 0  -- 重置：退避循环用自己的尝试计数
            schedule_revive(entry, attached, 0)
            return
        end

        entry.attempts = entry.attempts + 1
        local delay = 500 * entry.attempts
        vim.defer_fn(function()
            vim.notify(string.format(
                "ZeroNvim: LSP '%s' %s，自动重启 (第 %d 次)...",
                lsp_name, reason, entry.attempts), vim.log.levels.INFO)
            local new_id, err2 = ensure_lsp_client(
                entry.user, entry.host, entry.port,
                entry.root_dir, entry.server_name,
                entry.cmd_args, entry.settings,
                { force_new = true }
            )
            if new_id then
                stop_duplicate_clients(lsp_name, entry.root_dir, new_id,
                    client_select.target_key(entry.user, entry.host, entry.port))
                local new_entry = restart.entry(new_id)
                if new_entry then
                    new_entry.attempts = entry.attempts
                end
                for _, b in ipairs(attached or {}) do
                    if vim.api.nvim_buf_is_valid(b) then
                        pcall(vim.lsp.buf_attach_client, b, new_id)
                    end
                end
                if #(attached or {}) > 0 then
                    vim.notify(string.format(
                        "ZeroNvim: LSP '%s' 已恢复，重新附着 %d 个 buffer",
                        lsp_name, #attached), vim.log.levels.INFO)
                end
            else
                -- ensure_lsp_client 返回 nil 多半是 daemon RPC 失败（网络断了 /
                -- ssh 连不上）。继续走快速循环也是徒劳，直接转入慢速退避。
                vim.notify(string.format(
                    "ZeroNvim: LSP '%s' 重启失败 (%s)，转入退避重试",
                    lsp_name, tostring(err2)), vim.log.levels.WARN)
                schedule_revive(entry, attached, 0)
            end
        end, delay)
    end

    local client_id
    client_id = vim.lsp.start_client({
        name = lsp_name,
        cmd = vim.lsp.rpc.connect('127.0.0.1', local_port),
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
            if client then
                restart.reset_attempts(client.id)
            end
        end,
        on_exit = function(code, signal, client_id_arg)
            clear_lock()
            local entry = restart.entry(client_id_arg)
            local attached = attached_buffers(client_id_arg)
            local action = restart.resolve_exit(client_id_arg, entry, attached, code)

            if action.kind == "ignore" then
                return
            end

            if action.kind == "notify_exit" then
                vim.schedule(function()
                    local level = action.level == "warn" and vim.log.levels.WARN or vim.log.levels.INFO
                    vim.notify(string.format(
                        "ZeroNvim: LSP '%s' exited (code=%s, signal=%s)",
                        lsp_name, tostring(code), tostring(signal)), level)
                end)
                return
            end

            if action.kind == "restart" then
                -- resolve_exit deliberately restarts registered clients even on
                -- code=0: idle SSH disconnects can look like clean EOF locally.
                restart_from_entry(client_id_arg, action.entry, action.attached, action.reason)
            end
        end,
        on_error = function(code, err2)
            if is_transport_error(code, err2) and client_id then
                local entry = restart.entry(client_id)
                if restart.queue_transport_restart(client_id, entry, attached_buffers(client_id), "连接断开") then
                    local client = vim.lsp.get_client_by_id(client_id)
                    if client and client.stop then
                        pcall(client.stop, true)
                    end
                    vim.defer_fn(function()
                        local action = restart.resolve_transport_fallback(client_id)
                        if action.kind == "restart" then
                            restart_from_entry(client_id, action.entry, action.attached, action.reason)
                        end
                    end, 3000)
                    return
                end
            end
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

function M.mark_intentional_stop(client_id)
    restart.mark_intentional_stop(client_id)
end

function M.preflight(user, host, port, cmd_args)
    local ok, err = preflight_lsp(user, host, port, cmd_args)
    return ok, err
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
            local _tkey = client_select.target_key(user, host, port)
            local function try_attach()
                if not vim.api.nvim_buf_is_valid(_bufnr) then return true end
                for _, client in ipairs(vim.lsp.get_clients({ name = lsp_name })) do
                    if client.config
                        and client.config.root_dir == _root
                        and client.config._zero_target == _tkey then
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

-- ───── 长期断网后的慢速重连 ────────────────────────────────────────────────
-- 设计点：
--   • 上限：started_at 起累计 MAX_DORMANT_SECS 后彻底休眠 — 防止长期挂着
--     空发 RPC。`:ZeroLspRestart` 会清掉 started_at，相当于重新开始计时。
--   • 取消语义：revive_dormant_now 把 dormant entry 清掉先于重排，
--     保证旧 timer 即便已经进入回调也能在头部检查时早返回。

local function do_revive_attempt(entry, attached, prior_attempts)
    local lsp_name = "zero-" .. entry.server_name
    local new_id = ensure_lsp_client(
        entry.user, entry.host, entry.port,
        entry.root_dir, entry.server_name,
        entry.cmd_args, entry.settings,
        { force_new = true }
    )
    if new_id then
        local key = restart.dormant_key_for(entry)
        restart.clear_dormant(key)
        stop_duplicate_clients(lsp_name, entry.root_dir, new_id,
            client_select.target_key(entry.user, entry.host, entry.port))
        for _, b in ipairs(attached or {}) do
            if vim.api.nvim_buf_is_valid(b) then
                pcall(vim.lsp.buf_attach_client, b, new_id)
            end
        end
        vim.schedule(function()
            vim.notify(string.format(
                "ZeroNvim: LSP '%s' 已恢复 (退避第 %d 次)",
                lsp_name, prior_attempts + 1), vim.log.levels.INFO)
        end)
    else
        schedule_revive(entry, attached, prior_attempts)
    end
end

schedule_revive = function(entry, attached, prior_attempts)
    local key = restart.dormant_key_for(entry)
    local existing = restart.get_dormant(key)
    if existing then restart.cancel_timer(existing.timer) end

    local started_at = (existing and existing.started_at) or os.time()
    local elapsed = os.time() - started_at
    if elapsed >= restart.MAX_DORMANT_SECS then
        restart.clear_dormant(key)
        vim.schedule(function()
            vim.notify(string.format(
                "ZeroNvim: LSP 'zero-%s' 已重试 %d 分钟仍未恢复，进入休眠。`:ZeroLspRestart` 可手动唤起。",
                entry.server_name, math.floor(elapsed / 60)), vim.log.levels.ERROR)
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
            vim.notify(string.format(
                "ZeroNvim: LSP 'zero-%s' 进入退避重连 (%d-60s 间隔，最多 %d 分钟)",
                entry.server_name, restart.BACKOFF_SECS[1], math.floor(restart.MAX_DORMANT_SECS / 60)),
                vim.log.levels.INFO)
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
    local snapshot = restart.dormant_keys()
    for _, key in ipairs(snapshot) do
        local d = restart.get_dormant(key)
        if d then
            local entry, attached = d.entry, d.attached
            -- 清掉 dormant entry，让 old timer 的回调如果跑到了能在头部早返回，
            -- 也让 schedule_revive 把 started_at 当作 now 重新计时（用户回来 →
            -- 30min 时窗刷新）。
            restart.clear_dormant(key)
            vim.defer_fn(function() do_revive_attempt(entry, attached, 0) end, 50)
            count = count + 1
        end
    end
    return count
end

---@return integer count
function M.dormant_count()
    return restart.dormant_count()
end

return M
