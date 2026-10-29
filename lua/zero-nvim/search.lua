local M = {}

local zero = require("zero-nvim")
local ui = require("zero-nvim.ui")
local uri = require("zero-nvim.uri")
local cmd = require("zero-nvim.cmd")
local rg_parser = require("zero-nvim.cmd.parsers.rg")

M.current_session = nil
M.last_query = ""
M.last_path = nil
M.last_case_sensitive = false
M.last_whole_word = false
M.last_file_types = {}
M.last_selected_index = 0

-- 结果上限：超过后停止 rg 并显示 truncated 提示（防 UI 卡死）
M.MAX_RESULTS = 5000
-- 预览防抖（ms）：j/k 连按时不对每一行都同步拉远端文件
M.PREVIEW_DEBOUNCE_MS = 100

-- 单调递增的搜索代号：每次 execute_search（包括清空 query）都会 +1，
-- 旧 stream 的迟到事件靠它丢弃。vim.loop.now() 同一毫秒内会撞。
local search_gen = 0
local function next_gen()
    search_gen = search_gen + 1
    return search_gen
end

local uv = vim.uv or vim.loop

local function close_timer(t)
    if t then
        pcall(function()
            t:stop()
            if not t:is_closing() then t:close() end
        end)
    end
end

-- =============================================================================
-- 内部：rg argv 构造
-- =============================================================================

-- ripgrep 内置 type（其余走 --glob '*.<ext>'）
local RG_BUILTIN = {
    c = true, cpp = true, css = true, go = true, h = true, html = true,
    java = true, js = true, json = true, lua = true, md = true, py = true,
    rust = true, sh = true, sql = true, toml = true, ts = true, txt = true,
    xml = true, yaml = true,
}

-- 远端 PATH 注入：sshd non-interactive shell 通常缺 brew/cargo bin
local REMOTE_PATH_PREFIX =
"/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:/home/linuxbrew/.linuxbrew/bin"

local function build_rg_args(query, path, case_sensitive, whole_word, file_types)
    -- --max-columns：超长行（minified js / 单行 json）只给预览片段，避免几 MB
    -- 的行塞进 msgpack + 渲染
    local args = { "rg", "--json", "--max-columns=500", "--max-columns-preview" }
    if case_sensitive then
        table.insert(args, "--case-sensitive")
    else
        table.insert(args, "--ignore-case")
    end
    if whole_word then table.insert(args, "--word-regexp") end
    for _, ft in ipairs(file_types or {}) do
        if RG_BUILTIN[ft] then
            table.insert(args, "--type"); table.insert(args, ft)
        else
            table.insert(args, "--glob"); table.insert(args, "*." .. ft)
        end
    end
    table.insert(args, "--")
    table.insert(args, query)
    table.insert(args, path)
    return args
end

-- 远端：用 sh -c 包一层让 $PATH 在远端运行时展开
local function wrap_remote_argv(rg_args)
    local out = {
        "sh", "-c",
        ('PATH="%s:$PATH" exec "$@"'):format(REMOTE_PATH_PREFIX),
        "--",
    }
    vim.list_extend(out, rg_args)
    return out
end

-- =============================================================================
-- 内部：增量渲染防抖
-- =============================================================================

local function schedule_render(session)
    if session._render_scheduled then return end
    session._render_scheduled = true
    vim.defer_fn(function()
        session._render_scheduled = false
        if M.current_session == session and not session.closed then
            M.render_tree()
        end
    end, 50)
end

-- =============================================================================
-- 渲染
-- =============================================================================

--- 从第 start_char 个字符（0-based）起，取显示宽度 <= budget 的最长子串。
--- 整串调用 strdisplaywidth，不再逐字符切分。
local function fit_chars(text, start_char, budget)
    if budget <= 0 then return "" end
    local n = budget
    local sub = vim.fn.strcharpart(text, start_char, n)
    local w = vim.fn.strdisplaywidth(sub)
    while w > budget and n > 0 do
        n = n - math.max(1, math.floor((w - budget) / 2))
        sub = vim.fn.strcharpart(text, start_char, n)
        w = vim.fn.strdisplaywidth(sub)
    end
    return sub
end

--- 取 text 尾部显示宽度 <= budget 的最长后缀（目录前缀截断用）。
local function fit_tail(text, budget)
    if budget <= 0 then return "" end
    local total = vim.fn.strchars(text)
    local start = math.max(0, total - budget)
    local sub = vim.fn.strcharpart(text, start)
    local w = vim.fn.strdisplaywidth(sub)
    while w > budget and start < total do
        start = start + math.max(1, math.floor((w - budget) / 2))
        sub = vim.fn.strcharpart(text, start)
        w = vim.fn.strdisplaywidth(sub)
    end
    return sub
