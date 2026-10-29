--- 打开远端路径 + :ZeroLink 流程（host 选择 → 目录浏览 → :edit）。
local uri = require("zero-nvim.uri")
local log = require("zero-nvim.log")
local remote = require("zero-nvim.remote")
local ssh_config = require("zero-nvim.ssh_config")

local M = {}

--- Open a remote path as a zero:// buffer. Relative paths and "~" are resolved
--- against the remote $HOME.
---@param user string
---@param host string
---@param port integer
---@param path string
function M.open_remote(user, host, port, path)
    if not path:match("^/") then
        local home = remote.remote_home(user, host, port) or ("/home/" .. user)
        path = home .. "/" .. path:gsub("^~", "")
    end
    path = uri.normalize_path(path)

    -- 问 daemon 而不是看扩展名：Makefile / Dockerfile / LICENSE 之类会被误判成目录
    local is_dir = path:match("/$") ~= nil
    if not is_dir then
        local ok, ftype = remote.request(user, host, port, "stat", path)
        is_dir = ok and ftype == "directory"
    end
    if is_dir then path = uri.as_dir(path) end

    vim.cmd("edit " .. vim.fn.fnameescape(uri.format(user, host, port, path)))

    -- 打开项目根目录时预热声明的 LSP，用户打开第一个匹配文件时就能直接 attach，
    -- 不用再等 ssh + LSP initialize。
    if is_dir then
        local _, project_config = require("zero-nvim.project.manager").match_project(host, path, user, port)
        if project_config and type(project_config.lsp) == "table" and next(project_config.lsp) then
            vim.schedule(function()
                require("zero-nvim.lsp").prewarm_lsps(user, host, port, project_config)
            end)
        end
    end
end

local function browse(user, host, port, display_name)
    require("zero-nvim.ui.browser").browse_path(user, host, port, function(p)
        M.open_remote(user, host, port, p)
    end, { display_name = display_name })
end

--- :ZeroLink [ssh_target] [path]
---   - 无参数：SSH host 选择器 → 目录浏览
---   - 只有 ssh_target：目录浏览
---   - ssh_target + path：直接打开
---@param args string[] fargs
function M.run(args)
    local target, path = args[1], args[2]

    if not target or target == "" then
        require("zero-nvim.ui.host_picker").pick_host(ssh_config.parse(), function(entry)
            browse(entry.user or ssh_config.default_user(), entry.hostname or entry.host, entry.port or 22, entry.host)
        end)
        return
    end

    local resolved = ssh_config.resolve(target)
    if not resolved then
        log.error("Cannot resolve SSH target: " .. target)
        return
    end
    if path and path ~= "" then
        M.open_remote(resolved.user, resolved.hostname, resolved.port, path)
    else
        browse(resolved.user, resolved.hostname, resolved.port, target)
    end
end

return M
