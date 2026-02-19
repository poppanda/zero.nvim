--- Floating window UI components for zero-nvim ZeroLink
--- Provides SSH host picker and path input windows.

local M = {}

--- Create a centered floating window
---@param opts { title?: string, width?: number, height?: number }
---@return integer buf, integer win
local function create_float(opts)
    opts = opts or {}
    local width = opts.width or 60
    local height = opts.height or 15
    local ui = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }
    local row = math.floor((ui.height - height) / 2)
    local col = math.floor((ui.width - width) / 2)

    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = opts.title and (" " .. opts.title .. " ") or nil,
        title_pos = opts.title and "center" or nil,
        footer = opts.footer and (" " .. opts.footer .. " ") or nil,
        footer_pos = opts.footer and "center" or nil,
    })

    -- Window styling
    vim.api.nvim_set_option_value("winhl", "Normal:NormalFloat,FloatBorder:FloatBorder", { win = win })
    vim.api.nvim_set_option_value("cursorline", true, { win = win })

    return buf, win
end

--- Close a floating window safely
---@param win integer
---@param buf integer
local function close_float(win, buf)
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
    end
end

--- Display SSH Host picker floating window
---@param hosts table[] List from ssh_config.parse()
---@param on_select fun(entry: table) Callback with selected host entry
function M.pick_host(hosts, on_select)
    if #hosts == 0 then
        vim.notify("ZeroNvim: No hosts found in ~/.ssh/config", vim.log.levels.WARN)
        return
    end

    -- Build display lines
    local display_lines = {}

    -- Calculate how wide we need
    local max_width = 40
    for _, entry in ipairs(hosts) do
        local hostname = entry.hostname or entry.host
        local user = entry.user or vim.env.USER or "?"
        local port_str = entry.port ~= 22 and (":" .. entry.port) or ""
        local line = string.format("  %-16s  %s@%s%s", entry.host, user, hostname, port_str)
        max_width = math.max(max_width, #line + 4)
        table.insert(display_lines, line)
    end

    local final_width = math.min(max_width, 70)

    local win_height = math.min(#display_lines, 20)
    local buf, win = create_float({
        title = "SSH Hosts",
        footer = "j/k:Move | CR:Select | q:Cancel",
        width = final_width,
        height = win_height,
    })

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })

    -- Place cursor on first real entry
    vim.api.nvim_win_set_cursor(win, { 1, 0 })

    local host_count = #hosts

    -- Helper: clamp cursor to host entries only
    local function clamp_cursor()
        local pos = vim.api.nvim_win_get_cursor(win)
        if pos[1] > host_count then
            vim.api.nvim_win_set_cursor(win, { host_count, 0 })
        end
        if pos[1] < 1 then
            vim.api.nvim_win_set_cursor(win, { 1, 0 })
        end
    end

    -- Keymaps
    local close = function()
        close_float(win, buf)
    end

    local select = function()
        local pos = vim.api.nvim_win_get_cursor(win)
        local idx = pos[1]
        if idx >= 1 and idx <= host_count then
            local entry = hosts[idx]
            close_float(win, buf)
            vim.schedule(function() on_select(entry) end)
        end
    end

    local move_down = function()
        local pos = vim.api.nvim_win_get_cursor(win)
        if pos[1] < host_count then
            vim.api.nvim_win_set_cursor(win, { pos[1] + 1, 0 })
        end
    end

    local move_up = function()
        local pos = vim.api.nvim_win_get_cursor(win)
        if pos[1] > 1 then
            vim.api.nvim_win_set_cursor(win, { pos[1] - 1, 0 })
        end
    end

    local map_opts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("n", "<CR>", select, map_opts)
    vim.keymap.set("n", "q", close, map_opts)
    vim.keymap.set("n", "<Esc>", close, map_opts)
    vim.keymap.set("n", "j", move_down, map_opts)
    vim.keymap.set("n", "k", move_up, map_opts)
    vim.keymap.set("n", "<Down>", move_down, map_opts)
    vim.keymap.set("n", "<Up>", move_up, map_opts)

    -- Prevent cursor from entering hints area
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = buf,
        callback = function()
            if not vim.api.nvim_win_is_valid(win) then return true end
            clamp_cursor()
        end,
    })
end

----------------------------------------------------------------------
-- File type icons
----------------------------------------------------------------------

