local M = {}

-- 默认配置
local defaults = {
    daemon = {
        path = nil,
        build_type = "debug",
    },
    log = {
        level = vim.log.levels.INFO,
        prefix = "ZeroNvim: ",
    },
    explorer = "builtin",
    gitsigns = {
        -- 远端没有 .git/HEAD 文件监听，靠事件 + 可选轮询代偿。详见
        -- lua/zero-nvim/gitsigns/refresh.lua 头部注释。
        refresh = {
            debounce_ms = 300, -- 事件触发的 debounce + in-flight 释放节奏
            poll_ms = 0,       -- 0 = 关闭轮询；> 0 时每 poll_ms 检查一次
        },
    },
}

-- 插件内部状态
local state = {
    channel_id = nil,
    connected_hosts = {},
    scanned_projects = {},
    mason_bins = {}, -- key: "user@host:port" -> list of mason bin names
    python_paths = {}, -- key: "user@host:port" -> resolved python interpreter path
    remote_homes = {}, -- key: "user@host:port" -> remote $HOME (resolved on first probe)
    password_hosts = {}, -- key: "user@host:port" -> true when initial auth used password
    connect_failures = {}, -- key: "user@host:port" -> { at = ms, err = string } (negative cache)
    leaving = false, -- VimLeavePre 之后 daemon 退出属于正常流程，不再报错
}

-- 连接失败的负缓存时长：不可达主机在这段时间内不会被反复阻塞式重连。
local CONNECT_FAILURE_TTL_MS = 10000

-- 批量预取的文件内容，key 为规范化 URI。BufReadCmd / oil read_file 读取时
-- 优先消费这里的内容（一次性），避免 LSP 跳转时每个文件再单独 fetch 一次。
local prefetched = {}

-- Defaults are applied lazily so that functions called before setup() (tests,
-- other modules requiring us early) still see a usable config.
local options = vim.deepcopy(defaults)
local patches = {}

local function logger(msg, level)
    level = level or vim.log.levels.INFO
    if level >= options.log.level then
        vim.notify(options.log.prefix .. msg, level)
    end
end

local uri_helpers = require("zero-nvim.uri")
local buffer_io = require("zero-nvim.buffer_io")
local client_select = require("zero-nvim.lsp.client_select")

local uv = vim.uv or vim.loop

local function target_key(user, host, port)
    return uri_helpers.target_key(user, host, port)
end

function M.parse_uri(uri)
    return uri_helpers.parse(uri)
end

--- Find a buffer by its exact name (vim.fn.bufnr() does pattern matching,
--- which misfires on names containing wildcards or a "zero://" prefix).
---@param name string
---@return integer?
local function find_buf(name)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b) == name then return b end
    end
    return nil
end

--- Plugin install root, derived from this file's own path. The daemon binary
--- is only ever resolved relative to it (never relative to cwd: running a
--- binary from whatever project the user happens to be in is unsafe).
local function plugin_root()
    local src = debug.getinfo(1, "S").source
    if type(src) ~= "string" or src:sub(1, 1) ~= "@" then return nil end
    local script_path = vim.fn.fnamemodify(src:sub(2), ":p")
    -- <root>/lua/zero-nvim/init.lua
    return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script_path)))
end

local function get_daemon_bin()
    if options.daemon.path and vim.fn.executable(options.daemon.path) == 1 then
        return options.daemon.path
    end
    local root = plugin_root()
    if not root then return nil end
    local detected_path = string.format("%s/daemon/target/%s/zero-nvim-daemon", root, options.daemon.build_type)
    if vim.fn.executable(detected_path) == 1 then return detected_path end
    return nil
end

local function reset_connection_state()
    state.connected_hosts = {}
    state.scanned_projects = {}
    state.mason_bins = {}
    state.python_paths = {}
    state.remote_homes = {}
    state.password_hosts = {}
    state.connect_failures = {}
end

--- 通知所有进行中的 stream session：daemon 没了，不会再有 exit 事件回来。
local function abort_streams(reason)
    pcall(function()
        local exec = require("zero-nvim.cmd.exec")
        if type(exec.abort_all) == "function" then
            exec.abort_all(reason)
        end
    end)
end

local function get_daemon_chan()
    if state.channel_id then return state.channel_id end
    local bin_path = get_daemon_bin()
    if not bin_path then
        logger("Daemon binary not found. Build it with `make build` (or set daemon.path).", vim.log.levels.ERROR)
        return nil
    end
    local job
    job = vim.fn.jobstart({ bin_path }, {
        rpc = true,
        on_exit = function(_, code)
            -- 旧 daemon 的迟到 on_exit 不能清掉新 daemon 的状态
            if state.channel_id ~= job then return end
            state.channel_id = nil
            reset_connection_state()
            abort_streams(string.format("daemon exited (code=%s)", tostring(code)))
            local exiting = vim.v.exiting ~= nil and vim.v.exiting ~= vim.NIL
            if not state.leaving and not exiting then
                vim.schedule(function()
                    logger(string.format(
                        "Daemon exited unexpectedly (code=%s); it will be restarted on next use.",
                        tostring(code)), vim.log.levels.ERROR)
                end)
            end
        end,
        on_stderr = function(_, data)
            -- 调试模式：daemon stderr 同时 tee 到文件，方便 panic / SIGPIPE 死亡时
            -- 事后回看（vim.notify 历史可能被 :messages 截掉）。开关通过环境变量。
            local debug_log = os.getenv("ZERO_NVIM_DEBUG") and "/tmp/zero-daemon.log" or nil
            local f = debug_log and io.open(debug_log, "a") or nil
            for _, line in ipairs(data) do
                if line ~= "" then
                    logger("Daemon: " .. line, vim.log.levels.WARN)
                    if f then f:write(os.date("%H:%M:%S ") .. line .. "\n") end
                end
            end
            if f then f:close() end
        end,
    })
    -- jobstart: 0 = 参数非法，-1 = 不可执行；都不能当作有效 channel 缓存
    if type(job) ~= "number" or job <= 0 then
        logger(string.format("Failed to start daemon %s (jobstart returned %s)", bin_path, tostring(job)),
            vim.log.levels.ERROR)
        return nil
    end
    state.channel_id = job
    return job
end

--- 暴露 daemon channel 给其他模块（如 ssh_config.lua）使用
--- 仅在 daemon 已启动时返回 channel_id，不会自动启动 daemon
function M._get_daemon_chan()
    return state.channel_id
end

--- Daemon channel, starting the daemon on demand. Returns nil when the
--- binary cannot be found / started (an error has been logged).
---@return integer?
function M.get_daemon_chan()
    return get_daemon_chan()
end

function M.ensure_connection(user, host, port, password)
    local chan = get_daemon_chan()
    if not chan then return nil, "Daemon not running" end
    local key = target_key(user, host, port)

    if state.connected_hosts[key] then return chan end

    -- 负缓存：不可达主机 10s 内直接返回上次的错误，不再阻塞式重连。
    -- 带密码的调用（用户刚输入）总是绕过。
    if not password then
        local failure = state.connect_failures[key]
        if failure and (uv.now() - failure.at) < CONNECT_FAILURE_TTL_MS then
            return nil, failure.err
        end
    end

    local ok, res = pcall(vim.fn.rpcrequest, chan, "connect", user, host, port, password)
    if not ok then
        local err = tostring(res)
        state.connect_failures[key] = { at = uv.now(), err = err }
        return nil, err
    end
    state.connect_failures[key] = nil
    state.connected_hosts[key] = true
    if password then
        state.password_hosts[key] = true
    end
    return chan
