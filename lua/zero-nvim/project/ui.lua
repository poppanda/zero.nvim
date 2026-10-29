--- :ZeroProject 的项目列表 / 新增 / 健康检查浮窗。
local manager = require("zero-nvim.project.manager")
local float = require("zero-nvim.ui.float")
local remote = require("zero-nvim.remote")
local uri = require("zero-nvim.uri")
local log = require("zero-nvim.log")
local ssh_config = require("zero-nvim.ssh_config")

local M = {}

--- 老配置可能没存 user/port：回落到默认用户 / 22
local function with_target_defaults(config)
    return vim.tbl_extend("keep", config, { user = ssh_config.default_user(), port = uri.DEFAULT_PORT })
end

--- Add a project based on a specific buffer's path
---@param bufnr? integer Buffer number to derive remote path from (defaults to current)
---@param on_complete? fun() Callback after successful addition
function M.add_current_project(bufnr, on_complete)
    bufnr = bufnr or 0
    local buf_name = vim.api.nvim_buf_get_name(bufnr)
    local user, host, port, path = uri.parse(buf_name)
    if not user then
        log.warn("target buffer is not a zero:// buffer")
        return
    end

    -- Project root is always a directory: for a file buffer use its parent.
    local is_dir = path:sub(-1) == "/" or vim.b[bufnr].zero_is_dir == true
    local root = is_dir and uri.as_dir(path) or uri.parent_dir(path)

    -- Default project name is the folder name（根目录 "/" 时为 "/"）
    local default_name = vim.fs.basename(manager.norm_root(root))
    if default_name == "" then default_name = "/" end

    float.prompt({ title = "Project Name", default = default_name }, function(name)
        manager.add(name, { host = host, user = user, port = port, root = root })
        if on_complete then on_complete() end
    end)
end

--- Show the project picker
function M.show_project_picker()
    -- Capture the context buffer
    local context_buf = vim.api.nvim_get_current_buf()

    local projects = manager.list()
    local names = vim.tbl_keys(projects)
    table.sort(names)

    local display_lines = {}
    local max_width = 40

    if #names == 0 then
        table.insert(display_lines, "  <No projects found>")
        max_width = 30
    else
        for _, name in ipairs(names) do
            local config = projects[name]
            -- Format: [name] host:root
            local line = string.format(" %-20s  %s:%s", name, tostring(config.host), tostring(config.root))
            table.insert(display_lines, line)
            max_width = math.max(max_width, #line + 4)
        end
    end

    local final_width = math.min(max_width, 100)
    -- 高度 10..20 行
    local win_height = math.min(math.max(#names, 10), 20)

    local buf, win = float.create({
        title = "Zero Projects",
        footer = "<CR>:Open | <C-a>:Add | <C-e>:Edit | <C-d>:Del | <C-l>:Add LSP | <C-h>:Check",
        width = final_width,
        height = win_height,
    })

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })

    local function get_selected_name()
        return names[vim.api.nvim_win_get_cursor(win)[1]]
    end

    local function close()
        float.close(win, buf)
    end

    local function refresh()
        close()
        vim.schedule(M.show_project_picker)
    end

    -- Action: Open
    vim.keymap.set("n", "<CR>", function()
        local name = get_selected_name()
        if name then
            local config = projects[name]
            close()
            if type(config.root) ~= "string" then
                log.error("project '" .. name .. "' has no root directory configured")
                return
            end
            config = with_target_defaults(config)
            require("zero-nvim.link").open_remote(config.user, config.host, config.port, config.root)
        end
    end, { buffer = buf, silent = true })

    -- Action: Add (Current Buffer)
    vim.keymap.set("n", "<C-a>", function()
        -- 不先关 picker：名字输入框直接叠在上面，保存后重开列表刷新
        M.add_current_project(context_buf, refresh)
    end, { buffer = buf, silent = true })

    -- Action: Edit
    vim.keymap.set("n", "<C-e>", function()
        local name = get_selected_name()
        if name then
            close()
            float.edit_json(name, projects[name], function(new_config)
                manager.add(name, new_config)
                refresh()
            end)
        end
    end, { buffer = buf, silent = true })

    -- Action: Delete
    vim.keymap.set("n", "<C-d>", function()
        local name = get_selected_name()
        if name then
            vim.ui.select({ "Yes", "No" }, { prompt = "Delete project '" .. name .. "'?" }, function(choice)
                if choice == "Yes" then
                    manager.remove(name)
                    refresh()
                end
            end)
        end
    end, { buffer = buf, silent = true })

    -- Action: Add LSP via wizard
    vim.keymap.set("n", "<C-l>", function()
        local name = get_selected_name()
        if not name then return end
        local config = with_target_defaults(projects[name])
        close()
        require("zero-nvim.lsp.add_wizard").open({
            user = config.user,
            host = config.host,
            port = config.port,
            project_name = name,
            project_config = config,
        })
    end, { buffer = buf, silent = true })

    -- Action: Health Check
    vim.keymap.set("n", "<C-h>", function()
        local name = get_selected_name()
        if name then
            M.check_health(name)
        end
    end, { buffer = buf, silent = true })

    vim.keymap.set("n", "q", close, { buffer = buf, silent = true })
    vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true })