local icon_map = {
    -- Source code
    lua = "🌙",
    py = "🐍",
    rs = "🦀",
    go = "🐹",
    js = "📜",
    ts = "📘",
    jsx = "⚛️",
    tsx = "⚛️",
    rb = "💎",
    c = "⚙️",
    cpp = "⚙️",
    h = "⚙️",
    java = "☕",
    cs = "🔷",
    swift = "🐦",
    kt = "🟣",
    php = "🐘",
    -- Web / markup
    html = "🌐",
    css = "🎨",
    scss = "🎨",
    less = "🎨",
    vue = "💚",
    svelte = "🔥",
    -- Data / config
    json = "📋",
    yaml = "📋",
    yml = "📋",
    toml = "📋",
    xml = "📋",
    csv = "📊",
    ini = "⚙️",
    conf = "⚙️",
    env = "🔒",
    -- Shell / scripts
    sh = "🐚",
    bash = "🐚",
    zsh = "🐚",
    fish = "🐚",
    bat = "🐚",
    ps1 = "🐚",
    -- Docs
    md = "📝",
    txt = "📝",
    rst = "📝",
    org = "📝",
    tex = "📝",
    pdf = "📕",
    doc = "📘",
    docx = "📘",
    xls = "📗",
    xlsx = "📗",
    ppt = "📙",
    -- Images
    png = "🖼️",
    jpg = "🖼️",
    jpeg = "🖼️",
    gif = "🖼️",
    svg = "🖼️",
    ico = "🖼️",
    bmp = "🖼️",
    webp = "🖼️",
    -- Video / audio
    mp4 = "🎬",
    mkv = "🎬",
    avi = "🎬",
    mov = "🎬",
    webm = "🎬",
    mp3 = "🎵",
    wav = "🎵",
    flac = "🎵",
    ogg = "🎵",
    -- Archives
    zip = "📦",
    tar = "📦",
    gz = "📦",
    bz2 = "📦",
    xz = "📦",
    ["7z"] = "📦",
    rar = "📦",
    -- Build / lock
    lock = "🔒",
    log = "📃",
    -- Binary / misc
    so = "🔧",
    dll = "🔧",
    exe = "🔧",
    bin = "🔧",
    o = "🔧",
}

--- Get an emoji icon for a file extension
---@param ext? string File extension (without dot)
---@return string icon
function M._file_icon(ext)
    if not ext then return "📄" end
    return icon_map[ext:lower()] or "📄"
end

----------------------------------------------------------------------
-- Remote Directory Browser
----------------------------------------------------------------------

