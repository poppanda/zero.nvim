local M = {}

-- 保存 Daemon 的 Job ID / Channel ID
local daemon_channel_id = nil
-- 记录已连接的主机: { ["user@host:port"] = true }
local connected_hosts = {}

-- 解析 URI: remote://user@host[:port]:/path/to/file
-- 返回: user, host, port (number or 22), path
local function parse_uri(uri)
    -- 尝试匹配带端口的格式: remote://user@host:port:/path
    local user, host, port_str, path = string.match(uri, "^remote://([^@]+)@([^:]+):(%d+):(.+)$")
    
    if user and host and port_str and path then
        return user, host, tonumber(port_str), path
    end

    -- 尝试匹配不带端口的格式: remote://user@host:/path
    user, host, path = string.match(uri, "^remote://([^@]+)@([^:]+):(.+)$")
    if user and host and path then
        return user, host, 22, path
    end

    return nil, nil, nil, nil
end

-- 启动 Daemon 进程
local function start_daemon()
    if daemon_channel_id then
        return daemon_channel_id
    end

    -- 查找 Daemon 二进制文件路径
    local bin_path = vim.fn.getcwd() .. "/daemon/target/debug/zero-nvim-daemon"
    if vim.fn.executable(bin_path) == 0 then
        -- 尝试在插件目录下查找
        local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1).source:sub(2))))
        bin_path = plugin_root .. "/daemon/target/debug/zero-nvim-daemon"
    end

    vim.notify("ZeroNvim: Looking for daemon at: " .. bin_path, vim.log.levels.INFO)

    if vim.fn.executable(bin_path) == 0 then
        vim.notify("ZeroNvim Daemon binary not found at: " .. bin_path, vim.log.levels.ERROR)
        return nil
    end

    vim.notify("Starting ZeroNvim Daemon...", vim.log.levels.INFO)
    daemon_channel_id = vim.fn.jobstart({ bin_path }, {
        rpc = true, -- 启用 Msgpack-RPC 通信
        on_exit = function(id, code, event)
            if code ~= 0 then
                vim.notify("ZeroNvim Daemon exited with code " .. code, vim.log.levels.WARN)
            else
                vim.notify("ZeroNvim Daemon exited normally", vim.log.levels.INFO)
            end
            daemon_channel_id = nil
            connected_hosts = {} -- 重置连接状态
        end,
        on_stderr = function(id, data, event)
            -- data 是一个字符串列表
            for _, line in ipairs(data) do
                if line ~= "" then
                    vim.notify("Daemon Stderr: " .. line, vim.log.levels.WARN)
                end
            end
        end,
    })

    if daemon_channel_id == 0 then
        vim.notify("ZeroNvim Daemon failed to start (invalid arguments)", vim.log.levels.ERROR)
        daemon_channel_id = nil
    elseif daemon_channel_id == -1 then
        vim.notify("ZeroNvim Daemon is not executable", vim.log.levels.ERROR)
        daemon_channel_id = nil
    else 
        vim.notify("ZeroNvim Daemon started with Channel ID: " .. daemon_channel_id, vim.log.levels.INFO)
    end

    return daemon_channel_id
end

-- 更新 Buffer 内容
local function update_buffer(buf, lines, remote_path)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value('modified', false, { buf = buf })
    vim.api.nvim_set_option_value('readonly', true, { buf = buf })
    local ft = vim.filetype.match({ filename = remote_path })
    if ft then
        vim.api.nvim_set_option_value('filetype', ft, { buf = buf })
    end
    vim.notify("File loaded: " .. remote_path, vim.log.levels.INFO)
end

-- 确保与远程主机建立连接
-- user: 用户名, host: 主机名, port: 端口, password: 密码 (可选)
-- 返回: success (bool), error_message (string/nil)
local function ensure_connection(user, host, port, password)
    local key = user .. "@" .. host .. ":" .. port
    
    if connected_hosts[key] then
        vim.notify("Already connected to " .. key, vim.log.levels.DEBUG)
        return true, nil
    end

    local chan = start_daemon()
    if not chan then
        return false, "Daemon not running"
    end

    vim.notify("Connecting to " .. key .. "...", vim.log.levels.INFO)
    -- 发送 RPC 请求: connect(user, host, port, password)
    -- 注意: 之前协议只有 (user, host, password)，现在增加 port
    -- 我们需要同步修改 daemon 端
    local ok, res = pcall(vim.fn.rpcrequest, chan, "connect", user, host, port, password)

    if not ok then
        return false, "RPC Call failed: " .. tostring(res)
    end
    
    connected_hosts[key] = true
    vim.notify("Connected to " .. key, vim.log.levels.INFO)
    return true, nil
end

-- 通过 Daemon 获取文件
local function fetch_remote_daemon(buf, user, host, port, remote_path)
    local chan = daemon_channel_id
    if not chan then return end

    vim.notify("Fetching " .. remote_path .. " via Daemon...", vim.log.levels.INFO)
    local ok, content = pcall(vim.fn.rpcrequest, chan, "fetch_file", user, host, port, remote_path)

    if not ok then
        vim.notify("Fetch failed: " .. tostring(content), vim.log.levels.ERROR)
        return
    end

    local lines = vim.split(content, "\n")
    if #lines > 0 and lines[#lines] == "" then
        table.remove(lines)
    end

    update_buffer(buf, lines, remote_path)
end

-- 处理连接与重试逻辑 (包含密码输入)
-- forward declaration
local handle_connect_and_fetch

handle_connect_and_fetch = function(buf, user, host, port, remote_path, password)
    local success, err = ensure_connection(user, host, port, password)
    
    if success then
        fetch_remote_daemon(buf, user, host, port, remote_path)
    else
        vim.notify("Connection failed: " .. tostring(err), vim.log.levels.WARN)
        -- 如果失败，判断是否是因为认证失败，如果是则提示输入密码
        if password then
             -- 已经试过密码了，彻底失败
            vim.notify("Authentication failed definitively.", vim.log.levels.ERROR)
        else
            -- 第一次尝试失败，提示输入密码
            vim.ui.input({ prompt = "SSH Password for " .. user .. "@" .. host .. ": ", secret = true }, function(input)
                if input then
                    vim.schedule(function()
                        handle_connect_and_fetch(buf, user, host, port, remote_path, input)
                    end)
                else
                    vim.notify("Connection aborted by user.", vim.log.levels.WARN)
                end
            end)
        end
    end
end

-- BufReadCmd 事件回调
local function handle_buf_read_cmd(args)
    vim.notify("ZeroNvim: BufReadCmd triggered for " .. args.file, vim.log.levels.INFO)
    local buf = args.buf
    local uri = args.file
    local user, host, port, remote_path = parse_uri(uri)

    if not user or not host or not remote_path then
        vim.notify("Invalid URI: " .. uri, vim.log.levels.ERROR)
        return
    end

    vim.api.nvim_set_option_value('buftype', 'acwrite', { buf = buf })
    vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

    vim.schedule(function()
        handle_connect_and_fetch(buf, user, host, port, remote_path, nil)
    end)
end

function M.setup()
    vim.notify("ZeroNvim: Plugin loaded", vim.log.levels.INFO)
    vim.api.nvim_create_autocmd("BufReadCmd", {
        pattern = "remote://*",
        callback = handle_buf_read_cmd,
        group = vim.api.nvim_create_augroup("ZeroNvim", { clear = true }),
    })
end

return M
