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
}

-- 插件内部状态
local state = {
    channel_id = nil,
    connected_hosts = {},
    scanned_projects = {},
    mason_bins = {}, -- key: "user@host:port" -> list of mason bin names
    python_paths = {}, -- key: "user@host:port" -> resolved python interpreter path
    remote_homes = {}, -- key: "user@host:port" -> remote $HOME (resolved on first probe)
}

local options = {}

local function logger(msg, level)
    level = level or vim.log.levels.INFO
    if level >= options.log.level then
        vim.notify(options.log.prefix .. msg, level)
    end
end

local uri_helpers = require("zero-nvim.uri")

function M.parse_uri(uri)
    return uri_helpers.parse(uri)
end

local function get_daemon_bin()
    if options.daemon.path and vim.fn.executable(options.daemon.path) == 1 then
        return options.daemon.path
    end
    local script_path = debug.getinfo(1).source:sub(2)
    local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script_path)))
    local relative_path = string.format("/daemon/target/%s/zero-nvim-daemon", options.daemon.build_type)
    local detected_path = plugin_root .. relative_path
    if vim.fn.executable(detected_path) == 1 then return detected_path end
    local cwd_path = vim.fn.getcwd() .. relative_path
    if vim.fn.executable(cwd_path) == 1 then return cwd_path end
    return nil
end

local function get_daemon_chan()
    if state.channel_id then return state.channel_id end
    local bin_path = get_daemon_bin()
    if not bin_path then
        logger("Daemon binary not found.", vim.log.levels.ERROR)
        return nil
    end
    state.channel_id = vim.fn.jobstart({ bin_path }, {
        rpc = true,
        on_exit = function(_, code)
            state.channel_id = nil
            state.connected_hosts = {}
            state.scanned_projects = {}
            state.mason_bins = {}
            state.python_paths = {}
            state.remote_homes = {}
        end,
        on_stderr = function(_, data)
            for _, line in ipairs(data) do
                if line ~= "" then logger("Daemon: " .. line, vim.log.levels.WARN) end
            end
        end,
    })
    return state.channel_id
end

--- 暴露 daemon channel 给其他模块（如 ssh_config.lua）使用
--- 仅在 daemon 已启动时返回 channel_id，不会自动启动 daemon
function M._get_daemon_chan()
    return state.channel_id
end

function M.ensure_connection(user, host, port, password)
    local chan = get_daemon_chan()
    if not chan then return nil, "Daemon not running" end
    local key = string.format("%s@%s:%s", user, host, port)

    if not state.connected_hosts[key] then
        local ok, res = pcall(vim.fn.rpcrequest, chan, "connect", user, host, port, password)
        if not ok then
            return nil, tostring(res)
        end
        state.connected_hosts[key] = true
        -- Async: scan mason/bin on the remote server for LSP autocomplete
        vim.schedule(function()
            M.scan_mason_bins(user, host, port)
        end)
    end
    return chan
end

--- Resolve and cache the remote user's $HOME. Used by anything that wants to
--- address a path relative to the user's home (mason bin scan etc.). Hard-
--- coding /home/<user> breaks on macOS (/Users/...), root (/root), and
--- containerized hosts where $HOME is non-standard.
---@return string?
function M.get_remote_home(user, host, port)
    local key = string.format("%s@%s:%s", user, host, port)
    if state.remote_homes[key] then return state.remote_homes[key] end
    local chan = get_daemon_chan()
    if not chan then return nil end
    local ok, home = pcall(vim.fn.rpcrequest, chan, "exec_remote", user, host, port, 'printf %s "$HOME"')
    if not ok or type(home) ~= "string" or home == "" then return nil end
    state.remote_homes[key] = home
    return home
end