end

local function do_request(interactive, user, host, port, method, ...)
    local chan, err = M.ensure_connection(user, host, port)
    if not chan and interactive and tostring(err):find("AUTH_FAILED", 1, true)
        and #vim.api.nvim_list_uis() > 0 then
        -- 典型场景：daemon 重启后密码认证的连接丢失。用户主动操作（保存等）时
        -- 同步询问一次密码，而不是直接失败。
        local ok_in, pw = pcall(vim.fn.inputsecret, string.format("SSH Password (%s@%s): ", user, host))
        if ok_in and type(pw) == "string" and pw ~= "" then
            chan, err = M.ensure_connection(user, host, port, pw)
        end
    end
    if not chan then return false, tostring(err or "not connected") end

    local ok, res = pcall(vim.fn.rpcrequest, chan, method, user, host, port, ...)
    if not ok and tostring(res):find("NOT_CONNECTED", 1, true) then
        -- daemon 侧会话丢了（daemon 重启 / 被回收）：重连一次后重试
        state.connected_hosts[target_key(user, host, port)] = nil
        chan, err = M.ensure_connection(user, host, port)
        if not chan then return false, tostring(err) end
        ok, res = pcall(vim.fn.rpcrequest, chan, method, user, host, port, ...)
    end
    if not ok then return false, tostring(res) end
    return true, res
end

--- Issue a per-connection RPC (`method(user, host, port, ...)`), making sure
--- the daemon is running and the host is connected; retries once after a
--- reconnect when the daemon answers NOT_CONNECTED.
---@return boolean ok
---@return any result_or_error
function M.request(user, host, port, method, ...)
    return do_request(false, user, host, port, method, ...)
end

--- Like M.request, but may prompt for an SSH password synchronously when the
--- host needs password auth (use only for user-initiated actions).
function M.request_interactive(user, host, port, method, ...)
    return do_request(true, user, host, port, method, ...)
end

function M.uses_password_auth(user, host, port)
    return state.password_hosts[target_key(user, host, port)] == true
end

--- Resolve and cache the remote user's $HOME. Used by anything that wants to
--- address a path relative to the user's home (mason bin scan etc.). Hard-
--- coding /home/<user> breaks on macOS (/Users/...), root (/root), and
--- containerized hosts where $HOME is non-standard.
---@return string?
function M.get_remote_home(user, host, port)
    local key = target_key(user, host, port)
    if state.remote_homes[key] then return state.remote_homes[key] end
    local ok, home = M.request(user, host, port, "exec_remote", 'printf %s "$HOME"')
    if not ok or type(home) ~= "string" or home == "" then return nil end
    state.remote_homes[key] = home
    return home
end

--- Scan <remote-home>/.local/share/nvim/mason/bin/ and cache the bin names.
--- Results are used as autocomplete suggestions for :ZeroLspStart.
--- 不再在连接建立时自动扫描（那会在主循环上多跑两次阻塞 RPC）；改为首次
--- 需要补全时懒扫描，结果（包括"没有 mason"）都会缓存。
function M.scan_mason_bins(user, host, port)
    local key = target_key(user, host, port)
    local home = M.get_remote_home(user, host, port)
    if not home then return end
    local mason_bin_path = home .. "/.local/share/nvim/mason/bin"
    local ok, entries = M.request(user, host, port, "read_dir", mason_bin_path)
    if not ok or type(entries) ~= "table" then
        -- Mason not installed on remote — fallback silently, autocomplete
        -- just won't show Mason bins.
        state.mason_bins[key] = {}
        return
    end
    local bins = {}
    for _, entry in ipairs(entries) do
        if entry.type == "file" then
            table.insert(bins, entry.name)
        end
    end
    state.mason_bins[key] = bins
end

--- Get cached mason bin completions.
--- When user/host/port are provided, returns the bins for that exact remote
--- (scanning lazily on first use if the host is connected).
--- When called with no args, returns the first cached host's bins (legacy
--- behaviour preserved for callers that lack buffer context).
---@param user? string
---@param host? string
---@param port? integer
---@return string[]
function M.get_mason_bins(user, host, port)
    if user and host and port then
        local key = target_key(user, host, port)
        if state.mason_bins[key] == nil and state.connected_hosts[key] then
            M.scan_mason_bins(user, host, port)
        end
        return state.mason_bins[key] or {}
    end
    for _, bins in pairs(state.mason_bins) do
        return bins
    end
    return {}
end

--- Cached remote python interpreter path keyed by user@host:port.
--- Populated by lsp.lua on first pyright probe and reused for subsequent starts.
function M.get_python_path(user, host, port)
    return state.python_paths[target_key(user, host, port)]
end

function M.set_python_path(user, host, port, path)
    state.python_paths[target_key(user, host, port)] = path
end

M._test_select_lsp_clients_for_path = client_select.select_attach_clients_for_path

function M.get_entries(user, host, port, path)
    local chan, err = M.ensure_connection(user, host, port)
    if not chan then return nil, err end
    local project_key = string.format("%s:%s", target_key(user, host, port), path)
    if not state.scanned_projects[project_key] then
        pcall(vim.rpcnotify, chan, "scan_project", user, host, port, path)
        state.scanned_projects[project_key] = true
    end
    local ok, entries = M.request(user, host, port, "read_dir", path)
    if not ok then return nil, entries end
    return entries
end

function M.get_file_content(user, host, port, path)
    local ok, content = M.request(user, host, port, "fetch_file", path)
    if not ok then return nil, content end
    return buffer_io.to_bytes(content)
end

--- Consume prefetched content for a canonical URI (one-shot).
---@param uri string
---@return string?
function M._take_prefetched(uri)
    local canon = uri_helpers.normalize(uri) or uri
    local content = prefetched[canon]
    prefetched[canon] = nil
    return content
end

---@param uri string
---@return boolean
function M._has_prefetched(uri)
    local canon = uri_helpers.normalize(uri) or uri
    return prefetched[canon] ~= nil
end

--- Rename `buf` to `new_name` without clobbering the window's alternate file,
--- then wipe the placeholder buffer `:file` leaves behind for the old name.
---@return boolean ok
local function rename_buffer(buf, new_name)
    local old_name = vim.api.nvim_buf_get_name(buf)
    if old_name == new_name then return true end
    local ok = pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("keepalt noautocmd file " .. vim.fn.fnameescape(new_name))
    end)
    if not ok then return false end
    vim.schedule(function()
        local old = find_buf(old_name)
        if old and old ~= buf and not vim.api.nvim_buf_is_loaded(old) and vim.fn.bufwinid(old) == -1 then
            pcall(vim.api.nvim_buf_delete, old, { force = true })
        end
    end)
    return true
end

--- `buf` is an alias (non-canonical name) of the already existing `target`
--- buffer: keep it empty/unwritable, move its windows to `target`, wipe it.
local function redirect_alias(buf, target)
    buffer_io.mark_failed(buf)
    vim.b[buf].zero_alias_of = target
    vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_valid(target) then return end
        for _, w in ipairs(vim.fn.win_findbuf(buf)) do
            pcall(vim.api.nvim_win_set_buf, w, target)
        end
        if vim.fn.bufwinid(buf) == -1 then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end)
