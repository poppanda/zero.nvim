local M = {}

-- 解析 URI: remote://user@host:/path/to/file
-- 返回: user, host, path
local function parse_uri(uri)
    -- 匹配 user@host:path 格式
    local pattern = "^remote://([^@]+)@([^:]+):(.+)$"
    local user, host, path = string.match(uri, pattern)
    return user, host, path
end

-- 生成用于 SSH 密码输入的辅助脚本 (SSH_ASKPASS)
-- SSH 默认不支持直接通过管道或参数传递密码，需要设置 SSH_ASKPASS 环境变量指向一个可执行脚本
-- 该脚本负责输出密码到 stdout
local function get_askpass_script()
    local uv = vim.uv or vim.loop
    local path = vim.fn.stdpath("cache") .. "/zero_nvim_askpass.sh"
    local stat = uv.fs_stat(path)

    -- 如果脚本不存在，则创建它
    if not stat then
        local f = io.open(path, "w")
        if f then
            f:write("#!/bin/sh\n")
            -- $ZERO_NVIM_PASSWORD 是我们在调用 ssh 时设置的环境变量
            f:write("echo \"$ZERO_NVIM_PASSWORD\"\n")
            f:close()
            -- 设置执行权限 (rwxr-xr-x)
            uv.fs_chmod(path, 493) -- 0755
        end
    end
    return path
end

-- 更新 Buffer 内容并设置相关选项
local function update_buffer(buf, lines, remote_path)
    if not vim.api.nvim_buf_is_valid(buf) then return end

    -- 临时允许修改以写入内容
    vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    -- 标记为未修改且只读 (Milestone 1 要求只读 VFS)
    -- 这样用户试图修改时会提示警告，且关闭 buffer 时不会提示保存
    vim.api.nvim_set_option_value('modified', false, { buf = buf })
    vim.api.nvim_set_option_value('readonly', true, { buf = buf })

    -- 尝试检测文件类型，以便应用语法高亮
    local ft = vim.filetype.match({ filename = remote_path })
    if ft then
        vim.api.nvim_set_option_value('filetype', ft, { buf = buf })
    end

    vim.notify("File loaded: " .. remote_path, vim.log.levels.INFO)
end

-- 处理 SSH 命令执行失败的情况
local function handle_error(buf, cmd, obj)
    local error_msg = string.format(
        "Remote fetch failed!\nCmd: %s\nCode: %d\nStderr: %s\nStdout: %s",
        table.concat(cmd, " "),
        obj.code,
        obj.stderr,
        obj.stdout
    )
    vim.notify(error_msg, vim.log.levels.ERROR)
    -- 即使失败也允许修改，方便用户查看错误或重试（虽然目前没有重试机制）
    vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
end

-- 执行远程抓取逻辑 (核心 SSH 处理函数)
-- buf: Neovim buffer ID
-- user, host, remote_path: 连接信息
-- password: 第一次尝试时为 nil，失败后重试时传入用户输入的密码
local function fetch_remote(buf, user, host, remote_path, password)
    local cmd = { 'ssh' }
    local env = nil

    if password then
        -- 如果提供了密码，说明是重试阶段，配置 ASKPASS 机制
        local askpass = get_askpass_script()
        local uv = vim.uv or vim.loop
        env = uv.os_environ()

        -- 设置环境变量供 askpass 脚本读取
        env["ZERO_NVIM_PASSWORD"] = password
        env["SSH_ASKPASS"] = askpass
        -- 强制 SSH 使用 askpass 程序，即使在没有 X11 的环境下
        env["SSH_ASKPASS_REQUIRE"] = "force"
        -- 设置 DISPLAY 变量通常是触发 GUI askpass 的必要条件，这里设为 dummy
        env["DISPLAY"] = "dummy:0"

        -- 再次尝试时，不再使用 BatchMode，因为我们需要 askpass 介入
        table.insert(cmd, '-o')
        table.insert(cmd, 'ConnectTimeout=5')
    else
        -- 第一次尝试：优先使用公钥验证
        -- BatchMode=yes 禁止交互式输入密码，如果公钥验证失败会立即返回错误
        table.insert(cmd, '-o')
        table.insert(cmd, 'BatchMode=yes')
        table.insert(cmd, '-o')
        table.insert(cmd, 'ConnectTimeout=5')
    end

    table.insert(cmd, user .. '@' .. host)
    -- 使用 cat 命令读取远程文件内容
    table.insert(cmd, 'cat ' .. remote_path)

    vim.notify("ZeroNvim: Executing SSH command: " .. table.concat(cmd, " "), vim.log.levels.INFO)

    -- 异步执行 SSH 命令
    vim.system(cmd, { text = true, env = env }, function(obj)
        if obj.code == 0 then
            -- 成功：分割输出并更新 Buffer
            local lines = vim.split(obj.stdout, "\n")
            -- 移除 split 导致的末尾空行（通常 cat 输出最后会有一个换行，split 会产生一个空字符串）
            if #lines > 0 and lines[#lines] == "" then
                table.remove(lines)
            end

            -- 回到主线程更新 UI
            vim.schedule(function()
                update_buffer(buf, lines, remote_path)
            end)
        else
            -- 失败处理逻辑
            -- code 255 是 SSH 的常规错误退出码
            -- 如果当前没有提供密码 (第一次尝试)，且 SSH 返回错误，则尝试请求密码
            if not password and obj.code == 255 then
                vim.schedule(function()
                    -- 使用 vim.ui.input 获取用户输入 (支持 Noice 等 UI 插件)
                    vim.ui.input({ prompt = "SSH Password/Passphrase: ", secret = true }, function(input)
                        if input then
                            -- 用户输入了密码，递归调用 fetch_remote 进行重试
                            fetch_remote(buf, user, host, remote_path, input)
                        else
                            -- 用户取消输入
                            handle_error(buf, cmd, obj)
                        end
                    end)
                end)
                return
            end

            -- 如果已经提供了密码依然失败，或者其他错误，则报错
            vim.schedule(function()
                handle_error(buf, cmd, obj)
            end)
        end
    end)
end

-- BufReadCmd 事件回调：当打开 remote://... 时触发
local function handle_buf_read_cmd(args)
    vim.notify("ZeroNvim: BufReadCmd triggered for " .. args.file, vim.log.levels.INFO)
    local buf = args.buf
    local uri = args.file
    local user, host, remote_path = parse_uri(uri)

    -- 校验 URI 格式
    if not user or not host or not remote_path then
        vim.notify("Invalid remote URI format. Expected: remote://user@host:/path/to/file\nGot: " .. uri,
            vim.log.levels.ERROR)
        return
    end

    -- 设置 Buffer 状态：加载中禁止修改，类型为 acwrite (允许通过 BufWriteCmd 写入，虽然目前只读)
    vim.api.nvim_set_option_value('buftype', 'acwrite', { buf = buf })
    vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

    vim.notify(string.format("Fetching %s from %s...", remote_path, host), vim.log.levels.INFO)

    -- 开始获取远程文件，初始密码为 nil
    fetch_remote(buf, user, host, remote_path, nil)
end

function M.setup()
    vim.notify("ZeroNvim: Setup initialized", vim.log.levels.INFO)
    -- 注册自动命令：拦截 remote:// 开头的 buffer 读取操作
    vim.api.nvim_create_autocmd("BufReadCmd", {
        pattern = "remote://*",
        callback = handle_buf_read_cmd,
        group = vim.api.nvim_create_augroup("ZeroNvim", { clear = true }),
    })
end

return M
