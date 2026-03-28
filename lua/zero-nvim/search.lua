local M = {}

local zero = require("zero-nvim")
local ui = require("zero-nvim.ui")

M.current_session = nil
M.last_query = ""

function M.render_tree()
    local session = M.current_session
    if not session then return end

    if not M._hl_defined then
        vim.api.nvim_set_hl(0, "ZeroSearchMatch", { fg = "#61afef", bold = true })
        vim.api.nvim_set_hl(0, "ZeroSearchCount", { fg = "#e5c07b" })
        vim.api.nvim_set_hl(0, "ZeroSearchLineNr", { fg = "#5c6370" })
        vim.api.nvim_set_hl(0, "ZeroSearchSep", { fg = "#5c6370" })
        M._hl_defined = true
    end

    session.nodes = {}
    local display_lines = {}
    local extmarks = {} -- { lnum, col, end_col, hl_group }

    local win_width = vim.api.nvim_win_is_valid(session.results_win)
        and vim.api.nvim_win_get_width(session.results_win) or 60

    for fi, file_obj in ipairs(session.files) do
        local is_expanded = file_obj.expanded
        local icon = is_expanded and "" or ""
        local match_count = #file_obj.matches
        local filepath = file_obj.file
        local filename = vim.fs.basename(filepath)
        local dirpath = filepath:sub(1, #filepath - #filename)

        local ext = filename:match("%.([^%.]+)$") or ""
        local file_icon = (ui.icon_map and ui.icon_map[ext]) and ui.icon_map[ext] or "󰈔"

        -- File header: "icon filename dirpath       [N matches]"
        local name_part = string.format("%s %s %s ", icon, file_icon, filename)
        local count_text = string.format("[%d match%s]", match_count, match_count > 1 and "es" or "")
        local name_w = vim.fn.strdisplaywidth(name_part)
        local dir_w = vim.fn.strdisplaywidth(dirpath)
        local count_w = vim.fn.strdisplaywidth(count_text)
        -- If dirpath would cause overflow, truncate it
        local max_dir_w = win_width - name_w - count_w - 2
        local display_dir = dirpath
        if dir_w > max_dir_w and max_dir_w > 3 then
            -- Truncate from the left: show "...tail/of/path/"
            local chars = vim.fn.split(dirpath, "\\zs")
            local truncated = {}
            local w = 3 -- for "..."
            for i = #chars, 1, -1 do
                w = w + vim.fn.strdisplaywidth(chars[i])
                if w > max_dir_w then break end
                table.insert(truncated, 1, chars[i])
            end
            display_dir = "..." .. table.concat(truncated)
            dir_w = vim.fn.strdisplaywidth(display_dir)
        end
        local padding = string.rep(" ", math.max(1, win_width - name_w - dir_w - count_w - 1))
        local full_line = name_part .. display_dir .. padding .. count_text

        table.insert(display_lines, full_line)
        local current_row = #display_lines - 1

        table.insert(session.nodes, { type = "file", file = file_obj.file, ref = file_obj })

        -- Highlights for file header
        local icon_bytes = #string.format("%s %s ", icon, file_icon)
        local name_end = icon_bytes + #filename
        local dir_start = #name_part
        local dir_end = dir_start + #display_dir
        table.insert(extmarks, { current_row, 0, icon_bytes, "Title" })
        table.insert(extmarks, { current_row, icon_bytes, name_end, "Title" })
        table.insert(extmarks, { current_row, dir_start, dir_end, "Comment" })
        table.insert(extmarks, { current_row, #full_line - #count_text, #full_line, "ZeroSearchCount" })

        if is_expanded then
            for _, match in ipairs(file_obj.matches) do
                -- Match line: "123 │ code content here"
                local lnum_str = string.format("%4d", match.lnum)
                local prefix = lnum_str .. " │ "
                local prefix_w = vim.fn.strdisplaywidth(prefix)
                local max_text_width = win_width - prefix_w
                local text = match.text
                local query_len = #session.query
                local col0 = math.max(0, match.col - 1)

                -- Truncate long lines: center the match keyword in the visible area
                local text_offset = 0
                local display_text = text
                if vim.fn.strdisplaywidth(text) > max_text_width then
                    local ellipsis = "..."
                    local ellipsis_w = 3
                    local chars = vim.fn.split(text, "\\zs")
                    local char_widths = {}
                    local total_w = 0
                    for i, ch in ipairs(chars) do
                        local w = vim.fn.strdisplaywidth(ch)
                        char_widths[i] = w
                        total_w = total_w + w
                    end

                    local match_char = 1
                    local byte_pos = 0
                    for i, ch in ipairs(chars) do
                        if byte_pos >= col0 then break end
                        byte_pos = byte_pos + #ch
                        match_char = i + 1
                    end
                    if match_char > #chars then match_char = #chars end

                    local left = match_char
                    local right = match_char
                    local used = char_widths[match_char] or 0
                    local reserved = ellipsis_w * 2
                    local budget = max_text_width - reserved

                    while right < #chars and used < budget do
                        right = right + 1
                        used = used + char_widths[right]
                    end
                    if used > budget and right > match_char then
                        used = used - char_widths[right]
                        right = right - 1
                    end
                    while left > 1 and used + char_widths[left - 1] <= budget do
                        left = left - 1
                        used = used + char_widths[left]
                    end
                    while right < #chars and used + char_widths[right + 1] <= budget do
                        right = right + 1
                        used = used + char_widths[right]
                    end

                    local need_left_ellipsis = left > 1
                    local need_right_ellipsis = right < #chars

                    if need_left_ellipsis or need_right_ellipsis then
                        if not need_left_ellipsis then
                            budget = budget + ellipsis_w
                            while right < #chars and used + char_widths[right + 1] <= budget do
                                right = right + 1
                                used = used + char_widths[right]
                            end
                            need_right_ellipsis = right < #chars
                        elseif not need_right_ellipsis then
                            budget = budget + ellipsis_w
                            while left > 1 and used + char_widths[left - 1] <= budget do
                                left = left - 1
                                used = used + char_widths[left]
                            end
                            need_left_ellipsis = left > 1
                        end
                    end

                    local parts = {}
                    for i = left, right do parts[#parts + 1] = chars[i] end
                    local sliced = table.concat(parts)

                    display_text = (need_left_ellipsis and ellipsis or "")
                        .. sliced
                        .. (need_right_ellipsis and ellipsis or "")

                    local left_byte = 0
                    for i = 1, left - 1 do left_byte = left_byte + #chars[i] end
                    text_offset = left_byte - (need_left_ellipsis and #ellipsis or 0)
                end

                local c_line = prefix .. display_text

                table.insert(display_lines, c_line)
                local c_row = #display_lines - 1

                table.insert(session.nodes, {
                    type = "match",
                    file = file_obj.file,
                    lnum = match.lnum,
                    col = match.col,
                    text = match.text
                })

                -- Highlights: line number dim, separator dim
                local lnum_end = #lnum_str
                local sep_start = lnum_end + 1 -- space before │
                local sep_end = sep_start + #"│"
                table.insert(extmarks, { c_row, 0, lnum_end, "ZeroSearchLineNr" })
                table.insert(extmarks, { c_row, sep_start, sep_end, "ZeroSearchSep" })

                -- Highlight the match keyword in blue
                local prefix_bytes = #prefix
                local match_start = prefix_bytes + col0 - text_offset
                if match.col > 0 and match_start >= prefix_bytes and (match_start + query_len) <= #c_line then
                    table.insert(extmarks, { c_row, match_start, match_start + query_len, "ZeroSearchMatch" })
                end
            end
        end

        -- Add separator between file groups (but not after the last one)
        if fi < #session.files then
            table.insert(display_lines, "")
            table.insert(session.nodes, { type = "spacer" })
        end
    end

    local buf = session.results_buf
    if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
        if #display_lines == 0 then
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  0 results found." })
        else
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
            vim.api.nvim_buf_clear_namespace(buf, session.ns, 0, -1)
            for _, mark in ipairs(extmarks) do
                pcall(vim.api.nvim_buf_set_extmark, buf, session.ns, mark[1], mark[2], {
                    end_col = mark[3],
                    hl_group = mark[4]
                })
            end
        end
        vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

        if session.selected_index == 0 and #session.nodes > 0 then
            M.set_selection(1)
        else
            -- re-clamp selection
            M.set_selection(session.selected_index)
        end
    end
end

function M.on_chunk(session_id, lines)
    local session = M.current_session
    if not session or session.id ~= session_id then return end

    local changed = false
    for _, line in ipairs(lines) do
        local file, lnum, col, text = line:match("^([^:]+):(%d+):(%d+):(.*)$")
        if file then
            if not session.file_map[file] then
                local new_file = { file = file, expanded = true, matches = {} }
                session.file_map[file] = new_file
                table.insert(session.files, new_file)
            end
            table.insert(session.file_map[file].matches, {
                lnum = tonumber(lnum),
                col = tonumber(col),
                text = text,
            })
            changed = true
        end
    end

    if changed then M.render_tree() end
end

function M.on_end(session_id)
    local session = M.current_session
    if not session or session.id ~= session_id then return end
    if #session.files == 0 then M.render_tree() end
end

function M.on_error(session_id, error_msg)
    local session = M.current_session
    if not session or session.id ~= session_id then return end
    local msg = error_msg:gsub("^sh: %d+: ", "")
    vim.notify("ZeroSearch Error: " .. msg, vim.log.levels.ERROR)
end

function M.toggle_fold()
    local session = M.current_session
    if not session then return end
    local node = session.nodes[session.selected_index]
    if node and node.type == "file" then
        node.ref.expanded = not node.ref.expanded
        M.render_tree()
    end
end

function M.update_preview()
    local session = M.current_session
    if not session then return end

    local node = session.nodes[session.selected_index]

    -- Clear preview if spacer or invalid
    if not node or node.type == "spacer" then
        if vim.api.nvim_buf_is_valid(session.preview_buf) then
            vim.api.nvim_set_option_value("modifiable", true, { buf = session.preview_buf })
            vim.api.nvim_buf_set_lines(session.preview_buf, 0, -1, false, {})
            vim.api.nvim_set_option_value("modifiable", false, { buf = session.preview_buf })
        end
        return
    end

    session.file_cache = session.file_cache or {}
    local content = session.file_cache[node.file]
    if not content then
        if session.is_local then
            local f = io.open(node.file, "r")
            if f then
                content = f:read("*a")
                f:close()
                session.file_cache[node.file] = content
            end
        else
            content = zero.get_file_content(session.user, session.host, session.port, node.file)
            if content then
                session.file_cache[node.file] = content
            end
        end
    end

    if content and vim.api.nvim_buf_is_valid(session.preview_buf) then
        local lines = vim.split(content, "\n")
        if #lines > 0 and lines[#lines] == "" then table.remove(lines) end

        vim.api.nvim_set_option_value("modifiable", true, { buf = session.preview_buf })
        vim.api.nvim_buf_set_lines(session.preview_buf, 0, -1, false, lines)
        vim.api.nvim_set_option_value("modifiable", false, { buf = session.preview_buf })

        local ft = vim.filetype.match({ filename = node.file })
        if ft then pcall(vim.api.nvim_set_option_value, "filetype", ft, { buf = session.preview_buf }) end

        local win = session.preview_win
        if vim.api.nvim_win_is_valid(win) then
            local lnum = node.type == "match" and node.lnum or 1
            local col = node.type == "match" and math.max(0, node.col - 1) or 0

            pcall(vim.api.nvim_win_set_cursor, win, { lnum, col })
            vim.api.nvim_win_call(win, function() vim.cmd("normal! zz") end)

            pcall(vim.api.nvim_buf_clear_namespace, session.preview_buf, session.ns, 0, -1)
            -- Highlight the matched line if it's a match node
            if node.type == "match" then
                pcall(vim.api.nvim_buf_add_highlight, session.preview_buf, session.ns, "Search", lnum - 1, 0, -1)
            end
        end
    end
end

function M.set_selection(idx)
    local session = M.current_session
    if not session or #session.nodes == 0 then return end

    if idx < 1 then idx = 1 end
    if idx > #session.nodes then idx = #session.nodes end

    -- Skip spacer nodes when navigating
    if session.nodes[idx].type == "spacer" then
        if idx > session.selected_index and idx < #session.nodes then
            idx = idx + 1
        elseif idx < session.selected_index and idx > 1 then
            idx = idx - 1
        else
            return
        end
    end

    session.selected_index = idx

    local win = session.results_win
    if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_set_cursor, win, { idx, 0 })
    end

    local buf = session.results_buf
    if vim.api.nvim_buf_is_valid(buf) then
        if not session.cursor_ns then
            session.cursor_ns = vim.api.nvim_create_namespace("zero_search_cursor")
        end
        pcall(vim.api.nvim_buf_clear_namespace, buf, session.cursor_ns, 0, -1)
        pcall(vim.api.nvim_buf_add_highlight, buf, session.cursor_ns, "CursorLine", idx - 1, 0, -1)
    end

    M.update_preview()
end

function M.close_ui()
    local session = M.current_session
    if not session then return end
    local wins = { session.path_win, session.input_win, session.results_win, session.preview_win }
    for _, win in ipairs(wins) do
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end
    for _, buf in ipairs({ session.path_buf, session.input_buf, session.results_buf, session.preview_buf }) do
        if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end
    if session.job_id then
        pcall(vim.fn.jobstop, session.job_id)
    end
    if session.timer then
        session.timer:stop()
        session.timer:close()
    end
    M.current_session = nil
    vim.cmd("stopinsert")
end

function M.execute_search(case_sensitive, whole_word)
    local session = M.current_session
    if not session then return end

    local path_lines = vim.api.nvim_buf_get_lines(session.path_buf, 0, 1, false)
    local query_lines = vim.api.nvim_buf_get_lines(session.input_buf, 0, 1, false)

    local path = path_lines[1] or "/"
    local query = query_lines[1] or ""
    M.last_query = query

    session.query = query
    session.files = {}
    session.file_map = {}
    session.nodes = {}
    session.selected_index = 0

    if vim.api.nvim_buf_is_valid(session.results_buf) then
        vim.api.nvim_set_option_value("modifiable", true, { buf = session.results_buf })
        vim.api.nvim_buf_set_lines(session.results_buf, 0, -1, false, {})
        vim.api.nvim_set_option_value("modifiable", false, { buf = session.results_buf })
        pcall(vim.api.nvim_buf_clear_namespace, session.results_buf, session.ns, 0, -1)
    end

    if vim.api.nvim_buf_is_valid(session.preview_buf) then
        vim.api.nvim_set_option_value("modifiable", true, { buf = session.preview_buf })
        vim.api.nvim_buf_set_lines(session.preview_buf, 0, -1, false, {})
        vim.api.nvim_set_option_value("modifiable", false, { buf = session.preview_buf })
    end

    if query == "" or path == "" then return end

    session.id = tostring(vim.loop.now())

    local file_types = (session.toggle_state and session.toggle_state.file_types) or {}

    -- Separate rg built-in types from custom extensions
    local rg_builtin = {
        c = true, cpp = true, css = true, go = true, h = true, html = true,
        java = true, js = true, json = true, lua = true, md = true, py = true,
        rust = true, sh = true, sql = true, toml = true, ts = true, txt = true,
        xml = true, yaml = true,
    }
    local builtin_list = {}
    local glob_list = {}
    for _, ft in ipairs(file_types) do
        if rg_builtin[ft] then
            table.insert(builtin_list, ft)
        else
            table.insert(glob_list, ft)
        end
    end

    if session.is_local then
        if session.job_id then pcall(vim.fn.jobstop, session.job_id) end
        local args = { "rg", "--line-number", "--column", "--no-heading", "--color=never", "--with-filename" }
        if case_sensitive then table.insert(args, "--case-sensitive") else table.insert(args, "--ignore-case") end
        if whole_word then table.insert(args, "--word-regexp") end
        for _, ft in ipairs(builtin_list) do
            table.insert(args, "--type")
            table.insert(args, ft)
        end
        for _, ft in ipairs(glob_list) do
            table.insert(args, "--glob")
            table.insert(args, "*." .. ft)
        end
        table.insert(args, query)
        table.insert(args, path)

        session.job_id = vim.fn.jobstart(args, {
            on_stdout = function(j, data, e)
                if not data or #data == 0 or (#data == 1 and data[1] == "") then return end
                M.on_chunk(session.id, data)
            end,
            on_exit = function(j, exit_code, e)
                M.on_end(session.id)
            end,
        })
    else
        -- Format: "type:lua,rust;glob:vue,svelte"
        local parts = {}
        if #builtin_list > 0 then table.insert(parts, "type:" .. table.concat(builtin_list, ",")) end
        if #glob_list > 0 then table.insert(parts, "glob:" .. table.concat(glob_list, ",")) end
        local types_str = table.concat(parts, ";")
        vim.fn.rpcrequest(session.chan, "global_search", session.user, session.host, session.port, path, query,
            session.id, case_sensitive or false, whole_word or false, types_str)
    end
end

function M.focus_window(name)
    local session = M.current_session
    if not session then return end

    if name == "path" and vim.api.nvim_win_is_valid(session.path_win) then
        vim.api.nvim_set_current_win(session.path_win)
        session.focus = "path"
    elseif name == "query" and vim.api.nvim_win_is_valid(session.input_win) then
        vim.api.nvim_set_current_win(session.input_win)
        session.focus = "query"
    elseif name == "results" and vim.api.nvim_win_is_valid(session.results_win) then
        vim.api.nvim_set_current_win(session.results_win)
        session.focus = "results"
    end
end

function M.open_ui(opts)
    local title_prefix
    if opts.is_local then
        title_prefix = "Local"
    else
        local chan = zero.ensure_connection(opts.user, opts.host, opts.port)
        if not chan then
            vim.notify("ZeroNvim: Cannot connect to daemon for search", vim.log.levels.ERROR)
            return
        end
        opts.chan = chan
        title_prefix = string.format("%s@%s:%s", opts.user, opts.host, opts.port)
    end

    M.current_session = {
        is_local = opts.is_local,
        chan = opts.chan,
        user = opts.user,
        host = opts.host,
        port = opts.port,
        files = {},
        file_map = {},
        nodes = {},
        query = "",
        selected_index = 0,
        id = "",
    }

    local ui_state = ui.open_search_ui(title_prefix, opts.initial_path, {
        on_query_change = function(cs, ww) M.execute_search(cs, ww) end,
        on_path_change = function(cs, ww) M.execute_search(cs, ww) end,
        on_close = function() M.close_ui() end,
        on_enter = function()
            local session = M.current_session
            if not session then return end
            local node = session.nodes[session.selected_index]
            if not node or node.type == "spacer" then return end

            if node.type == "file" then
                M.toggle_fold()
                return
            end

            M.close_ui()
            if session.is_local then
                vim.cmd("edit " .. vim.fn.fnameescape(node.file))
            else
                local uri = string.format("zero://%s@%s:%d%s", session.user, session.host, session.port, node.file)
                vim.cmd("edit " .. uri)
            end
            vim.schedule(function()
                pcall(vim.api.nvim_win_set_cursor, 0, { node.lnum, math.max(0, node.col - 1) })
                vim.cmd("normal! zz")
            end)
        end,
        on_toggle_fold = function()
            M.toggle_fold()
        end,
        on_select_next = function()
            if M.current_session and M.current_session.selected_index then
                M.set_selection(M.current_session.selected_index + 1)
            end
        end,
        on_select_prev = function()
            if M.current_session and M.current_session.selected_index then
                if M.current_session.selected_index <= 1 then
                    return true -- Signal to focus query input
                else
                    M.set_selection(M.current_session.selected_index - 1)
                    return false
                end
            end
            return false
        end
    })

    if M.last_query and M.last_query ~= "" then
        vim.api.nvim_buf_set_lines(ui_state.input_buf, 0, -1, false, { M.last_query })
        vim.api.nvim_win_set_cursor(ui_state.input_win, { 1, #M.last_query })
    end

    -- Merge the UI objects directly into our session state for update_preview() and close_ui() access
    for k, v in pairs(ui_state) do
        M.current_session[k] = v
    end
end

function M.live_grep(opts)
    local buf_name = vim.api.nvim_buf_get_name(0)
    local is_remote = buf_name:match("^zero://")

    local default_path = "/"
    local default_user, default_host, default_port

    if is_remote then
        local user, host, port_str, path

        user, host, port_str, path = buf_name:match("^zero://([^@]+)@([^:]+):(%d+)(/.*)$")
        if not user then
            user, host, path = buf_name:match("^zero://([^@]+)@([^/:]+)(/.*)$")
            port_str = "22"
        end

        if user and host and path then
            default_user = user
            default_host = host
            default_port = tonumber(port_str) or 22
            default_path = path:match("/$") and path or vim.fs.dirname(path)
            if default_path == "" or default_path == "." then default_path = "/" end
        end
    end

    if default_user then
        M.open_ui({
            user = default_user,
            host = default_host,
            port = default_port,
            initial_path = default_path
        })
    else
        M.open_ui({
            is_local = true,
            initial_path = vim.fn.getcwd()
        })
    end
end

return M