end

local function setup_dir_buffer(buf, user, host, port, path, entries)
    local lines = { '" Remote Directory: ' .. path, '" Press <CR> to open, R to refresh, .. to go up', "" }
    local entry_map = {}
    table.insert(lines, " \239\132\149 ../")
    entry_map[#lines] = { name = "..", type = "directory" }
    table.sort(entries, function(a, b)
        if a.type ~= b.type then return a.type == "directory" end
        return a.name < b.name
    end)
    for _, entry in ipairs(entries) do
        local display = (entry.type == "directory" and " \239\132\149 " or " \239\133\155 ") .. entry.name
        if entry.type == "directory" then display = display .. "/" end
        table.insert(lines, display)
        entry_map[#lines] = entry
    end
    vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value('modified', false, { buf = buf })
    vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
    vim.api.nvim_set_option_value('readonly', true, { buf = buf })
    vim.api.nvim_set_option_value('filetype', 'netrw', { buf = buf })
    vim.b[buf].zero_is_dir = true
    vim.b[buf].zero_loaded = true
    vim.b[buf].zero_load_failed = nil
    vim.keymap.set('n', '<CR>', function()
        local line = vim.fn.line('.')
        local entry = entry_map[line]
        if not entry then return end
        local new_path
        if entry.name == ".." then
            new_path = uri_helpers.parent_dir(path)
        else
            new_path = uri_helpers.join(path, entry.name, entry.type == "directory")
        end
        vim.cmd("edit " .. vim.fn.fnameescape(uri_helpers.format(user, host, port, new_path)))
    end, { buffer = buf, silent = true })
    vim.keymap.set('n', 'R', function() M.handle_fetch(buf, user, host, port, path, nil, true) end,
        { buffer = buf, silent = true })
end

--- Filetype detection + BufReadPost for a freshly loaded file buffer.
local function post_read(buf, path)
    if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].zero_is_dir then return end
    -- Content-based detection covers shebangs / extension-less files.
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 5, false)
    local ft = vim.filetype.match({ filename = path, contents = lines })
    if ft and ft ~= "" and vim.bo[buf].filetype ~= ft then
        vim.bo[buf].filetype = ft
    end
    -- BufReadCmd replaces BufRead — downstream readers (gitsigns
    -- attach autocmd, etc.) need an explicit BufReadPost to wake up.
    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf, modeline = false })
end

--- Load remote `path` into `buf` synchronously.
--- On failure the buffer is left empty, non-modifiable and flagged
--- b:zero_load_failed so a later :w cannot truncate the remote file.
---@return boolean|"pending" result true = loaded, false = failed,
---        "pending" = waiting for an SSH password (loaded asynchronously)
function M.handle_fetch(buf, user, host, port, path, password, refresh)
    local res
    local content = M._take_prefetched(uri_helpers.format(user, host, port, path))
    if content ~= nil then
        res = { "file", content }
    else
        local chan, err = M.ensure_connection(user, host, port, password)
        if not chan then
            local err_str = type(err) == "string" and err or tostring(err or "unknown error")
            -- 只有明确包含 AUTH_FAILED 字样才弹窗
            if not password and err_str:match("AUTH_FAILED") then
                -- 拿到密码前 buffer 是空的：先标记为加载失败，防止误写回
                buffer_io.mark_failed(buf)
                vim.ui.input({ prompt = "SSH Password: ", secret = true }, function(input)
                    if input then
                        vim.schedule(function()
                            if not vim.api.nvim_buf_is_valid(buf) then return end
                            if M.handle_fetch(buf, user, host, port, path, input) == true then
                                post_read(buf, path)
                            end
                        end)
                    end
                end)
                return "pending"
            end
            -- 其他错误（如 Banner 失败，SFTP 不支持等）直接报错
            buffer_io.mark_failed(buf)
            logger("Connection failed: " .. err_str .. " (buffer is read-only; :e to retry)", vim.log.levels.ERROR)
            return false
        end

        local ok_fetch, fetch_res = M.request(user, host, port, "fetch_path", path)
        if not ok_fetch then
            if not path:match("/$") and buffer_io.is_missing_error(fetch_res) then
                -- 远端不存在 → 当作新文件（与 :e newfile 一致），允许写入创建
                buffer_io.apply(buf, "")
                vim.b[buf].zero_new_file = true
                logger("[New] " .. path, vim.log.levels.INFO)
                return true
            end
            buffer_io.mark_failed(buf)
            logger("Access failed: " .. tostring(fetch_res) .. " (buffer is read-only; :e to retry)",
                vim.log.levels.ERROR)
            return false
        end
        res = fetch_res
    end

    if type(res) ~= "table" then
        buffer_io.mark_failed(buf)
        logger("Access failed: unexpected daemon reply for " .. path, vim.log.levels.ERROR)
        return false
    end

    local ftype = res[1]
    if ftype == "directory" then
        -- 目录 buffer 名统一以 "/" 结尾，".." / 子目录拼接才不会出错
        local dir = uri_helpers.as_dir(path)
        if dir ~= path then
            local want = uri_helpers.format(user, host, port, dir)
            local existing = find_buf(want)
            if existing and existing ~= buf then
                redirect_alias(buf, existing)
                return false
            end
            rename_buffer(buf, want)
        end
        local entries, err = M.get_entries(user, host, port, dir)
        if not entries then
            buffer_io.mark_failed(buf)
            logger("Failed to list " .. dir .. ": " .. tostring(err), vim.log.levels.ERROR)
            return false
        end
        setup_dir_buffer(buf, user, host, port, dir, entries)
        return true
    elseif ftype == "file" then
        buffer_io.apply(buf, buffer_io.to_bytes(res[2]) or "")
        -- Do NOT set readonly=true: it causes W10 warnings whenever Neovim's
        -- internal buffer-loading machinery (bufload, BufRead events, fold
        -- operations) touches the buffer after our pre-fetch. Writes are
        -- handled exclusively via BufWriteCmd, so readonly is not needed.
        -- buflisted is set on BufWinEnter (when the user actually sees the
        -- buffer), not here: buffers loaded only to render a quickfix list
        -- must not show up as tabs in buffer-manager plugins.
        return true
    end

    buffer_io.mark_failed(buf)
    logger("Access failed: unknown path type for " .. path, vim.log.levels.ERROR)
    return false
end

--- Read handler for a zero:// buffer (BufReadCmd). Canonicalizes the buffer
--- name first so zero://u@h/p and zero://u@h:22/p share one buffer.
---@param buf integer
---@param name string
function M.read_buffer(buf, name)
    local canon = uri_helpers.normalize(name)
    if not canon then return end
    if canon ~= name then
        local existing = find_buf(canon)
        if existing and existing ~= buf then
            redirect_alias(buf, existing)
            return
        end
        rename_buffer(buf, canon)
    end
    local user, host, port, path = uri_helpers.parse(canon)
    -- Populate buffer synchronously (BufReadCmd requirement).
    if M.handle_fetch(buf, user, host, port, path) == true then
        -- Set filetype HERE, not inside handle_fetch: BufReadCmd fires after
        -- the window has already switched to this buffer, so TreeSitter and
        -- syntax plugins attach their on_win decoration providers correctly.
        post_read(buf, path)
    end
