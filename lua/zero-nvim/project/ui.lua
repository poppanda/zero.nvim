local M = {}
local manager = require("zero-nvim.project.manager")
local utils = require("zero-nvim.ui.utils")
local zero = require("zero-nvim")

--- Show a floating input prompt
---@param opts { title: string, default?: string }
---@param on_confirm fun(text: string)
local function prompt_float(opts, on_confirm)
    local width = 40
    local height = 1
    local buf, win = utils.create_float({
        title = opts.title,
        width = width,
        height = height,
        footer = "<Enter>: Confirm"
    })
    
    if opts.default then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { opts.default })
    end

    local function confirm()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
        local text = vim.trim(lines[1] or "")
        utils.close_float(win, buf)
        vim.cmd("stopinsert")
        if text ~= "" then
            on_confirm(text)
        end
    end

    local function close()
        utils.close_float(win, buf)
        vim.cmd("stopinsert")
    end

    vim.keymap.set("i", "<CR>", confirm, { buffer = buf })
    vim.keymap.set("n", "<CR>", confirm, { buffer = buf })
    vim.keymap.set("n", "<Esc>", close, { buffer = buf })
    vim.keymap.set("i", "<Esc>", close, { buffer = buf })
    vim.keymap.set("n", "q", close, { buffer = buf })

    vim.cmd("startinsert")
    -- Ensure cursor is at end of line
    if opts.default then
        vim.api.nvim_win_set_cursor(win, {1, #opts.default})
    end
end

--- Add a project based on a specific buffer's path
---@param bufnr? integer Buffer number to derive remote path from (defaults to current)
---@param on_complete? fun() Callback after successful addition
function M.add_current_project(bufnr, on_complete)
    bufnr = bufnr or 0
    local buf_name = vim.api.nvim_buf_get_name(bufnr)
    local user, host, port, path = zero.parse_uri(buf_name)

    if not user then
        vim.notify("Target buffer is not a remote:// or oil-zero:// buffer.", vim.log.levels.WARN)
        return
    end

    -- Default project name is the folder name
    local clean_path = path:gsub("/+$", "")
    if clean_path == "" then clean_path = "/" end
    local default_name = vim.fs.basename(clean_path)

    -- Use custom prompt float instead of vim.ui.input for consistency
    prompt_float({ title = "Project Name", default = default_name }, function(name)
        local config = {
            host = host,
            user = user,
            port = port,
            root = path,
            created_at = os.time(),
        }
        manager.add(name, config)
        if on_complete then on_complete() end
    end)
end

--- Edit project config (JSON) in a floating window
---@param name string
---@param current_config table
---@param on_save fun(new_config: table)
local function edit_project_config(name, current_config, on_save)
    local content = vim.split(vim.json.encode(current_config), "\n")
    
    local buf, win = utils.create_float({ title = "Edit Config: " .. name, width = 80, height = 20 })
    
    -- Set buffer name and type for correct write behavior
    -- Use a simple name to avoid special character issues
    local buf_name = string.format("zero-project-%s.json", name)
    pcall(vim.api.nvim_buf_set_name, buf, buf_name)
    
    vim.api.nvim_set_option_value("buftype", "acwrite", { buf = buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
    
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    vim.api.nvim_set_option_value("filetype", "json", { buf = buf })
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    
    vim.notify("Edit config and write (:w) to save. Close window to cancel.", vim.log.levels.INFO)

    -- Auto-save on write
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function()
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            local json_str = table.concat(lines, "\n")
            local ok, new_config = pcall(vim.json.decode, json_str)
            if not ok then
                vim.notify("Invalid JSON: " .. tostring(new_config), vim.log.levels.ERROR)
                return
            end
            
            on_save(new_config)
            vim.api.nvim_set_option_value("modified", false, { buf = buf })
            utils.close_float(win, buf)
        end,
    })
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
            local line = string.format(" %-20s  %s:%s", name, config.host, config.root)
            table.insert(display_lines, line)
            max_width = math.max(max_width, #line + 4)
        end
    end

    local final_width = math.min(max_width, 100)
    -- [Fixed] Minimum height 10, Maximum 20
    local win_height = math.min(math.max(#names, 10), 20)

    local buf, win = utils.create_float({
        title = "Zero Projects",
        footer = "<CR>:Open | <C-a>:Add | <C-e>:Edit | <C-d>:Del | <C-h>:Check",
        width = final_width,
        height = win_height,
    })

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })

    local function get_selected_name()
        if #names == 0 then return nil end
        local cursor = vim.api.nvim_win_get_cursor(win)
        local idx = cursor[1]
        if idx >= 1 and idx <= #names then
            return names[idx]
        end
        return nil
    end

    local function close()
        utils.close_float(win, buf)
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
            zero.open_remote(config.user, config.host, config.port, config.root)
        end
    end, { buffer = buf, silent = true })

    -- Action: Add (Current Buffer)
    vim.keymap.set("n", "<C-a>", function()
        -- [Fixed] Do NOT close the picker first.
        -- Just invoke add_current_project which will spawn the prompt float on top.
        M.add_current_project(context_buf, function()
            -- Refresh the list by re-opening (simple way to redraw)
            refresh()
        end)
    end, { buffer = buf, silent = true })

    -- Action: Edit
    vim.keymap.set("n", "<C-e>", function()
        local name = get_selected_name()
        if name then
            close()
            edit_project_config(name, projects[name], function(new_config)
                manager.add(name, new_config)
                refresh()
            end)
        end
    end, { buffer = buf, silent = true })

    -- Action: Delete
    vim.keymap.set("n", "<C-d>", function()
        local name = get_selected_name()
        if name then
            vim.ui.select({"Yes", "No"}, { prompt = "Delete project '" .. name .. "'?" }, function(choice)
                if choice == "Yes" then
                    manager.remove(name)
                    refresh()
                end
            end)
        end
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
    local buf, win = utils.create_float({
        title = "Health Check: " .. name,
        width = 60,
        height = math.max(#lines + 2, 5),
    })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    
    local close = function() utils.close_float(win, buf) end
    vim.keymap.set("n", "q", close, { buffer = buf })
    vim.keymap.set("n", "<Esc>", close, { buffer = buf })

    --- Update a specific line (1-based index)
    local function update_line(idx, text)
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
            vim.api.nvim_buf_set_lines(buf, idx - 1, idx, false, { text })
            vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
        end
    end

    return buf, win, update_line
end

--- Run health check for a project
---@param project_name_or_args string
function M.check_health(project_name_or_args)
    local name = project_name_or_args
    if not name or name == "" then
        vim.notify("Please specify a project name.", vim.log.levels.WARN)
        return
    end

    local config = manager.get(name)
    if not config then
        vim.notify("Project not found: " .. name, vim.log.levels.ERROR)
        return
    end

    -- Prepare initial checklist
    local checklist = {
        { label = "SSH Connection (" .. config.host .. ")", key = "ssh" },
        { label = "Root Directory (" .. config.root .. ")", key = "root" },
    }
    
    if config.lsp then
        for srv_name, _ in pairs(config.lsp) do
            table.insert(checklist, { label = "LSP (" .. srv_name .. ")", key = "lsp_" .. srv_name })
        end
    else
        table.insert(checklist, { label = "LSP Configuration", key = "lsp_none", status = "SKIP" })
    end

    -- Convert to display lines
    local lines = {}
    for _, item in ipairs(checklist) do
        local prefix = (item.status == "SKIP") and "[-] " or "[ ] "
        table.insert(lines, prefix .. item.label)
    end

    -- Open window immediately
    local _, _, update_line = open_health_window(name, lines)

    -- Run checks asynchronously
    vim.schedule(function()
        -- 1. SSH Check
        local idx = 1
        update_line(idx, "[●] " .. checklist[idx].label .. " (Connecting...)")
        
        -- Need to use defer or just rely on the blocking ensure_connection?
        -- ensure_connection is unfortunately blocking on the RPC part in some implementations, 
        -- but here it sends 'connect' request.
        -- To make UI update visible, we might need to yield.
        -- But Lua is single threaded. 
        -- However, since ensure_connection might take time, we want to at least show the "Connecting..." state.
        -- We force a redraw?
        vim.cmd("redraw")

        local chan, err = zero.ensure_connection(config.user, config.host, config.port)
        if not chan then
            update_line(idx, "[x] " .. checklist[idx].label .. ": Failed (" .. (err or "Unknown") .. ")")
            return -- Stop if SSH fails
        end
        update_line(idx, "[✓] " .. checklist[idx].label)
        
        -- 2. Root Dir Check
        idx = 2
        update_line(idx, "[●] " .. checklist[idx].label .. " (Checking...)")
        vim.cmd("redraw")
        local ok, ftype = pcall(vim.fn.rpcrequest, chan, "stat", config.user, config.host, config.port, config.root)
        if ok and ftype == "directory" then
             update_line(idx, "[✓] " .. checklist[idx].label)
        else
             update_line(idx, "[x] " .. checklist[idx].label .. ": Not accessible")
        end

        -- 3. LSP Checks
        -- Offset for LSP items
        for i = 3, #checklist do
            local item = checklist[i]
            if item.status ~= "SKIP" then
                update_line(i, "[●] " .. item.label .. " (Checking config...)")
                vim.cmd("redraw")
                -- Simulation delay or actual check
                update_line(i, "[?] " .. item.label .. ": Configured (Binary check pending)")
            end
        end
    end)
end

return M
