local M = {}

-- 解析 URI: remote://user@host:/path/to/file
-- 返回: user, host, path
local function parse_uri(uri)
  local pattern = "^remote://([^@]+)@([^:]+):(.+)$"
  local user, host, path = string.match(uri, pattern)
  return user, host, path
end

local function handle_buf_read_cmd(args)
  vim.notify("ZeroNvim: BufReadCmd triggered for " .. args.file, vim.log.levels.INFO)
  local buf = args.buf
  local uri = args.file
  local user, host, remote_path = parse_uri(uri)

  if not user or not host or not remote_path then
    vim.notify("Invalid remote URI format. Expected: remote://user@host:/path/to/file\nGot: " .. uri,
      vim.log.levels.ERROR)
    return
  end

  -- 设置 Buffer 状态：加载中禁止修改
  vim.api.nvim_set_option_value('buftype', 'acwrite', { buf = buf })
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  vim.notify(string.format("Fetching %s from %s...", remote_path, host), vim.log.levels.INFO)

  -- 构造 SSH 命令
  -- -o BatchMode=yes: 禁止交互式密码输入，连接失败直接报错
  -- -o ConnectTimeout=5: 设置超时时间
  local cmd = { 'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', user .. '@' .. host, 'cat ' .. remote_path }

  -- 打印调试信息，方便在 :messages 中查看实际执行的命令
  vim.notify("ZeroNvim: Executing SSH command: " .. table.concat(cmd, " "), vim.log.levels.INFO)

  -- 使用 vim.system (Neovim 0.10+)
  vim.system(cmd, { text = true }, function(obj)
    if obj.code ~= 0 then
      vim.schedule(function()
        local error_msg = string.format(
          "Remote fetch failed!\nCmd: %s\nCode: %d\nStderr: %s\nStdout: %s",
          table.concat(cmd, " "),
          obj.code,
          obj.stderr,
          obj.stdout
        )
        vim.notify(error_msg, vim.log.levels.ERROR)

        -- 允许修改以便用户处理错误
        vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
      end)
      return
    end

    local lines = vim.split(obj.stdout, "\n")
    -- 移除 split 导致的末尾空行（如果在文件末尾没有多余换行的话）
    if #lines > 0 and lines[#lines] == "" then
      table.remove(lines)
    end

    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then return end

      -- 允许写入内容
      vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

      -- 标记为未修改且只读 (Milestone 1 要求只读 VFS)
      vim.api.nvim_set_option_value('modified', false, { buf = buf })
      vim.api.nvim_set_option_value('readonly', true, { buf = buf })

      -- 尝试检测文件类型
      local ft = vim.filetype.match({ filename = remote_path })
      if ft then
        vim.api.nvim_set_option_value('filetype', ft, { buf = buf })
      end

      vim.notify("File loaded: " .. remote_path, vim.log.levels.INFO)
    end)
  end)
end

function M.setup()
  vim.notify("ZeroNvim: Setup initialized", vim.log.levels.INFO)
  vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern = "remote://*",
    callback = handle_buf_read_cmd,
    group = vim.api.nvim_create_augroup("ZeroNvim", { clear = true }),
  })
end

return M