end

--- 把匹配行截到 max_w 显示宽度，尽量让 col0（0-based 字节）处的匹配可见。
---@return string display_text
---@return integer text_offset  原文字节偏移 - 显示串字节偏移（用于高亮换算）
local function truncate_around(text, col0, max_w)
    local ellipsis = "..."
    local budget = max_w - 2 * #ellipsis
    if budget < 1 then
        return fit_chars(text, 0, math.max(0, max_w)), 0
    end
    local total = vim.fn.strchars(text)
    local mc = vim.fn.strchars(text:sub(1, col0))
    -- 匹配前保留约 1/3 预算的上下文
    local left = math.max(0, mc - math.floor(budget / 3))
    local sub = fit_chars(text, left, budget)
    if left > 0 and left + vim.fn.strchars(sub) >= total then
        -- 右侧已到行尾：向左回填，但不越过匹配起点
        local tail = fit_tail(text, budget)
        local tail_left = total - vim.fn.strchars(tail)
        if tail_left < left then
            left = math.min(tail_left, mc)
            sub = fit_chars(text, left, budget)
        end
    end
    local need_left = left > 0
    local need_right = left + vim.fn.strchars(sub) < total
    local display = (need_left and ellipsis or "") .. sub .. (need_right and ellipsis or "")
    local left_byte = #vim.fn.strcharpart(text, 0, left)
    return display, left_byte - (need_left and #ellipsis or 0)
end
M._truncate_around = truncate_around

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

        local name_part = string.format("%s %s %s ", icon, file_icon, filename)
        local count_text = string.format("[%d match%s]", match_count, match_count > 1 and "es" or "")
        local name_w = vim.fn.strdisplaywidth(name_part)
        local dir_w = vim.fn.strdisplaywidth(dirpath)
        local count_w = vim.fn.strdisplaywidth(count_text)
        local max_dir_w = win_width - name_w - count_w - 2
        local display_dir = dirpath
        if dir_w > max_dir_w and max_dir_w > 3 then
            display_dir = "..." .. fit_tail(dirpath, max_dir_w - 3)
            dir_w = vim.fn.strdisplaywidth(display_dir)
        end
        local padding = string.rep(" ", math.max(1, win_width - name_w - dir_w - count_w - 1))
        local full_line = name_part .. display_dir .. padding .. count_text

        table.insert(display_lines, full_line)
        local current_row = #display_lines - 1

        table.insert(session.nodes, { type = "file", file = file_obj.file, ref = file_obj })

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
                local lnum_str = string.format("%4d", match.lnum)
                local prefix = lnum_str .. " │ "
                local prefix_w = vim.fn.strdisplaywidth(prefix)
                local max_text_width = win_width - prefix_w
                local text = match.text
                -- 旧 text 模式 col 是 1-based；新 JSON 模式我们也产 1-based。
                local col0 = math.max(0, match.col - 1)
                local match_len = match.match_len or #(session.query or "")

                local text_offset = 0
                local display_text = text
                if #text > max_text_width and vim.fn.strdisplaywidth(text) > max_text_width then
                    display_text, text_offset = truncate_around(text, col0, max_text_width)
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

                local lnum_end = #lnum_str
                local sep_start = lnum_end + 1
                local sep_end = sep_start + #"│"
                table.insert(extmarks, { c_row, 0, lnum_end, "ZeroSearchLineNr" })
                table.insert(extmarks, { c_row, sep_start, sep_end, "ZeroSearchSep" })

                local prefix_bytes = #prefix
                local match_start = prefix_bytes + col0 - text_offset
                local match_end = math.min(match_start + match_len, #c_line)
                if match.col > 0 and match_start >= prefix_bytes and match_end > match_start then
                    table.insert(extmarks, { c_row, match_start, match_end, "ZeroSearchMatch" })
                end
            end
        end

        if fi < #session.files then
            table.insert(display_lines, "")
            table.insert(session.nodes, { type = "spacer" })
        end
    end

    if session.truncated and #display_lines > 0 then
        table.insert(display_lines, "")
        table.insert(session.nodes, { type = "spacer" })
        table.insert(display_lines, string.format("  ... truncated at %d matches (refine the query)", M.MAX_RESULTS))
        table.insert(session.nodes, { type = "spacer" })
        table.insert(extmarks, { #display_lines - 1, 0, #display_lines[#display_lines], "Comment" })
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

        if M.last_selected_index > 0 then
            if #session.nodes >= M.last_selected_index then
                M.set_selection(M.last_selected_index)
                M.last_selected_index = 0
            end
        elseif session.selected_index == 0 and #session.nodes > 0 then
            M.set_selection(1)
        else
            M.set_selection(session.selected_index)
        end
    end
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

--- 立即渲染当前选中节点的预览。内容按文件缓存在 session 内（失败也缓存为
--- false，避免对同一个拉不下来的文件反复同步 RPC）。
local function render_preview(session)
    if M.current_session ~= session or session.closed then return end

    local node = session.nodes[session.selected_index]

    if not node or node.type == "spacer" then
        session._preview_key = nil
        if vim.api.nvim_buf_is_valid(session.preview_buf) then
            vim.api.nvim_set_option_value("modifiable", true, { buf = session.preview_buf })
            vim.api.nvim_buf_set_lines(session.preview_buf, 0, -1, false, {})
            vim.api.nvim_set_option_value("modifiable", false, { buf = session.preview_buf })
        end
        return
    end

    -- render_tree 每 50ms 重绘都会 set_selection；同一节点不重复刷新预览
    local key = node.file .. "\n" .. tostring(node.lnum) .. ":" .. tostring(node.col)
    if session._preview_key == key then return end

    session.file_cache = session.file_cache or {}
    local content = session.file_cache[node.file]
    if content == nil then
        if session.is_local then
            local f = io.open(node.file, "r")
            if f then
                content = f:read("*a")
                f:close()
            end
        else
            content = zero.get_file_content(session.user, session.host, session.port, node.file)
        end
        if type(content) ~= "string" then content = false end
        session.file_cache[node.file] = content
        -- 同步拉取期间 UI 可能已被关闭
        if M.current_session ~= session or session.closed then return end
    end
    session._preview_key = key

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
            if node.type == "match" then
                pcall(vim.api.nvim_buf_add_highlight, session.preview_buf, session.ns, "Search", lnum - 1, 0, -1)
            end
        end
    end
end

--- 防抖预览：选择变化后 PREVIEW_DEBOUNCE_MS 内没有新变化才真正拉文件。
function M.update_preview()
    local session = M.current_session
    if not session or session.closed then return end
    if not session.preview_timer then
        session.preview_timer = uv.new_timer()
    end
    session.preview_timer:stop()
    session.preview_timer:start(M.PREVIEW_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
        render_preview(session)
    end))
end

function M.set_selection(idx)
    local session = M.current_session
    if not session or #session.nodes == 0 then return end

    if idx < 1 then idx = 1 end
    if idx > #session.nodes then idx = #session.nodes end

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

-- 取消任何在飞的搜索（远程 cmd.stream 或本地 jobstart）
local function cancel_inflight(session)
    if session.job_id then
        pcall(vim.fn.jobstop, session.job_id)
        session.job_id = nil
    end
    if session.stream_sid then
        pcall(cmd.cancel, session.stream_sid)
        session.stream_sid = nil
    end
    session._local_parser = nil
end

--- 关闭 UI 并做完整 teardown：取消在飞搜索、关所有浮窗、关 timer、删 augroup。
--- 可重入：WinClosed 回调 / q / <Esc> / 打开结果 任一路径先到先关，后到 no-op。
---@param session? table 指定要关的 session；省略 = 当前 session
function M.close_ui(session)
    session = session or M.current_session
    if not session or session.closed then return end
    session.closed = true
    -- 先删 augroup：下面主动关窗口时不要再触发 WinClosed 回调
    if session.augroup then
        pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
        session.augroup = nil
    end
    -- 代号 +1：在飞 stream 的迟到事件 / 防抖回调全部失效
    session.id = next_gen()
    cancel_inflight(session)
    close_timer(session.timer1); session.timer1 = nil
    close_timer(session.timer2); session.timer2 = nil
    close_timer(session.preview_timer); session.preview_timer = nil

    local wins = { session.path_win, session.input_win, session.results_win, session.preview_win }
    for _, win in ipairs(wins) do
        if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    end
    for _, buf in ipairs({ session.path_buf, session.input_buf, session.results_buf, session.preview_buf }) do
        if buf and vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    end
    M.last_selected_index = session.selected_index or 0
    if M.current_session == session then
        M.current_session = nil
    end
    vim.cmd("stopinsert")
end

function M.execute_search(case_sensitive, whole_word)
    local session = M.current_session
    if not session or session.closed then return end

    local path_lines = vim.api.nvim_buf_get_lines(session.path_buf, 0, 1, false)
    local query_lines = vim.api.nvim_buf_get_lines(session.input_buf, 0, 1, false)

    local path = path_lines[1] or "/"
    local query = query_lines[1] or ""
    M.last_query = query
    M.last_path = path
    M.last_case_sensitive = case_sensitive
    M.last_whole_word = whole_word
    M.last_file_types = (session.toggle_state and session.toggle_state.file_types) or {}

    cancel_inflight(session)
    -- 先换代号再决定是否 early return：清空 query 时旧 stream 的迟到结果
    -- 不能再回填列表
    session.id = next_gen()
    local sid_capture = session.id

    session.query = query
    session.files = {}
    session.file_map = {}
    session.nodes = {}
    session.selected_index = 0
    session.match_count = 0
    session.truncated = false
    session._stderr_buf = nil
    session._parse_errors = 0
    session._preview_key = nil

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

    local file_types = (session.toggle_state and session.toggle_state.file_types) or {}
    local rg_args = build_rg_args(query, path, case_sensitive, whole_word, file_types)

    local function is_live()
        return M.current_session == session and not session.closed and session.id == sid_capture
    end

    local function on_event(ev)
        if not is_live() or session.truncated then return end
        local kind = ev.kind
        if kind == "match" then
            local f = ev.file
            if not session.file_map[f] then
                local nf = { file = f, expanded = true, matches = {} }
                session.file_map[f] = nf
                table.insert(session.files, nf)
            end
            table.insert(session.file_map[f].matches, {
                lnum = ev.lnum,
                col = ev.col,
                text = ev.text,
                match_len = ev.match_len,
            })
            session.match_count = session.match_count + 1
            if session.match_count >= M.MAX_RESULTS then
                -- 到上限：停掉 rg，保留已有结果 + truncated 提示。
                -- 不换代号，让 on_done 照常收尾渲染。
                session.truncated = true
                if session.job_id then pcall(vim.fn.jobstop, session.job_id) end
                if session.stream_sid then pcall(cmd.cancel, session.stream_sid) end
            end
            schedule_render(session)
        elseif kind == "stderr" then
            -- stderr 只留前 4KB，够诊断
            local buf = session._stderr_buf or ""
            if #buf < 4096 then session._stderr_buf = buf .. ev.text end
        elseif kind == "parse_error" then
            session._parse_errors = (session._parse_errors or 0) + 1
        end
        -- file_begin / file_end 忽略：match 上来时 lazy 创建条目
    end

    local function on_done(code, reason)
        if not is_live() then return end
        session.job_id = nil
        session.stream_sid = nil
        session._local_parser = nil

        local has_results = #session.files > 0
        if session.truncated then
            -- 我们自己因结果上限取消的：不报错
        elseif reason then
            -- aborted / cancelled：daemon 的 reason 形如 "cancelled (exit=N)" /
            -- "cancelled: ..." / "aborted: ..."。主动 cancel 已经换过代号走不到这里；
            -- 能到这里的是 daemon 侧中断（连接断 / daemon 退出），提示一下。
            if not reason:match("^cancelled") then
                vim.notify("ZeroSearch: search aborted (" .. reason .. ")", vim.log.levels.WARN)
            end
        elseif code and code >= 2 then
            -- rg 退出码：0 = 有匹配；1 = 无匹配；2 = 出错（但可能已有部分结果，
            -- 例如部分文件无权限读取）→ 有结果时降级成 warning
            local msg = (session._stderr_buf or ""):gsub("^sh: %d+: ", "")
            if msg == "" then msg = "rg exited with code " .. tostring(code) end
            if has_results then
                vim.notify("ZeroSearch: rg reported errors (partial results):\n" .. msg, vim.log.levels.WARN)
            else
                vim.notify("ZeroSearch Error: " .. msg, vim.log.levels.ERROR)
            end
        end
        if (session._parse_errors or 0) > 0 and not has_results then
            vim.notify(
                ("ZeroSearch: rg --json 解析失败 %d 行（远端 rg 可能太老或不存在）"):format(
                    session._parse_errors),
                vim.log.levels.WARN)
        end

        M.render_tree()
        if M.last_selected_index > 0 and #session.nodes > 0 then
            M.set_selection(math.min(M.last_selected_index, #session.nodes))
            M.last_selected_index = 0
        end
    end

    if session.is_local then
        local parser = rg_parser.new()
        session._local_parser = parser
        local job_id = vim.fn.jobstart(rg_args, {
            on_stdout = function(_, data)
                if not data or #data == 0 then return end
                local events = parser:feed(table.concat(data, "\n"))
                if events then for _, ev in ipairs(events) do on_event(ev) end end
            end,
            on_stderr = function(_, data)
                if not data or #data == 0 then return end
                local s = table.concat(data, "\n")
                if #s > 0 then on_event({ kind = "stderr", text = s }) end
            end,
            on_exit = function(_, code)
                if session._local_parser == parser then
                    local tail = parser:finalize() or {}
                    for _, ev in ipairs(tail) do on_event(ev) end
                end
                on_done(code, nil)
            end,
        })
        if job_id <= 0 then
            session._local_parser = nil
            local why = job_id == -1 and "rg not found in PATH" or "invalid arguments"
            vim.notify("ZeroSearch: failed to start rg (" .. why .. ")", vim.log.levels.ERROR)
            return
        end
        session.job_id = job_id
    else
        local target = { user = session.user, host = session.host, port = session.port }
        local sid, err = cmd.stream(target, {
            argv = wrap_remote_argv(rg_args),
            parser = rg_parser.new(),
            owner_buf = session.results_buf,
            owner_win = session.results_win,
        }, {
            on_event = on_event,
            on_exit = function(code, _signal, reason, _dur)
                on_done(code, reason)
            end,
        })
        if not sid then
            vim.notify("ZeroSearch: cmd.stream failed: " .. tostring(err), vim.log.levels.ERROR)
            return
        end
        -- stream 启动期间（同步 RPC）UI 可能已被关掉 / 已换代
        if not is_live() then
            pcall(cmd.cancel, sid)
            return
        end
        session.stream_sid = sid
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
        title_prefix = string.format("%s@%s:%s", opts.user, opts.host, opts.port)
    end

    -- 旧 UI 还开着（比如 WinClosed 之外的路径漏关）：先完整 teardown
    if M.current_session then M.close_ui() end

    local this_session = {
        is_local = opts.is_local,
        user = opts.user,
        host = opts.host,
        port = opts.port,
        files = {},
        file_map = {},
        nodes = {},
        query = "",
        selected_index = 0,
        id = next_gen(),
    }
    M.current_session = this_session

    -- 回调全部绑定到 this_session：防抖 timer / WinClosed 的 vim.schedule
    -- 迟到时不能作用到下一次打开的 session 上
    local function is_current()
        return M.current_session == this_session and not this_session.closed
    end

    local ui_state = ui.open_search_ui(title_prefix, opts.initial_path, {
        on_query_change = function(cs, ww) if is_current() then M.execute_search(cs, ww) end end,
        on_path_change = function(cs, ww) if is_current() then M.execute_search(cs, ww) end end,
        on_close = function() M.close_ui(this_session) end,
        on_enter = function()
            if not is_current() then return end
            local session = this_session
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
                local target = uri.format(session.user, session.host, session.port, node.file)
                vim.cmd("edit " .. vim.fn.fnameescape(target))
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
                    return true
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
    if M.last_path and not opts.initial_path then
        vim.api.nvim_buf_set_lines(ui_state.path_buf, 0, -1, false, { M.last_path })
    end
    if ui_state.toggle_state then
        ui_state.toggle_state.case_sensitive = M.last_case_sensitive or false
        ui_state.toggle_state.whole_word = M.last_whole_word or false
        if M.last_file_types and #M.last_file_types > 0 then
            ui_state.toggle_state.file_types = vim.deepcopy(M.last_file_types)
        end
        if ui_state.update_input_footer then ui_state.update_input_footer() end
        if ui_state.update_path_footer then ui_state.update_path_footer() end
    end

    for k, v in pairs(ui_state) do
        this_session[k] = v
    end

    if M.last_query and M.last_query ~= "" then
        if M.current_session.timer1 then M.current_session.timer1:stop() end
        if M.current_session.timer2 then M.current_session.timer2:stop() end
        vim.cmd("stopinsert")
        M.execute_search(
            M.current_session.toggle_state.case_sensitive,
            M.current_session.toggle_state.whole_word
        )
        M.focus_window("results")
    end
end

function M.live_grep(opts)
    local buf_name = vim.api.nvim_buf_get_name(0)
    local is_remote = buf_name:match("^zero://")

    local default_path = "/"
    local default_user, default_host, default_port

    if is_remote then
        local user, host, port, path = uri.parse(buf_name)
        if user and host and path then
            default_user = user
            default_host = host
            default_port = port
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