--- Scan <remote-home>/.local/share/nvim/mason/bin/ and cache the bin names.
--- Results are used as autocomplete suggestions for :ZeroLspStart.
function M.scan_mason_bins(user, host, port)
    local chan = get_daemon_chan()
    if not chan then return end
    local home = M.get_remote_home(user, host, port)
    if not home then return end
    local key = string.format("%s@%s:%s", user, host, port)
    local mason_bin_path = home .. "/.local/share/nvim/mason/bin"
    local ok, entries = pcall(vim.fn.rpcrequest, chan, "read_dir", user, host, port, mason_bin_path)
    if not ok or type(entries) ~= "table" then
        -- Mason not installed on remote — fallback silently, autocomplete
        -- just won't show Mason bins.
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
--- When user/host/port are provided, returns the bins for that exact remote.
--- When called with no args, returns the first cached host's bins (legacy
--- behaviour preserved for callers that lack buffer context).
---@param user? string
---@param host? string
---@param port? integer
---@return string[]
function M.get_mason_bins(user, host, port)
    if user and host and port then
        local key = string.format("%s@%s:%s", user, host, port)
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
    return state.python_paths[string.format("%s@%s:%s", user, host, port)]
end

function M.set_python_path(user, host, port, path)
    state.python_paths[string.format("%s@%s:%s", user, host, port)] = path
end

function M.get_entries(user, host, port, path)
    local chan, err = M.ensure_connection(user, host, port)
    if not chan then return nil, err end
    local project_key = string.format("%s@%s:%d:%s", user, host, port, path)
    if not state.scanned_projects[project_key] then
        vim.rpcnotify(chan, "scan_project", user, host, port, path)
        state.scanned_projects[project_key] = true
    end
    local ok, entries = pcall(vim.fn.rpcrequest, chan, "read_dir", user, host, port, path)
    if not ok then return nil, tostring(entries) end
    return entries
end

function M.get_file_content(user, host, port, path)
    local chan, err = M.ensure_connection(user, host, port)
    if not chan then return nil, err end
    local ok, content = pcall(vim.fn.rpcrequest, chan, "fetch_file", user, host, port, path)
    if not ok then return nil, tostring(content) end
    return content
end