end

--- Open a health check window with initial lines
---@param name string Project name
---@param lines string[] Initial lines
---@return integer buf, integer win, function update_line
local function open_health_window(name, lines)
    local buf, win = float.create({
        title = "Health Check: " .. name,
        width = 60,
        height = math.max(#lines + 2, 5),
    })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })

    local close = function() float.close(win, buf) end
    vim.keymap.set("n", "q", close, { buffer = buf })
    vim.keymap.set("n", "<Esc>", close, { buffer = buf })

    --- Update a specific line (1-based index)
    local function update_line(idx, text)
        if not vim.api.nvim_buf_is_valid(buf) then return end
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, idx - 1, idx, false, { text })
        vim.bo[buf].modifiable = false
    end

    return buf, win, update_line
end

--- Run health check for a project
---@param project_name_or_args string
function M.check_health(project_name_or_args)
    local name = project_name_or_args
    if not name or name == "" then
        log.warn("please specify a project name")
        return
    end

    local config = manager.get(name)
    if not config then
        log.error("project not found: " .. name)
        return
    end
    config = with_target_defaults(config)

    -- Prepare initial checklist
    local checklist = {
        { label = "SSH Connection (" .. config.host .. ")" },
        { label = "Root Directory (" .. tostring(config.root) .. ")" },
    }

    if config.lsp then
        for srv_name, _ in pairs(config.lsp) do
            table.insert(checklist, { label = "LSP (" .. srv_name .. ")", server = srv_name })
        end
    else
        table.insert(checklist, { label = "LSP Configuration", skip = true })
    end

    -- Convert to display lines
    local lines = {}
    for _, item in ipairs(checklist) do
        table.insert(lines, (item.skip and "[-] " or "[ ] ") .. item.label)
    end

    -- Open window immediately
    local _, _, update_line = open_health_window(name, lines)

    -- Run checks asynchronously
    vim.schedule(function()
        -- 1. SSH Check
        local idx = 1
        update_line(idx, "[●] " .. checklist[idx].label .. " (Connecting...)")

        -- ensure_connection 是阻塞的 RPC：先 redraw 让 "Connecting..." 显示出来
        vim.cmd("redraw")

        local chan, err = remote.ensure_connection(config.user, config.host, config.port)
        if not chan then
            update_line(idx, "[x] " .. checklist[idx].label .. ": Failed (" .. (err or "Unknown") .. ")")
            return -- Stop if SSH fails
        end
        update_line(idx, "[✓] " .. checklist[idx].label)

        -- 2. Root Dir Check
        idx = 2
        update_line(idx, "[●] " .. checklist[idx].label .. " (Checking...)")
        vim.cmd("redraw")
        local ok, ftype = remote.request(config.user, config.host, config.port, "stat", config.root)
        if ok and ftype == "directory" then
            update_line(idx, "[✓] " .. checklist[idx].label)
        else
            update_line(idx, "[x] " .. checklist[idx].label .. ": Not accessible")
        end

        -- 3. LSP Checks (checklist[3..])
        local lsp = require("zero-nvim.lsp")
        for i = 3, #checklist do
            local item = checklist[i]
            if item.server then
                local cmd_args = lsp.server_cmd(item.server, config.lsp[item.server])

                update_line(i, "[●] " .. item.label .. " (Checking ssh + binary...)")
                vim.cmd("redraw")
                local lsp_ok, lsp_err = lsp.preflight(config.user, config.host, config.port, cmd_args)
                if lsp_ok then
                    update_line(i, "[✓] " .. item.label .. " (" .. table.concat(cmd_args, " ") .. ")")
                else
                    update_line(i, "[x] " .. item.label .. ": " .. tostring(lsp_err))
                end
            end
        end
    end)
end

return M