end

--- Write `buf` (or lines [first, last] of it) to the zero:// URI `target`.
--- Shared by BufWriteCmd / FileWriteCmd / FileAppendCmd and the oil adapter.
---
--- Rules:
---   • 写到 buffer 自己的名字且整个 buffer 写成功 → 清 'modified' + BufWritePost
---   • 写到别的 URI（:w zero://other）→ 不动当前 buffer 的 'modified'
---   • buffer 从未成功加载（b:zero_load_failed）→ 拒绝写，`:w!` 可强制覆盖
---   • 写失败 → 把 'modified' 置位，让 :wq / :x 停下来而不是丢掉修改
---@param buf integer
---@param target string zero:// URI being written
---@param opts? { first?: integer, last?: integer, append?: boolean, bang?: boolean }
---@return boolean ok
function M.write_buffer(buf, target, opts)
    opts = opts or {}
    local canon = uri_helpers.normalize(target)
    if not canon then
        logger("Invalid zero:// target: " .. tostring(target), vim.log.levels.ERROR)
        return false
    end
    local user, host, port, path = uri_helpers.parse(canon)
    local own = uri_helpers.normalize(vim.api.nvim_buf_get_name(buf)) == canon

    if path:match("/$") or (own and vim.b[buf].zero_is_dir) then
        logger("Cannot write a directory: " .. path, vim.log.levels.ERROR)
        return false
    end
    if own and vim.b[buf].zero_load_failed and not opts.bang then
        logger(string.format(
            "Refusing to write %s: the remote file was never loaded successfully (use :w! to overwrite it)",
            path), vim.log.levels.ERROR)
        return false
    end

    local content, whole = buffer_io.buffer_content(buf, opts.first, opts.last)

    if opts.append then
        local ok_old, old = M.request_interactive(user, host, port, "fetch_path", path)
        if ok_old and type(old) == "table" and old[1] == "file" then
            content = (buffer_io.to_bytes(old[2]) or "") .. content
        elseif not (not ok_old and buffer_io.is_missing_error(old)) then
            logger("Append failed: " .. tostring(old), vim.log.levels.ERROR)
            return false
        end
        whole = false
    end

    local ok, res = M.request_interactive(user, host, port, "write_file", path, content)
    local full_own = own and whole
    if ok and res == true then
        if full_own then
            vim.bo[buf].modified = false
            vim.b[buf].zero_load_failed = nil
            vim.b[buf].zero_new_file = nil
            vim.b[buf].zero_loaded = true
            vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf, modeline = false })
        end
        logger(string.format('"%s" %dB written', path, #content), vim.log.levels.INFO)
        return true
    end

    logger("Save failed: " .. tostring(res), vim.log.levels.ERROR)
    if full_own then
        -- BufWriteCmd 返回时 buffer 仍是 modified → Vim 视为写失败，:wq 不会退出
        vim.bo[buf].modified = true
    end
    return false
end

--- vim.fn.readfile() replacement for zero:// paths (honours {type} and {max}).
---@param fname string
---@param ftype? string
---@param max? integer
---@return string[]
function M._readfile(fname, ftype, max)
    local canon = uri_helpers.normalize(fname)
    local user, host, port, path = uri_helpers.parse(canon or "")
    if not user then error("E484: Can't open file " .. fname, 0) end

    local content
    local b = find_buf(canon)
    if b and buffer_io.is_loaded(b) and not vim.bo[b].modified and not vim.b[b].zero_is_dir then
        content = buffer_io.buffer_content(b)
    else
        local ok, res = M.request(user, host, port, "fetch_path", path)
        if not ok or type(res) ~= "table" or res[1] ~= "file" then
            error("E484: Can't open file " .. fname, 0)
        end
        content = buffer_io.to_bytes(res[2]) or ""
    end

    local binary = type(ftype) == "string" and ftype:find("b", 1, true) ~= nil
    local lines = vim.split(content, "\n", { plain = true })
    if not binary then
        -- readfile(): 末尾换行不产生额外空项；NL 前的 CR 去掉
        if lines[#lines] == "" then table.remove(lines) end
        for i, l in ipairs(lines) do lines[i] = (l:gsub("\r$", "")) end
    end
    -- readfile() 里 NUL 以 NL 表示
    for i, l in ipairs(lines) do lines[i] = (l:gsub("%z", "\n")) end

    max = tonumber(max)
    if max then
        if max == 0 then return {} end
        if max > 0 then
            return { unpack(lines, 1, math.min(max, #lines)) }
        end
        return { unpack(lines, math.max(1, #lines + max + 1), #lines) }
    end
    return lines
end

--- Make sure the zero:// buffers referenced by LSP locations hold content
--- before Neovim's LSP code reads them. Fetches everything that is missing in
--- one `fetch_paths` round-trip per host, stashes the content, then
--- `bufload`s each buffer so BufReadCmd (or oil's read_file) consumes the
--- stash instead of fetching again. URIs are canonicalized in place so
--- vim.uri_to_bufnr() lands on the same buffer as BufReadCmd's canonical name.
---@param locations table[]
function M._preload_locations(locations)
    if type(locations) ~= "table" then return end
    local hosts, order, needed = {}, {}, {}
    local seen = {}
    for _, loc in ipairs(locations) do
        if type(loc) == "table" then
            local field = (type(loc.uri) == "string" and "uri")
                or (type(loc.targetUri) == "string" and "targetUri") or nil
            local raw = field and loc[field]
            if raw and raw:match("^zero://") then
                local canon = uri_helpers.normalize(raw)
                if canon then
                    loc[field] = canon
                    if not seen[canon] and not canon:match("/$") then
                        seen[canon] = true
                        local b = find_buf(canon)
                        local loaded = b and vim.api.nvim_buf_is_loaded(b)
                        if not loaded or (b and vim.b[b].zero_load_failed) then
                            local u, h, p, fpath = uri_helpers.parse(canon)
                            local key = target_key(u, h, p)
                            if not hosts[key] then
                                hosts[key] = { user = u, host = h, port = p, paths = {}, uris = {} }
                                table.insert(order, key)
                            end
                            table.insert(hosts[key].paths, fpath)
                            table.insert(hosts[key].uris, canon)
                            table.insert(needed, canon)
                        end
                    end
                end
            end
        end
    end
    if #needed == 0 then return end

    for _, key in ipairs(order) do
        local hd = hosts[key]
        if #hd.paths == 1 then
            local ok, res = M.request(hd.user, hd.host, hd.port, "fetch_path", hd.paths[1])
            if ok and type(res) == "table" and res[1] == "file" then
                prefetched[hd.uris[1]] = buffer_io.to_bytes(res[2]) or ""
            end
        else
            logger(string.format("Batch fetching %d files from %s", #hd.paths, key), vim.log.levels.DEBUG)
            local ok, content_map = M.request(hd.user, hd.host, hd.port, "fetch_paths", hd.paths)
            if ok and type(content_map) == "table" then
                for i, fpath in ipairs(hd.paths) do
                    local content = buffer_io.to_bytes(content_map[fpath])
                    if type(content) == "string" then
                        prefetched[hd.uris[i]] = content
                    end
                end
            else
                logger("Batch fetch failed: " .. tostring(content_map), vim.log.levels.WARN)
            end
        end
    end

    for _, canon in ipairs(needed) do
        local b = find_buf(canon) or vim.fn.bufadd(canon)
        if not vim.api.nvim_buf_is_loaded(b) then
            pcall(vim.fn.bufload, b)
        elseif vim.b[b].zero_load_failed then
            local u, h, p, fpath = uri_helpers.parse(canon)
            pcall(M.handle_fetch, b, u, h, p, fpath)
        end
        prefetched[canon] = nil -- 未被消费（例如 oil 走了别的路径）就丢弃
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
local function attach_matching_clients(buf)
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then return end
    local u, h, p, fpath = uri_helpers.parse(vim.api.nvim_buf_get_name(buf))
    if not u or fpath:match("/$") then return end
    local best_by_name = client_select.select_attach_clients_for_path(vim.lsp.get_clients(), target_key(u, h, p), fpath)
    for cname, client in pairs(best_by_name) do
        if #vim.lsp.get_clients({ bufnr = buf, name = cname }) == 0 then
            logger(string.format("Auto-attaching LSP %s to buffer %d", cname, buf), vim.log.levels.DEBUG)
            pcall(vim.lsp.buf_attach_client, buf, client.id)
        end
    end
end

--- Open a remote:// URI given resolved connection params and path.
---@param user string
---@param host string
---@param port integer
---@param path string
function M.open_remote(user, host, port, path)
    -- Ensure path starts with /
    if not path:match("^/") then
        -- Expand ~ to remote $HOME (resolved by daemon, falls back to /home/<user>)
        local function home()
            return M.get_remote_home(user, host, port) or ("/home/" .. user)
        end
        if path:match("^~") then
            path = home() .. path:sub(2)
        else
            path = home() .. "/" .. path
        end
    end
    path = uri_helpers.normalize_path(path)

    -- Stat via daemon: extension-only heuristics misclassify files like
    -- Makefile / Dockerfile / LICENSE as directories.
    local is_dir = path:match("/$") ~= nil
    if not is_dir then
        local ok, ftype = M.request(user, host, port, "stat", path)
        if ok and ftype == "directory" then
            is_dir = true
        end
    end

    if is_dir then path = uri_helpers.as_dir(path) end

    local uri = uri_helpers.format(user, host, port, path)
    vim.cmd("edit " .. vim.fn.fnameescape(uri))

    -- Pre-warm declared LSP servers when opening a project root directory so
    -- that the first matching file the user opens attaches instantly instead
    -- of waiting on ssh + LSP initialize.
    if is_dir then
        local _, project_config = require("zero-nvim.project.manager").match_project(host, path, user, port)
        if project_config and type(project_config.lsp) == "table" and next(project_config.lsp) then
            vim.schedule(function()
                require("zero-nvim.lsp").prewarm_lsps(user, host, port, project_config)
            end)
        end
    end
end

--- ZeroLink command handler.
--- Usage: :ZeroLink [ssh_target] [path]
---   - No args: show SSH host picker
---   - ssh_target only: show path input
---   - ssh_target + path: open directly
---@param args string[] Command arguments (fargs)
function M.zero_link(args)
    local ssh_config = require("zero-nvim.ssh_config")
    local ui = require("zero-nvim.ui")

    local target = args[1]
    local path = args[2]

    -- Case 1: No arguments → show SSH host picker
    if not target or target == "" then
        local hosts = ssh_config.parse()
        ui.pick_host(hosts, function(entry)
            local user = entry.user or vim.env.USER or "root"
            local hostname = entry.hostname or entry.host
            local port = entry.port or 22
            -- After picking host, browse remote directories
            ui.browse_path(user, hostname, port, function(p)
                M.open_remote(user, hostname, port, p)
            end, { display_name = entry.host })
        end)
        return
    end

    -- Resolve the ssh target
    local resolved = ssh_config.resolve(target)
    if not resolved then
        logger("Cannot resolve SSH target: " .. target, vim.log.levels.ERROR)
        return
    end

    local user = resolved.user
    local hostname = resolved.hostname
    local port = resolved.port

    -- Case 3: Both target and path provided → open directly
    if path and path ~= "" then
        M.open_remote(user, hostname, port, path)
        return
    end

    -- Case 2: Only target, no path → browse remote directories
    ui.browse_path(user, hostname, port, function(p)
        M.open_remote(user, hostname, port, p)
    end, { display_name = target })
end

--- True once setup() has run (plugin/zero-nvim.lua uses it to avoid
--- overriding a user's earlier setup(opts) with defaults).
function M.is_configured()
    return M._configured == true
end

function M.setup(opts)
    options = vim.tbl_deep_extend("force", defaults, opts or {})
    M._configured = true

    local group = vim.api.nvim_create_augroup("ZeroNvim", { clear = true })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = function() state.leaving = true end,
    })

    -- zero:// buffers are virtual: content lives on the remote server, edits go
    -- through BufWriteCmd. A swap file recovers nothing useful, but Neovim
    -- still tries to create one and — worse — refuses to load the buffer
    -- (E325 ATTENTION) when it finds a stale swap left by a previously
    -- crashed nvim process. Disable swap up-front, and silently bypass any
    -- pre-existing swap file. Registered outside the oil guard so oil and
    -- builtin explorer share the fix.
    vim.api.nvim_create_autocmd("BufNew", {
        pattern = "zero://*",
        callback = function(args)
            vim.bo[args.buf].swapfile = false
        end,
        group = group,
    })

    vim.api.nvim_create_autocmd("SwapExists", {
        pattern = "zero://*",
        callback = function()
            vim.v.swapchoice = "e"
        end,
        group = group,
    })

    -- When oil is the explorer, oil's adapter handles all zero:// buffer I/O
    -- (read_file, write_file, list). Registering BufReadCmd/BufWriteCmd here
    -- would conflict with oil's own handlers and cause infinite refresh loops.
    --
    -- 文件内容只在 BufReadCmd 里加载一次（以前 BufNew 也会预取，导致每次
    -- :edit 拉两遍）。LSP 跳转路径由下面的 locations_to_items 补丁负责预取。
    if options.explorer ~= "oil" then
        vim.api.nvim_create_autocmd("BufReadCmd", {
            pattern = "zero://*",
            callback = function(args)
                M.read_buffer(args.buf, args.match)
            end,
            group = group,
        })

        -- 同步写入（不再 vim.schedule）：:wq / :x 依赖 BufWriteCmd 返回时
        -- 'modified' 已经复位，否则 E37。
        vim.api.nvim_create_autocmd("BufWriteCmd", {
            pattern = "zero://*",
            callback = function(args)
                M.write_buffer(args.buf, args.match, { bang = vim.v.cmdbang == 1 })
            end,
            group = group,
        })
    end

    -- :{range}w zero://... / :w >> zero://...  — partial write / append;
    -- '[ and '] mark the range. oil doesn't handle these events, so they are
    -- registered for both explorers.
    vim.api.nvim_create_autocmd({ "FileWriteCmd", "FileAppendCmd" }, {
        pattern = "zero://*",
        callback = function(args)
            local first = vim.api.nvim_buf_get_mark(args.buf, "[")[1]
            local last = vim.api.nvim_buf_get_mark(args.buf, "]")[1]
            M.write_buffer(args.buf, args.match, {
                first = first > 0 and first or nil,
                last = last > 0 and last or nil,
                append = args.event == "FileAppendCmd",
                bang = vim.v.cmdbang == 1,
            })
        end,
        group = group,
    })

    -- oil 把 win-local 的 signcolumn / wrap / foldcolumn / list / conceallevel 等
    -- 钉到 window 上 (lua/oil/view.lua:set_win_options)。从 oil 目录列表选文件后
    -- buffer 切了，但 window-local 选项没切 —— 最直观的副作用是 gitsigns 因为
    -- signcolumn="no" 检测到没有 sign 列、attach 直接跳过；wrap=false 也会让
    -- markdown 等期望换行的 ftplugin 失效。
    --
    -- 仅在 explorer="oil" 模式下注册：其它模式根本没人跑 set_win_options，
    -- 多余的 reset 反而会在 BufReadCmd 路径里把用户 ftplugin 的 setlocal 抹掉。
    -- 跳过目录 buffer（zero://.../）—— 那是 oil 自己的列表，保留它的样式。
    --
    -- 注册顺序：放在下面 filetype-detection BufWinEnter **之前**。oil 流里
    -- filetype 是经 FileType=oil 拦截器 vim.schedule 后才设到正确值，那时
    -- ftplugin 才真正跑 setlocal —— 那次 setlocal 在我们的 reset 之后，
    -- per-filetype 选项不会被复位掉。
    if options.explorer == "oil" then
        local oil_overridden_winopts = {
            "signcolumn", "wrap", "cursorcolumn", "foldcolumn",
            "spell", "list", "conceallevel", "concealcursor",
        }
        vim.api.nvim_create_autocmd("BufWinEnter", {
            pattern = "zero://*",
            group = group,
            callback = function(args)
                if args.file:match("/$") then return end
                local win = vim.api.nvim_get_current_win()
                if vim.api.nvim_win_get_buf(win) ~= args.buf then return end
                for _, opt in ipairs(oil_overridden_winopts) do
                    local default = vim.api.nvim_get_option_value(opt, { scope = "global" })
                    vim.api.nvim_set_option_value(opt, default, { scope = "local", win = win })
                end
            end,
        })
    end

    -- Set filetype when a zero:// buffer first enters a window without one.
    -- Placed OUTSIDE the oil guard deliberately: BufReadCmd only runs when
    -- explorer ~= "oil", but BufWinEnter must run for oil users too.
    -- It only reads content and sets filetype — no file I/O, no conflict.
    -- Covers:
    --   • oil.nvim path (oil reads content, never fires our BufReadCmd)
    --   • Any path where filetype wasn't set yet when the window opens
    --
    -- Also lists the buffer here: buffers preloaded for a quickfix/LSP list
    -- stay unlisted until the user actually opens them. Setting buflisted
    -- fires BufAdd, which buffer-manager plugins (barbar, bufferline, etc.)
    -- use to register tabs.
    vim.api.nvim_create_autocmd("BufWinEnter", {
        pattern = "zero://*",
        callback = function(args)
            local buf = args.buf
            local name = args.file
            -- bufload() 也会在临时 autocmd window 里触发 BufWinEnter —— 那不是
            -- 用户真正打开了它（quickfix 预加载），不 list、不挂 LSP。
            local in_aucmd_win = vim.fn.win_gettype() == "autocmd"
            if not in_aucmd_win then
                if not vim.bo[buf].buflisted then
                    pcall(vim.api.nvim_set_option_value, 'buflisted', true, { buf = buf })
                end
                if not name:match("/$") then
                    -- 依赖文件（site-packages 等）不会触发项目 autostart：挂上同主机
                    -- 正在运行的同名 server。schedule 出去，避开 win_set_buf 期间的限制。
                    vim.schedule(function() attach_matching_clients(buf) end)
                end
            end
            if name:match("/$") then return end -- skip directories
            if vim.bo[buf].filetype ~= "" then return end -- already set
            local _, _, _, path = M.parse_uri(name)
            if not path then return end
            local lc = vim.api.nvim_buf_line_count(buf)
            if lc == 0 then return end -- content not loaded yet
            local lines = vim.api.nvim_buf_get_lines(buf, 0, math.min(5, lc), false)
            local ft = vim.filetype.match({ filename = path, contents = lines })
            if ft and ft ~= "" then
                vim.bo[buf].filetype = ft
            end
        end,
        group = group,
    })

    -- Fix: oil.nvim sets filetype=oil on zero:// FILE buffers it manages,
    -- overriding our correctly-detected filetype (e.g. "python").
    -- Oil does this for ALL zero:// buffers, not just directory listings.
    -- Intercept FileType=oil on non-directory zero:// buffers and restore
    -- the correct filetype. vim.schedule ensures we run after oil finishes.
    vim.api.nvim_create_autocmd("FileType", {
        pattern = "oil",
        group = group,
        callback = function(args)
            local bname = vim.api.nvim_buf_get_name(args.buf)
            if not bname:match("^zero://") then return end
            if bname:match("/$") then return end  -- actual oil directory buffer, skip
            local _, _, _, path = M.parse_uri(bname)
            if not path then return end
            local lc = vim.api.nvim_buf_line_count(args.buf)
            if lc == 0 then return end
            local lines = vim.api.nvim_buf_get_lines(args.buf, 0, math.min(5, lc), false)
            local ft = vim.filetype.match({ filename = path, contents = lines })
            if ft and ft ~= "" then
                local _buf = args.buf
                vim.schedule(function()
                    if vim.api.nvim_buf_is_valid(_buf) and vim.bo[_buf].filetype == "oil" then
                        vim.bo[_buf].filetype = ft
                    end
                end)
            end
        end,
    })

    -- Auto-start configured LSP servers based on project configuration.
    -- 客户端命名统一走 lsp.client_name(<config key>)；并发启动锁只在
    -- lsp.lua (ensure_lsp_client) 里一把。
    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        callback = function(args)
            local bname = vim.api.nvim_buf_get_name(args.buf)
            if not bname:match("^zero://") then return end
            local ft = args.match

            local user, host, port, path = M.parse_uri(bname)
            if not host or not path then return end

            local _, project_config = require("zero-nvim.project.manager").match_project(host, path, user, port)
            if not project_config or type(project_config.lsp) ~= "table" then return end

            local zlsp = require("zero-nvim.lsp")
            for server_name, server_cfg in pairs(project_config.lsp) do
                if not server_cfg.filetypes then
                    logger(string.format("LSP %s is configured but missing 'filetypes' array, skipping auto-start", server_name), vim.log.levels.WARN)
                elseif vim.tbl_contains(server_cfg.filetypes, ft) then
                    local lsp_name = zlsp.client_name(server_name)
                    if #vim.lsp.get_clients({ bufnr = args.buf, name = lsp_name }) == 0 then
                        local root_dir = client_select.norm_root(project_config.root)
                        local cmd_args = (server_cfg.cmd and #server_cfg.cmd > 0) and server_cfg.cmd
                            or { server_name, "--stdio" }
                        local _buf = args.buf
                        logger(string.format("Auto-starting LSP %s for buffer %d", lsp_name, _buf), vim.log.levels.DEBUG)
                        -- Schedule so we don't block FileType processing
                        vim.schedule(function()
                            if vim.api.nvim_buf_is_valid(_buf) then
                                zlsp.start_lsp(_buf, vim.deepcopy(cmd_args), nil, {
                                    project_config = project_config,
                                    root_dir = root_dir,
                                    server_key = server_name,
                                })
                            end
                        end)
                    else
                        logger(string.format("LSP %s already active for buffer %d", lsp_name, args.buf), vim.log.levels.DEBUG)
                    end
                end
            end
        end,
    })

    -- Patch vim.fn.readfile so third-party plugins (references viewers, code
    -- preview windows, etc.) that read file content directly via readfile()
    -- — bypassing Neovim's BufReadCmd machinery — still work for zero:// URIs.
    -- Without this they error out with "cannot read file: zero://...".
    -- Patching at vim.fn.readfile catches Lua-side callers; Vimscript
    -- `:call readfile()` is unaffected (uses the C builtin directly).
    -- {type} ("b") and {max} are honoured; failures raise E484 like the real one.
    if not patches.readfile then
        patches.readfile = true
        local _orig_readfile = vim.fn.readfile
        vim.fn.readfile = function(path, ...)
            if type(path) == "string" and path:match("^zero://") then
                return M._readfile(path, ...)
            end
            return _orig_readfile(path, ...)
        end
    end

    -- Patch vim.lsp.buf_request_all to pre-load any zero:// buffers referenced
    -- in the LSP response. Third-party reference/preview plugins (e.g.
    -- code-view.nvim) call buf_request_all directly and then use io.open() on
    -- the URI string — io.open can't read zero://, but those plugins typically
    -- check for an already-loaded buffer with the same name first.
    if not patches.buf_request_all then
        patches.buf_request_all = true
        local _orig_brall = vim.lsp.buf_request_all
        local jump_methods = {
            ["textDocument/definition"]     = true,
            ["textDocument/declaration"]    = true,
            ["textDocument/typeDefinition"] = true,
            ["textDocument/implementation"] = true,
            ["textDocument/references"]     = true,
        }
        vim.lsp.buf_request_all = function(bufnr, method, params, handler)
            if not jump_methods[method] then
                return _orig_brall(bufnr, method, params, handler)
            end
            return _orig_brall(bufnr, method, params, function(results, ctx)
                local locs = {}
                for _, r in pairs(results or {}) do
                    local res = r and r.result
                    if type(res) == "table" then
                        if res.uri or res.targetUri then
                            table.insert(locs, res)
                        else
                            for _, loc in ipairs(res) do table.insert(locs, loc) end
                        end
                    end
                end
                pcall(M._preload_locations, locs)
                return handler(results, ctx)
            end)
        end
    end

    -- Patch vim.lsp.util.locations_to_items to pre-load zero:// buffers before
    -- the LSP jump. This is the call site in buf.lua's on_response callback
    -- (vim.schedule context = no textlock). Accessed via table field lookup
    -- (util.locations_to_items), so our patch IS visible even when keybindings
    -- captured vim.lsp.buf.definition by reference before this patch ran.
    -- 只加载真正需要的 buffer：缺内容的文件按 host 一次 fetch_paths 批量拉取，
    -- 再 bufload（BufReadCmd 直接消费预取内容）；列表里的 buffer 保持 unlisted，
    -- 用户真正进入时由 BufWinEnter 设 buflisted / 挂 LSP。
    if not patches.locations_to_items then
        patches.locations_to_items = true
        local _orig_lti = vim.lsp.util.locations_to_items
        vim.lsp.util.locations_to_items = function(locations, offset_encoding)
            local ok_pre, pre_err = pcall(M._preload_locations, locations)
            if not ok_pre then
                logger("Preloading LSP locations failed: " .. tostring(pre_err), vim.log.levels.DEBUG)
            end

            -- Defensive cursor re-snap for single-location jumps to zero://
            -- buffers. Some adapters (notably oil.nvim's async read_file)
            -- replace ALL lines AFTER the LSP framework set the cursor — Neovim
            -- then resets the cursor in displaying windows to (1,0).
            if type(locations) == "table" and #locations == 1 then
                local _loc = locations[1]
                local _uri = _loc.uri or _loc.targetUri
                local _range = _loc.range or _loc.targetSelectionRange
                if type(_uri) == "string" and _uri:match("^zero://") and _range and _range.start then
                    local target_line = (_range.start.line or 0) + 1
                    local target_char = _range.start.character or 0
                    local target_bnum = find_buf(_uri)
                    if target_bnum then
                        vim.schedule(function()
                            if not vim.api.nvim_buf_is_valid(target_bnum) then return end
                            for _, w in ipairs(vim.fn.win_findbuf(target_bnum)) do
                                local cur = vim.api.nvim_win_get_cursor(w)
                                if cur[1] ~= target_line then
                                    local lc = vim.api.nvim_buf_line_count(target_bnum)
                                    local lnum = math.min(target_line, math.max(1, lc))
                                    local line = vim.api.nvim_buf_get_lines(target_bnum, lnum - 1, lnum, false)[1] or ""
                                    local col = math.min(target_char, #line)
                                    pcall(vim.api.nvim_win_set_cursor, w, { lnum, col })
                                    pcall(vim.api.nvim_win_call, w, function() vim.cmd('normal! zv') end)
                                end
                            end
                        end)
                    end
                end
            end

            return _orig_lti(locations, offset_encoding)
        end
    end

    -- Register :ZeroLink user command
    vim.api.nvim_create_user_command("ZeroLink", function(cmd_opts)
        M.zero_link(cmd_opts.fargs)
    end, {
        nargs = "*",
        desc = "Connect to remote server via SSH config",
        complete = function(arg_lead, cmd_line, cursor_pos)
            -- Provide completion for SSH host aliases
            local parts = vim.split(cmd_line, "%s+")
            if #parts <= 2 then
                -- Completing first arg: ssh target
                local ssh_config = require("zero-nvim.ssh_config")
                local hosts = ssh_config.parse()
                local completions = {}
                for _, entry in ipairs(hosts) do
                    if entry.host:find(arg_lead, 1, true) == 1 then
                        table.insert(completions, entry.host)
                    end
                end
                return completions
            end
            return {}
        end,
    })

    -- [NEW] Register :ZeroProject command with subcommands
    vim.api.nvim_create_user_command("ZeroProject", function(opts)
        local args = opts.fargs
        local subcommand = args[1]
        local project_ui = require("zero-nvim.project.ui")

        if not subcommand or subcommand == "" then
            project_ui.show_project_picker()
        elseif subcommand == "add" then
            project_ui.add_current_project()
        elseif subcommand == "check" then
            local target = args[2]
            project_ui.check_health(target)
        else
            vim.notify("Unknown subcommand: " .. subcommand, vim.log.levels.ERROR)
        end
    end, {
        nargs = "*",
        desc = "Manage ZeroNvim projects (add, check, or list)",
        complete = function(arg_lead, cmd_line, cursor_pos)
            local parts = vim.split(cmd_line, "%s+")
            if #parts == 2 then
                -- Subcommand completion
                local cmds = { "add", "check" }
                return vim.tbl_filter(function(item)
                    return vim.startswith(item, arg_lead)
                end, cmds)
            elseif #parts == 3 and parts[2] == "check" then
                -- Project name completion for check
                local manager = require("zero-nvim.project.manager")
                local projects = manager.list()
                return vim.tbl_filter(function(item)
                    return vim.startswith(item, arg_lead)
                end, vim.tbl_keys(projects))
            end
            return {}
        end,
    })

    -- [NEW] Register :ZeroSearch user command
    vim.api.nvim_create_user_command("ZeroSearch", function(cmd_opts)
        require("zero-nvim.search").live_grep()
    end, {
        nargs = 0,
        desc = "Search remote server using Telescope",
    })

    -- [NEW] Register :ZeroLspStart user command
    -- The project-config entry (cmd/settings) is resolved inside start_lsp,
    -- keyed by config key so the client name matches autostart / prewarm.
    vim.api.nvim_create_user_command("ZeroLspStart", function(cmd_opts)
        require("zero-nvim.lsp").start_lsp(0, cmd_opts.fargs, nil)
    end, {
        nargs = "+",
        desc = "Start remote LSP via TCP proxy (e.g. :ZeroLspStart basedpyright --stdio)",
        complete = function(arg_lead, cmd_line, _)
            local parts = vim.split(cmd_line, "%s+")
            -- Only complete the first arg (the LSP binary name)
            if #parts <= 2 then
                -- Prefer the bins cached for the current buffer's remote so
                -- multi-host setups suggest the right list.
                local bname = vim.api.nvim_buf_get_name(0)
                local u, h, p = M.parse_uri(bname)
                local bins = (u and h and p) and M.get_mason_bins(u, h, p) or M.get_mason_bins()
                local completions = {}
                for _, name in ipairs(bins) do
                    if name:find(arg_lead, 1, true) == 1 then
                        table.insert(completions, name)
                    end
                end
                return completions
            end
            return {}
        end,
    })

    -- Register :ZeroLspStop [server_name] — stop a remote LSP client.
    -- Stopping the Neovim client closes the TCP socket, which terminates
    -- the daemon's SSH subprocess for that LSP session.
    vim.api.nvim_create_user_command("ZeroLspStop", function(cmd_opts)
        local arg = cmd_opts.fargs[1]
        local bufnr = vim.api.nvim_get_current_buf()

        local clients
        if arg and arg ~= "" then
            -- Accept either "basedpyright" or "zero-basedpyright"
            local lsp_name = arg:match("^zero%-") and arg or require("zero-nvim.lsp").client_name(arg)
            clients = vim.lsp.get_clients({ name = lsp_name })
        else
            -- Stop all zero-* clients attached to the current buffer
            clients = vim.tbl_filter(
                function(c) return c.name:match("^zero%-") end,
                vim.lsp.get_clients({ bufnr = bufnr })
            )
        end

        if #clients == 0 then
            vim.notify("ZeroNvim: no matching LSP client found", vim.log.levels.WARN)
            return
        end
        for _, client in ipairs(clients) do
            require("zero-nvim.lsp").mark_intentional_stop(client.id)
            client.stop()
            vim.notify("ZeroNvim: stopped LSP " .. client.name, vim.log.levels.INFO)
        end
    end, {
        nargs = "?",
        desc = "Stop remote LSP client (e.g. :ZeroLspStop basedpyright or :ZeroLspStop)",
        complete = function(arg_lead, _, _)
            local completions = {}
            for _, c in ipairs(vim.lsp.get_clients()) do
                if c.name:match("^zero%-") then
                    local short = c.name:gsub("^zero%-", "")
                    if short:find(arg_lead, 1, true) == 1 then
                        table.insert(completions, short)
                    end
                end
            end
            return completions
        end,
    })

    -- :ZeroLspRestart — 立刻触发所有 dormant LSP（处于退避重试中的）一次重试，
    -- 并把 30 分钟时窗复位。VimResume / FocusGained autocmd 也走这个入口。
    vim.api.nvim_create_user_command("ZeroLspRestart", function()
        local count = require("zero-nvim.lsp").revive_dormant_now()
        if count > 0 then
            vim.notify(string.format("ZeroNvim: kicked %d dormant LSP%s", count, count == 1 and "" or "s"),
                vim.log.levels.INFO)
        else
            vim.notify("ZeroNvim: no dormant LSPs to revive", vim.log.levels.INFO)
        end
    end, {
        nargs = 0,
        desc = "Kick dormant zero-* LSP clients into an immediate retry",
    })

    -- Suspend/resume + focus regain: 用户合盖再开 / 切回 Neovim 时，网络多半
    -- 已经恢复，没必要等退避计时器走完。VimResume 在 Neovim 0.10+ 才有，但
    -- 用 pcall 兜底；旧版没这事件就走 FocusGained。
    pcall(vim.api.nvim_create_autocmd, "VimResume", {
        group = group,
        callback = function()
            local lsp = require("zero-nvim.lsp")
            if lsp.dormant_count() > 0 then lsp.revive_dormant_now() end
        end,
    })
    vim.api.nvim_create_autocmd("FocusGained", {
        group = group,
        callback = function()
            local lsp = require("zero-nvim.lsp")
            if lsp.dormant_count() > 0 then lsp.revive_dormant_now() end
        end,
    })

    -- Register :ZeroLspAdd [server] — interactive wizard that writes an LSP
    -- entry into the current project's config and prewarms it.
    vim.api.nvim_create_user_command("ZeroLspAdd", function(cmd_opts)
        local prefill = cmd_opts.fargs[1]
        local bname = vim.api.nvim_buf_get_name(0)
        local user, host, port, path = M.parse_uri(bname)
        if not user then
            vim.notify("ZeroNvim: open a file inside a configured remote project first", vim.log.levels.ERROR)
            return
        end
        local manager = require("zero-nvim.project.manager")
        local project_name, project_config = manager.match_project(host, path, user, port)
        if not project_name then
            vim.notify(string.format(
                "ZeroNvim: no project matches %s:%s — run :ZeroProject add first", host, path),
                vim.log.levels.ERROR)
            return
        end
        require("zero-nvim.ui.lsp_add_wizard").open({
            user = user, host = host, port = port,
            project_name = project_name,
            project_config = project_config,
            prefill_server = prefill,
        })
    end, {
        nargs = "?",
        desc = "Add an LSP server to the current project (interactive)",
        complete = function(arg_lead, _, _)
            local bname = vim.api.nvim_buf_get_name(0)
            local u, h, p = M.parse_uri(bname)
            local bins = (u and h and p) and M.get_mason_bins(u, h, p) or M.get_mason_bins()
            local out = {}
            for _, name in ipairs(bins) do
                if name:find(arg_lead, 1, true) == 1 then
                    table.insert(out, name)
                end
            end
            return out
        end,
    })

    -- [NEW] Register :ZeroSearchMini user command
    vim.api.nvim_create_user_command("ZeroSearchMini", function(cmd_opts)
        require("zero-nvim.search_mini").open()
    end, {
        nargs = 0,
        desc = "Local buffer search and replace using floating windows",
    })

    -- Register the gitsigns data-layer backend so zero:// buffers in remote
    -- git repos get the same diff signs / hunk navigation / blame as local
    -- files. Requires the forked gitsigns that exposes `gitsigns.backends`;
    -- with upstream gitsigns this is a silent no-op (local files unaffected).
    require("zero-nvim.gitsigns.backend").setup(options.gitsigns)

    -- Register the neogit data/process-layer backend so :Neogit on remote
    -- repos routes git execution to the daemon. Requires the forked neogit
    -- that exposes `neogit.backends`; upstream neogit silently skips.
    require("zero-nvim.neogit.backend").setup(options.neogit)
end

return M