local function setup_dir_buffer(buf, user, host, port, path, entries)
    local lines = { '" Remote Directory: ' .. path, '" Press <CR> to open, R to refresh, .. to go up', "" }
    local entry_map = {}
    table.insert(lines, " ../")
    entry_map[#lines] = { name = "..", type = "directory" }
    table.sort(entries, function(a, b)
        if a.type ~= b.type then return a.type == "directory" end
        return a.name < b.name
    end)
    for _, entry in ipairs(entries) do
        local display = (entry.type == "directory" and " " or " ") .. entry.name
        if entry.type == "directory" then display = display .. "/" end
        table.insert(lines, display)
        entry_map[#lines] = entry
    end
    vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value('modified', false, { buf = buf })
    vim.api.nvim_set_option_value('readonly', true, { buf = buf })
    vim.api.nvim_set_option_value('filetype', 'netrw', { buf = buf })
    vim.keymap.set('n', '<CR>', function()
        local line = vim.fn.line('.')
        local entry = entry_map[line]
        if not entry then return end
        local new_path = entry.name == ".." and vim.fs.dirname(path) or (path:gsub("/$", "") .. "/" .. entry.name)
        local uri = string.format("zero://%s@%s:%d%s", user, host, port, new_path)
        if entry.type == "directory" then
            local ok, _ = pcall(vim.api.nvim_buf_set_name, buf, uri)
            if not ok then vim.cmd("edit " .. uri) else M.handle_fetch(buf, user, host, port, new_path) end
        else
            vim.cmd("edit " .. uri)
        end
    end, { buffer = buf, silent = true })
    vim.keymap.set('n', 'R', function() M.handle_fetch(buf, user, host, port, path, nil, true) end,
        { buffer = buf, silent = true })
end

function M.handle_fetch(buf, user, host, port, path, password, refresh)
    local chan, err = M.ensure_connection(user, host, port, password)

    if not chan then
        local err_str = type(err) == "string" and err or tostring(err or "unknown error")
        -- 核心改进：只有明确包含 AUTH_FAILED 字样才弹窗
        if not password and err_str:match("AUTH_FAILED") then
            vim.ui.input({ prompt = "SSH Password: ", secret = true }, function(input)
                if input then
                    vim.schedule(function() M.handle_fetch(buf, user, host, port, path, input) end)
                end
            end)
            return
        end
        -- 其他错误（如 Banner 失败，SFTP 不支持等）直接报错
        logger("Connection failed: " .. err_str, vim.log.levels.ERROR)
        return
    end

    local ok_fetch, fetch_res = pcall(vim.fn.rpcrequest, chan, "fetch_path", user, host, port, path)
    if not ok_fetch then
        logger("Access failed: " .. tostring(fetch_res), vim.log.levels.ERROR)
        return
    end

    local ftype = fetch_res[1]
    
    if ftype == "directory" then
        if options.explorer == "oil" then
            local oil_uri = string.format("zero://%s@%s:%d%s", user, host, port, path)
            -- 在跳转 Oil 之前，显式将 zero:// buffer 标记为已成功完成（虽然我们要跳走）
            -- 这样可以防止某些 autocommands 触发
            vim.api.nvim_buf_delete(buf, { force = true })
            vim.cmd("edit " .. oil_uri)
            return
        end
        local entries = M.get_entries(user, host, port, path)
        if entries then setup_dir_buffer(buf, user, host, port, path, entries) end
    elseif ftype == "file" then
        local content = fetch_res[2]
        if content then
            local lines = vim.split(content, "\n")
            if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
            vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            vim.api.nvim_set_option_value('modified', false, { buf = buf })
            -- Do NOT set readonly=true: it causes W10 warnings whenever Neovim's
            -- internal buffer-loading machinery (bufload, BufRead events, fold
            -- operations) touches the buffer after our pre-fetch. Writes are
            -- handled exclusively via BufWriteCmd, so readonly is not needed.
            -- List the buffer so buffer-manager plugins (barbar, bufferline, etc.)
            -- detect it via BufAdd. bufadd() creates unlisted buffers by default.
            vim.api.nvim_set_option_value('buflisted', true, { buf = buf })
            -- NOTE: filetype is NOT set here.
            -- Setting it inside handle_fetch is too early for the BufNew path:
            -- BufNew fires before the buffer enters any window, so TreeSitter's
            -- on_win decoration provider never fires and highlights don't appear.
            -- Filetype is set instead by:
            --   • BufReadCmd callback  — direct open / file browser (:edit)
            --   • BufWinEnter autocmd  — LSP-jump path (vim.fn.bufadd, no BufReadCmd)
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
            -- Connection is required to probe; ensure_connection is idempotent.
            M.ensure_connection(user, host, port)
            return M.get_remote_home(user, host, port) or ("/home/" .. user)
        end
        if path:match("^~") then
            path = path:gsub("^~", home())
        else
            path = home() .. "/" .. path
        end
    end

    -- Stat via daemon: extension-only heuristics misclassify files like
    -- Makefile / Dockerfile / LICENSE as directories.
    local is_dir = path:match("/$") ~= nil
    if not is_dir then
        local chan = M.ensure_connection(user, host, port)
        if chan then
            local ok, ftype = pcall(vim.fn.rpcrequest, chan, "stat", user, host, port, path)
            if ok and ftype == "directory" then
                is_dir = true
            end
        end
    end

    if is_dir and not path:match("/$") then path = path .. "/" end

    local uri = uri_helpers.format(user, host, port, path)
    vim.cmd("edit " .. uri)

    -- Pre-warm declared LSP servers when opening a project root directory so
    -- that the first matching file the user opens attaches instantly instead
    -- of waiting on ssh + LSP initialize.
    if is_dir then
        local _, project_config = require("zero-nvim.project.manager").match_project(host, path)
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

function M.setup(opts)
    options = vim.tbl_deep_extend("force", defaults, opts or {})

    local group = vim.api.nvim_create_augroup("ZeroNvim", { clear = true })

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
    if options.explorer ~= "oil" then
        -- Pre-load zero:// file buffers the moment they are created.
        -- vim.fn.bufadd() (used by vim.uri_to_bufnr in locations_to_items)
        -- creates an *unlisted* buffer, so BufAdd does NOT fire for it.
        -- BufNew fires for any new buffer regardless of listed status.
        vim.api.nvim_create_autocmd("BufNew", {
            pattern = "zero://*",
            callback = function(args)
                local name = args.file
                -- Skip directory buffers (LSP jumps target files, not dirs)
                if name:match("/$") then return end
                local user, host, port, path = M.parse_uri(name)
                if not user then return end
                -- Skip if buffer already has content
                local lc = vim.api.nvim_buf_line_count(args.buf)
                local already_loaded = lc > 1 or
                    (lc == 1 and vim.api.nvim_buf_get_lines(args.buf, 0, 1, false)[1] ~= "")
                if already_loaded then return end
                -- Only fetch if daemon is connected (avoid errors on startup)
                if not state.channel_id then return end
                M.handle_fetch(args.buf, user, host, port, path)
                -- Wake plugins (gitsigns attach autocmd, etc.) that listen for
                -- BufReadPost — bufadd-driven flow doesn't fire it on its own.
                vim.api.nvim_exec_autocmds("BufReadPost", { buffer = args.buf })
            end,
            group = group,
        })

        vim.api.nvim_create_autocmd("BufReadCmd", {
            pattern = "zero://*",
            callback = function(args)
                local user, host, port, path = M.parse_uri(args.file)
                if not user then return end
                -- Populate buffer synchronously (BufReadCmd requirement).
                M.handle_fetch(args.buf, user, host, port, path)
                -- Set filetype HERE, not inside handle_fetch.
                -- BufReadCmd fires after the window has already switched to this
                -- buffer, so the current buffer IS args.buf. This means TreeSitter
                -- and syntax plugins see the buffer as the active window buffer
                -- and attach their on_win decoration providers correctly.
                -- Content-based detection covers shebangs / extension-less files.
                local lines = vim.api.nvim_buf_get_lines(args.buf, 0, 5, false)
                local ft = vim.filetype.match({ filename = path, contents = lines })
                if ft and ft ~= "" then
                    vim.bo[args.buf].filetype = ft
                end
                -- BufReadCmd replaces BufRead — downstream readers (gitsigns
                -- attach autocmd, etc.) need an explicit BufReadPost to wake up.
                vim.api.nvim_exec_autocmds("BufReadPost", { buffer = args.buf })
            end,
            group = group,
        })

        vim.api.nvim_create_autocmd("BufWriteCmd", {
            pattern = "zero://*",
            callback = function(args)
                local user, host, port, path = M.parse_uri(args.file)
                if not user then return end

                local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
                local content = table.concat(lines, "\n")
                if #content > 0 and content:sub(-1) ~= "\n" then
                    content = content .. "\n"
                end

                local chan = get_daemon_chan()
                if not chan then
                    logger("Daemon not connected, cannot save.", vim.log.levels.ERROR)
                    return
                end

                vim.schedule(function()
                    local ok, res = pcall(vim.fn.rpcrequest, chan, "write_file", user, host, port, path, content)
                    if ok and res == true then
                        vim.api.nvim_set_option_value('modified', false, { buf = args.buf })
                        logger("Saved: " .. path, vim.log.levels.INFO)
                    else
                        logger("Save failed: " .. tostring(res), vim.log.levels.ERROR)
                    end
                end)
            end,
            group = group,
        })
    end

    -- Set filetype when a zero:// buffer first enters a window without one.
    -- Placed OUTSIDE the oil guard deliberately: BufReadCmd only runs when
    -- explorer ~= "oil", but BufWinEnter must run for oil users too.
    -- It only reads content and sets filetype — no file I/O, no conflict.
    -- Covers:
    --   • LSP-jump path (bufadd → BufNew loads content, no BufReadCmd)
    --   • oil.nvim path (oil reads content, never fires our BufReadCmd)
    --   • Any path where filetype wasn't set yet when the window opens
    vim.api.nvim_create_autocmd("BufWinEnter", {
        pattern = "zero://*",
        callback = function(args)
            if vim.bo[args.buf].filetype ~= "" then return end  -- already set
            local name = args.file
            if name:match("/$") then return end  -- skip directories
            local _, _, _, path = M.parse_uri(name)
            if not path then return end
            local lc = vim.api.nvim_buf_line_count(args.buf)
            if lc == 0 then return end  -- content not loaded yet
            local lines = vim.api.nvim_buf_get_lines(args.buf, 0, math.min(5, lc), false)
            local ft = vim.filetype.match({ filename = path, contents = lines })
            if ft and ft ~= "" then
                vim.bo[args.buf].filetype = ft
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
    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        callback = function(args)
            local bname = vim.api.nvim_buf_get_name(args.buf)
            if not bname:match("^zero://") then return end
            if not state.channel_id then return end
            local ft = args.match
            
            local user, host, port, path = M.parse_uri(bname)
            if not host or not path then return end
            
            local project_name, project_config = require("zero-nvim.project.manager").match_project(host, path)
            if not project_config or type(project_config.lsp) ~= "table" then return end

            for server_name, server_cfg in pairs(project_config.lsp) do
                if not server_cfg.filetypes then
                    logger(string.format("ZeroNvim: LSP %s is configured but missing 'filetypes' array, skipping auto-start", server_name), vim.log.levels.WARN)
                elseif vim.tbl_contains(server_cfg.filetypes, ft) then
                    local lsp_name = "zero-" .. server_name
                    logger(string.format("ZeroNvim: Checking auto-start for LSP %s (buffer %d, ft=%s)", lsp_name, args.buf, ft), vim.log.levels.DEBUG)
                    
                    local existing = vim.lsp.get_clients({ bufnr = args.buf, name = lsp_name })
                    if #existing == 0 then
                        state.lsp_starting = state.lsp_starting or {}
                        local root_dir = project_config.root and project_config.root:gsub("/+$", "") or vim.fs.dirname(path):gsub("/+$", "")
                        local start_key = lsp_name .. ":" .. root_dir
                        
                        if state.lsp_starting[start_key] then
                            logger(string.format("ZeroNvim: LSP %s for root %s is already starting, skipping duplicate trigger for buffer %d", lsp_name, root_dir, args.buf), vim.log.levels.DEBUG)
                        else
                            state.lsp_starting[start_key] = true
                            local cmd_args = server_cfg.cmd or { server_name, "--stdio" }
                            -- Schedule so we don't block FileType processing
                            local _buf = args.buf
                            local _proj = project_config
                            local _root = root_dir
                            logger(string.format("ZeroNvim: Auto-starting LSP %s for buffer %d", lsp_name, _buf), vim.log.levels.DEBUG)
                            vim.schedule(function()
                                if vim.api.nvim_buf_is_valid(_buf) then
                                    require("zero-nvim.lsp").start_lsp(
                                        _buf,
                                        vim.deepcopy(cmd_args),
                                        server_cfg.settings,
                                        { project_config = _proj, root_dir = _root }
                                    )
                                end
                                -- Clear the lock shortly after so future legitimate retries aren't blocked
                                vim.defer_fn(function()
                                    state.lsp_starting[start_key] = nil
                                end, 3000)
                            end)
                        end
                    else
                        logger(string.format("ZeroNvim: LSP %s already active for buffer %d", lsp_name, args.buf), vim.log.levels.DEBUG)
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
    do
        local _orig_readfile = vim.fn.readfile
        vim.fn.readfile = function(path, ...)
            if type(path) == "string" and path:match("^zero://") then
                local u, h, p, fpath = M.parse_uri(path)
                if u and state.channel_id then
                    local ok, res = pcall(vim.fn.rpcrequest, state.channel_id,
                        "fetch_path", u, h, p, fpath)
                    if ok and type(res) == "table" and res[1] == "file" and res[2] then
                        local lines = vim.split(res[2], "\n")
                        -- readfile() drops the trailing empty line that comes
                        -- from a final newline in the file.
                        if #lines > 0 and lines[#lines] == "" then
                            table.remove(lines)
                        end
                        return lines
                    end
                end
                return {}
            end
            return _orig_readfile(path, ...)
        end
    end

    -- Patch vim.lsp.buf_request_all to pre-load any zero:// buffers referenced
    -- in the LSP response. Third-party reference/preview plugins (e.g.
    -- code-view.nvim) call buf_request_all directly and then use io.open() on
    -- the URI string — io.open can't read zero://, but those plugins typically
    -- check for an already-loaded buffer with the same name first. By forcing
    -- bufadd+bufload before their handler runs, our BufReadCmd populates the
    -- buffer and they fall into that fast path.
    do
        local _orig_brall = vim.lsp.buf_request_all
        local jump_methods = {
            ["textDocument/definition"]     = true,
            ["textDocument/declaration"]    = true,
            ["textDocument/typeDefinition"] = true,
            ["textDocument/implementation"] = true,
            ["textDocument/references"]     = true,
        }
        vim.lsp.buf_request_all = function(bufnr, method, params, handler)
            if not jump_methods[method] or not state.channel_id then
                return _orig_brall(bufnr, method, params, handler)
            end
            return _orig_brall(bufnr, method, params, function(results, ctx)
                local seen = {}
                local function preload(loc)
                    if type(loc) ~= "table" then return end
                    local uri = loc.uri or loc.targetUri
                    if not uri or seen[uri] then return end
                    seen[uri] = true
                    if not uri:match("^zero://") or uri:match("/$") then return end
                    local u, h, p, fpath = M.parse_uri(uri)
                    if not u then return end
                    local b = vim.fn.bufnr(uri)
                    if b == -1 then b = vim.fn.bufadd(uri) end
                    if not vim.api.nvim_buf_is_loaded(b) then
                        pcall(vim.fn.bufload, b)
                    end
                    -- Defensive: even after bufadd → BufNew → BufReadCmd, the
                    -- buffer may still be empty (autocmd ordering, pcall'd
                    -- failures, etc.). Without content, third-party plugins
                    -- that read via nvim_buf_get_lines will see 1 empty line
                    -- and crash on out-of-range cursor moves. Force-fetch
                    -- here as a last resort — handle_fetch is idempotent.
                    local lc = vim.api.nvim_buf_line_count(b)
                    local has_content = lc > 1 or
                        (lc == 1 and vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] ~= "")
                    if not has_content then
                        pcall(M.handle_fetch, b, u, h, p, fpath)
                    end
                end
                for _, r in pairs(results or {}) do
                    local res = r and r.result
                    if type(res) == "table" then
                        if res.uri or res.targetUri then
                            preload(res)
                        else
                            for _, loc in ipairs(res) do preload(loc) end
                        end
                    end
                end
                return handler(results, ctx)
            end)
        end
    end

    -- Patch vim.lsp.util.locations_to_items to pre-load zero:// buffers before
    -- the LSP jump. This is the call site in buf.lua's on_response callback
    -- (vim.schedule context = no textlock). Accessed via table field lookup
    -- (util.locations_to_items), so our patch IS visible even when keybindings
    -- captured vim.lsp.buf.definition by reference before this patch ran.
    do
        local _orig_lti = vim.lsp.util.locations_to_items
        vim.lsp.util.locations_to_items = function(locations, offset_encoding)
            -- Batch processing of missing remote files
            local missing_files_by_host = {} -- structure: { ["user@host:port"] = { chan = id, paths = {}, buffers = {} } }
            
            for _, loc in ipairs(locations or {}) do
                local uri = loc.uri or loc.targetUri
                if uri and uri:match("^zero://") then
                    local u, h, p, fpath = M.parse_uri(uri)
                    if u and state.channel_id and not fpath:match("/$") then
                        local bnum = vim.fn.bufnr(uri)
                        if bnum == -1 then bnum = vim.fn.bufadd(uri) end
                        local lc = vim.api.nvim_buf_line_count(bnum)
                        local is_empty = (lc == 0) or
                            (lc == 1 and vim.api.nvim_buf_get_lines(bnum, 0, 1, false)[1] == "")
                            
                        if is_empty then
                            local host_key = string.format("%s@%s:%d", u, h, p)
                            if not missing_files_by_host[host_key] then
                                missing_files_by_host[host_key] = {
                                    user = u, host = h, port = p,
                                    paths = {}, bnums = {}
                                }
                            end
                            table.insert(missing_files_by_host[host_key].paths, fpath)
                            table.insert(missing_files_by_host[host_key].bnums, bnum)
                        end
                        
                        -- Auto-attach any running zero-* LSP client whose root_dir
                        -- covers this file. Clients started via start_lsp store the
                        -- project root in config.root_dir as a plain path.
                        logger("ZeroNvim: Checking auto-attach for buffer " .. bnum .. " (" .. fpath .. ")", vim.log.levels.DEBUG)
                        for _, client in ipairs(vim.lsp.get_clients()) do
                            if client.name:match("^zero%-") then
                                local croot = client.config and client.config.root_dir
                                if croot then
                                    croot = croot:gsub("/+$", "")
                                    if fpath == croot or fpath:find(croot .. "/", 1, true) == 1 then
                                        local already = vim.lsp.get_clients({ bufnr = bnum, id = client.id })
                                        if #already == 0 then
                                            logger(string.format("ZeroNvim: Auto-attaching LSP %s to buffer %d", client.name, bnum), vim.log.levels.DEBUG)
                                            vim.lsp.buf_attach_client(bnum, client.id)
                                        else
                                            logger(string.format("ZeroNvim: LSP %s already attached to buffer %d", client.name, bnum), vim.log.levels.DEBUG)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            
            -- Fetch missing files in batch per host
            for _, host_data in pairs(missing_files_by_host) do
                local chan, err = M.ensure_connection(host_data.user, host_data.host, host_data.port)
                if chan and #host_data.paths > 0 then
                    logger(string.format("ZeroNvim: Batch fetching %d files from %s:%d", #host_data.paths, host_data.host, host_data.port), vim.log.levels.DEBUG)
                    -- Sync call to fetch all in one roundtrip
                    local ok, content_map = pcall(vim.fn.rpcrequest, chan, "fetch_paths", host_data.user, host_data.host, host_data.port, host_data.paths)
                    if ok and type(content_map) == "table" then
                        for i, bnum in ipairs(host_data.bnums) do
                            local fpath = host_data.paths[i]
                            local content = content_map[fpath]
                            if content then
                                local lines = vim.split(content, "\n")
                                if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
                                vim.api.nvim_set_option_value('modifiable', true, { buf = bnum })
                                vim.api.nvim_buf_set_lines(bnum, 0, -1, false, lines)
                                vim.api.nvim_set_option_value('modified', false, { buf = bnum })
                                vim.api.nvim_set_option_value('buflisted', true, { buf = bnum })
                            end
                        end
                    else
                        logger("ZeroNvim: Batch fetch failed: " .. tostring(content_map), vim.log.levels.ERROR)
                    end
                end
            end

            -- Defensive cursor re-snap for single-location jumps to zero://
            -- buffers. Some adapters (notably oil.nvim's BufReadCmd flow)
            -- re-fetch and nvim_buf_set_lines(0, -1, ...) replace ALL lines
            -- AFTER the LSP framework set the cursor — Neovim then resets
            -- the cursor in displaying windows to (1,0). We pre-load via
            -- batch fetch above + the oil adapter has a fast-path skip,
            -- but keep this snap as a safety net for other clobbering paths.
            if #locations == 1 then
                local _loc = locations[1]
                local _uri = _loc.uri or _loc.targetUri
                local _range = _loc.range or _loc.targetSelectionRange
                if _uri and _uri:match("^zero://") and _range and _range.start then
                    local target_line = (_range.start.line or 0) + 1
                    local target_char = _range.start.character or 0
                    local target_bnum = vim.fn.bufnr(_uri)
                    if target_bnum > 0 then
                        vim.schedule(function()
                            for _, w in ipairs(vim.api.nvim_list_wins()) do
                                if vim.api.nvim_win_get_buf(w) == target_bnum then
                                    local cur = vim.api.nvim_win_get_cursor(w)
                                    if cur[1] ~= target_line then
                                        local lc = vim.api.nvim_buf_line_count(target_bnum)
                                        local lnum = math.min(target_line, math.max(1, lc))
                                        local line = vim.api.nvim_buf_get_lines(target_bnum, lnum - 1, lnum, false)[1] or ""
                                        local col = math.min(target_char, #line)
                                        pcall(vim.api.nvim_win_set_cursor, w, { lnum, col })
                                        vim._with({ win = w }, function() vim.cmd('normal! zv') end)
                                    end
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
    vim.api.nvim_create_user_command("ZeroLspStart", function(cmd_opts)
        local args = cmd_opts.fargs
        local server_bin = args[1]
        local settings = nil

        -- Lookup settings from project config
        local buf_name = vim.api.nvim_buf_get_name(0)
        local user, host, port, path = M.parse_uri(buf_name)
        if host and path then
            local project_name, project_config = require("zero-nvim.project.manager").match_project(host, path)
            if project_config and project_config.lsp then
                local s = project_config.lsp[server_bin]
                if s and s.settings then
                    settings = s.settings
                end
            end
        end

        require("zero-nvim.lsp").start_lsp(0, args, settings)
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
            local lsp_name = arg:match("^zero%-") and arg or ("zero-" .. arg)
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
        local project_name, project_config = manager.match_project(host, path)
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
    require("zero-nvim.gitsigns.backend").setup()
end

return M