--- Browse remote directories in a floating window.
--- Connects to the server, reads directories via the daemon, and allows
--- navigation. Press <CR> on a directory to enter it, <C-s> to confirm
--- the current directory, "-" or ".." to go up, q/<Esc> to cancel.
---
---@param user string
---@param hostname string
---@param port integer
---@param on_confirm fun(path: string) Called with the selected directory path
---@param opts? { start_path?: string, display_name?: string }
function M.browse_path(user, hostname, port, on_confirm, opts)
    local zero = require("zero-nvim")
    opts = opts or {}
    local default_home = "/home/" .. user
    local current_path = opts.start_path or default_home
    local display_name = opts.display_name or string.format("%s@%s", user, hostname)
    local show_hidden = false

    local float_width = 65

    local buf, win = create_float({
        title = display_name .. ":" .. current_path,
        footer = "CR:Enter | -:Parent | C-s:Open | .:Hidden | q:Cancel",
        width = float_width,
        height = 10, -- initial; resized dynamically in render()
    })

    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })

    -- State for the current directory listing
    local raw_entries = {}     -- full unfiltered listing from daemon
    local current_entries = {} -- filtered listing currently displayed
    local entry_count = 0      -- number of selectable rows (.. + filtered entries)

    --- Render the current directory entries into the buffer
    local function render(entries)
        if entries then raw_entries = entries end

        -- Filter hidden files
        current_entries = {}
        for _, entry in ipairs(raw_entries) do
            if show_hidden or entry.name:sub(1, 1) ~= "." then
                table.insert(current_entries, entry)
            end
        end

        table.sort(current_entries, function(a, b)
            if a.type ~= b.type then return a.type == "directory" end
            return a.name < b.name
        end)

        local lines = {}
        table.insert(lines, "  ↩️  ../")

        for _, entry in ipairs(current_entries) do
            if entry.type == "directory" then
                table.insert(lines, "  📁 " .. entry.name .. "/")
            else
                local ext = entry.name:match("%.([^%.]+)$")
                local icon = M._file_icon(ext)
                table.insert(lines, "  " .. icon .. " " .. entry.name)
            end
        end

        entry_count = 1 + #current_entries -- 1 for "..", rest for filtered entries

        if not vim.api.nvim_buf_is_valid(buf) then return end
        vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

        -- Resize window to fit content (capped at editor height - 4)
        if vim.api.nvim_win_is_valid(win) then
            local editor = vim.api.nvim_list_uis()[1] or { height = 40 }
            local new_height = math.min(#lines, editor.height - 4)
            vim.api.nvim_win_set_config(win, {
                relative = "editor",
                height = new_height,
                row = math.floor((editor.height - new_height) / 2),
                col = math.floor((editor.width - float_width) / 2),
            })
            vim.api.nvim_win_set_cursor(win, { 1, 0 })
        end
    end

    --- Load a remote directory and render it
    local function load_dir(path)
        current_path = path
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_set_config(win, {
                relative = "editor",
                row = math.floor(((vim.api.nvim_list_uis()[1] or { height = 40 }).height - vim.api.nvim_win_get_height(win)) /
                    2),
                col = math.floor(((vim.api.nvim_list_uis()[1] or { width = 80 }).width - float_width) / 2),
                title = " " .. display_name .. ":" .. current_path .. " ",
                title_pos = "center",
            })
        end

        local chan, err = zero.ensure_connection(user, hostname, port)
        if not chan then
            vim.notify("ZeroNvim: Connection failed — " .. (err or "unknown"), vim.log.levels.ERROR)
            close_float(win, buf)
            return
        end

        local ok, entries = pcall(vim.fn.rpcrequest, chan, "read_dir", user, hostname, port, path)
        if not ok then
            vim.notify("ZeroNvim: Failed to read directory — " .. tostring(entries), vim.log.levels.ERROR)
            render({})
            return
        end

        render(entries)
    end

    local function clamp_cursor()
        if not vim.api.nvim_win_is_valid(win) then return end
        local pos = vim.api.nvim_win_get_cursor(win)
        if pos[1] < 1 then vim.api.nvim_win_set_cursor(win, { 1, 0 }) end
        if pos[1] > entry_count then vim.api.nvim_win_set_cursor(win, { entry_count, 0 }) end
    end

    local function get_cursor_entry()
        if not vim.api.nvim_win_is_valid(win) then return nil end
        local row = vim.api.nvim_win_get_cursor(win)[1]
        if row == 1 then
            return { name = "..", type = "directory" }
        elseif row >= 2 and row <= 1 + #current_entries then
            return current_entries[row - 1]
        end
        return nil
    end

    local map_opts = { buffer = buf, silent = true, nowait = true }

    vim.keymap.set("n", "<CR>", function()
        local entry = get_cursor_entry()
        if not entry then return end
        if entry.name == ".." then
            local parent = vim.fs.dirname(current_path:gsub("/$", ""))
            if parent == "" then parent = "/" end
            load_dir(parent)
        elseif entry.type == "directory" then
            local new_path = current_path:gsub("/$", "") .. "/" .. entry.name
            load_dir(new_path)
        else
            close_float(win, buf)
            local file_path = current_path:gsub("/$", "") .. "/" .. entry.name
            vim.schedule(function() on_confirm(file_path) end)
        end
    end, map_opts)

    vim.keymap.set("n", "<C-s>", function()
        close_float(win, buf)
        vim.schedule(function() on_confirm(current_path) end)
    end, map_opts)

    vim.keymap.set("n", "-", function()
        local parent = vim.fs.dirname(current_path:gsub("/$", ""))
        if parent == "" then parent = "/" end
        load_dir(parent)
    end, map_opts)

    vim.keymap.set("n", ".", function()
        show_hidden = not show_hidden
        render() -- re-render with same raw_entries, no re-fetch
    end, map_opts)

    vim.keymap.set("n", "q", function() close_float(win, buf) end, map_opts)
    vim.keymap.set("n", "<Esc>", function() close_float(win, buf) end, map_opts)

    vim.keymap.set("n", "j", function()
        if not vim.api.nvim_win_is_valid(win) then return end
        local pos = vim.api.nvim_win_get_cursor(win)
        local last_row = entry_count
        if pos[1] < last_row then vim.api.nvim_win_set_cursor(win, { pos[1] + 1, 0 }) end
    end, map_opts)

    vim.keymap.set("n", "k", function()
        if not vim.api.nvim_win_is_valid(win) then return end
        local pos = vim.api.nvim_win_get_cursor(win)
        if pos[1] > 1 then vim.api.nvim_win_set_cursor(win, { pos[1] - 1, 0 }) end
    end, map_opts)

    vim.keymap.set("n", "<Down>", function()
        if not vim.api.nvim_win_is_valid(win) then return end
        local pos = vim.api.nvim_win_get_cursor(win)
        local last_row = entry_count
        if pos[1] < last_row then vim.api.nvim_win_set_cursor(win, { pos[1] + 1, 0 }) end
    end, map_opts)

    vim.keymap.set("n", "<Up>", function()
        if not vim.api.nvim_win_is_valid(win) then return end
        local pos = vim.api.nvim_win_get_cursor(win)
        if pos[1] > 1 then vim.api.nvim_win_set_cursor(win, { pos[1] - 1, 0 }) end
    end, map_opts)

    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = buf,
        callback = function()
            if not vim.api.nvim_win_is_valid(win) then return true end
            clamp_cursor()
        end,
    })

    -- Initial load
    load_dir(current_path)
end

return M
