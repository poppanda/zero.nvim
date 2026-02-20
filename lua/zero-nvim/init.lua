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
}

local options = {}

local function logger(msg, level)
    level = level or vim.log.levels.INFO
    if level >= options.log.level then
        vim.notify(options.log.prefix .. msg, level)
    end
end

function M.parse_uri(uri)
    local user, host, port_str, path = string.match(uri, "^remote://([^@]+)@([^:]+):(%d+):(.+)$")
    if user and host and port_str and path then
        return user, host, tonumber(port_str), path
    end
    user, host, path = string.match(uri, "^remote://([^@]+)@([^:]+):(.+)$")
    if user and host and path then
        return user, host, 22, path
    end
    return nil
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
    end
    return chan
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
        local uri = string.format("remote://%s@%s:%d:%s", user, host, port, new_path)
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
        -- 核心改进：只有明确包含 AUTH_FAILED 字样才弹窗
        if not password and err:match("AUTH_FAILED") then
            vim.ui.input({ prompt = "SSH Password: ", secret = true }, function(input)
                if input then
                    vim.schedule(function() M.handle_fetch(buf, user, host, port, path, input) end)
                end
            end)
            return
        end
        -- 其他错误（如 Banner 失败，SFTP 不支持等）直接报错
        logger("Connection failed: " .. err, vim.log.levels.ERROR)
        return
    end

    local ok_stat, ftype = pcall(vim.fn.rpcrequest, chan, "stat", user, host, port, path)
    if not ok_stat then
        logger("Access failed: " .. tostring(ftype), vim.log.levels.ERROR)
        return
    end

    if ftype == "directory" then
        if options.explorer == "oil" then
            local oil_uri = string.format("oil-zero://%s@%s:%d%s", user, host, port, path)
            -- 在跳转 Oil 之前，显式将 remote:// buffer 标记为已成功完成（虽然我们要跳走）
            -- 这样可以防止某些 autocommands 触发
            vim.api.nvim_buf_delete(buf, { force = true })
            vim.cmd("edit " .. oil_uri)
            return
        end
        local entries = M.get_entries(user, host, port, path)
        if entries then setup_dir_buffer(buf, user, host, port, path, entries) end
    else
        local content = M.get_file_content(user, host, port, path)
        if content then
            local lines = vim.split(content, "\n")
            if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
            vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            vim.api.nvim_set_option_value('modified', false, { buf = buf })
            vim.api.nvim_set_option_value('readonly', true, { buf = buf })
            local ft = vim.filetype.match({ filename = path })
            if ft then vim.api.nvim_set_option_value('filetype', ft, { buf = buf }) end
        end
    end
end

--- Open a remote:// URI given resolved connection params and path.
---@param user string
---@param host string
---@param port integer
---@param path string
local function open_remote(user, host, port, path)
    -- Ensure path starts with /
    if not path:match("^/") then
        -- Expand ~ to /home/user
        if path:match("^~") then
            path = path:gsub("^~", "/home/" .. user)
        else
            path = "/home/" .. user .. "/" .. path
        end
    end

    -- Determine if this is a directory path (ends with / or has no extension)
    local is_dir = path:match("/$") or not path:match("%.[^/]+$")

    if is_dir then
        -- Ensure trailing slash for oil
        if not path:match("/$") then path = path .. "/" end
        -- oil-zero://user@host:port/path
        local uri = string.format("oil-zero://%s@%s:%d%s", user, host, port, path)
        vim.cmd("edit " .. uri)
    else
        -- remote://user@host:port:path (for files)
        local uri = string.format("remote://%s@%s:%d:%s", user, host, port, path)
        vim.cmd("edit " .. uri)
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
                open_remote(user, hostname, port, p)
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
        open_remote(user, hostname, port, path)
        return
    end

    -- Case 2: Only target, no path → browse remote directories
    ui.browse_path(user, hostname, port, function(p)
        open_remote(user, hostname, port, p)
    end, { display_name = target })
end

function M.setup(opts)
    options = vim.tbl_deep_extend("force", defaults, opts or {})

    local group = vim.api.nvim_create_augroup("ZeroNvim", { clear = true })

    vim.api.nvim_create_autocmd("BufReadCmd", {
        pattern = "remote://*",
        callback = function(args)
            local user, host, port, path = M.parse_uri(args.file)
            if user then vim.schedule(function() M.handle_fetch(args.buf, user, host, port, path) end) end
        end,
        group = group,
    })

    -- [NEW] Phase 2: Write support
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        pattern = "remote://*",
        callback = function(args)
            local user, host, port, path = M.parse_uri(args.file)
            if not user then return end

            local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
            local content = table.concat(lines, "\n")
            -- Ensure trailing newline if file is not empty (standard Unix behavior)
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

    -- [NEW] Register :ZeroSearch user command
    vim.api.nvim_create_user_command("ZeroSearch", function(cmd_opts)
        require("zero-nvim.search").live_grep()
    end, {
        nargs = 0,
        desc = "Search remote server using Telescope",
    })
end

return M
