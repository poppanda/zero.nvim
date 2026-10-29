--- :ZeroSearch 控制器：rg 调度（本地 jobstart / 远端 cmd.stream）、结果树渲染、预览。
local M = {}

local uri = require("zero-nvim.uri")
local cmd = require("zero-nvim.cmd")
local log = require("zero-nvim.log")
local util = require("zero-nvim.util")
local remote = require("zero-nvim.remote")
local buffer_io = require("zero-nvim.buffer_io")
local icons = require("zero-nvim.ui.icons")
local rg_parser = require("zero-nvim.cmd.parsers.rg")
local view = require("zero-nvim.search.view")
local type_picker = require("zero-nvim.search.type_picker")

M.current_session = nil
-- 上次搜索的状态，下次打开时恢复
M.last = {
    query = "",
    path = nil,
    case_sensitive = false,
    whole_word = false,
    file_types = {},
    selected_index = 0,
}

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

local function define_highlights()
    for name, val in pairs({
        ZeroSearchMatch = { fg = "#61afef", bold = true },
        ZeroSearchCount = { fg = "#e5c07b" },
        ZeroSearchLineNr = { fg = "#5c6370" },
        ZeroSearchSep = { fg = "#5c6370" },
    }) do
        val.default = true
        vim.api.nvim_set_hl(0, name, val)
    end
end

-- =============================================================================
-- 内部：rg argv 构造
-- =============================================================================

local function build_rg_args(query, path, ts)
    -- --max-columns：超长行（minified js / 单行 json）只给预览片段，避免几 MB
    -- 的行塞进 msgpack + 渲染
    local args = { "rg", "--json", "--max-columns=500", "--max-columns-preview" }
    table.insert(args, ts.case_sensitive and "--case-sensitive" or "--ignore-case")
    if ts.whole_word then table.insert(args, "--word-regexp") end
    for _, ft in ipairs(ts.file_types or {}) do
        if type_picker.is_builtin(ft) then
            vim.list_extend(args, { "--type", ft })
        else
            vim.list_extend(args, { "--glob", "*." .. ft })
        end
    end
    return vim.list_extend(args, { "--", query, path })
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

    session.nodes = {}
    local lines = {}
    local marks = {} -- { lnum, col, end_col, hl_group }
    local function add(line, node)
        table.insert(lines, line)
        table.insert(session.nodes, node)
        return #lines - 1
    end

    local win_width = vim.api.nvim_win_is_valid(session.results_win)
        and vim.api.nvim_win_get_width(session.results_win) or 60

    for fi, file_obj in ipairs(session.files) do
        local filepath = file_obj.file
        local filename = vim.fs.basename(filepath)
        local dirpath = filepath:sub(1, #filepath - #filename)
        local count = #file_obj.matches

        local head = string.format("%s %s ", file_obj.expanded and "" or "",
            icons.for_ext(filename:match("%.([^%.]+)$")))
        local name_part = head .. filename .. " "
        local count_text = string.format("[%d match%s]", count, count > 1 and "es" or "")
        local name_w = vim.fn.strdisplaywidth(name_part)
        local count_w = vim.fn.strdisplaywidth(count_text)
        local display_dir = dirpath
        local max_dir_w = win_width - name_w - count_w - 2
        if vim.fn.strdisplaywidth(dirpath) > max_dir_w and max_dir_w > 3 then
            display_dir = "..." .. fit_tail(dirpath, max_dir_w - 3)
        end
        local padding = string.rep(" ", math.max(1, win_width - name_w - vim.fn.strdisplaywidth(display_dir) - count_w - 1))
        local full_line = name_part .. display_dir .. padding .. count_text

        local row = add(full_line, { type = "file", file = filepath, ref = file_obj })
        table.insert(marks, { row, 0, #head + #filename, "Title" })
        table.insert(marks, { row, #name_part, #name_part + #display_dir, "Comment" })
        table.insert(marks, { row, #full_line - #count_text, #full_line, "ZeroSearchCount" })

        if file_obj.expanded then
            for _, match in ipairs(file_obj.matches) do
                local lnum_str = string.format("%4d", match.lnum)
                local prefix = lnum_str .. " │ "
                local max_text_width = win_width - vim.fn.strdisplaywidth(prefix)
                local text = match.text
                -- col 是 1-based
                local col0 = math.max(0, match.col - 1)

                local display_text, text_offset = text, 0
                if #text > max_text_width and vim.fn.strdisplaywidth(text) > max_text_width then
                    display_text, text_offset = truncate_around(text, col0, max_text_width)
                end
                local c_line = prefix .. display_text
                local c_row = add(c_line, { type = "match", file = filepath, lnum = match.lnum, col = match.col, text = text })

                table.insert(marks, { c_row, 0, #lnum_str, "ZeroSearchLineNr" })
                table.insert(marks, { c_row, #lnum_str + 1, #lnum_str + 1 + #"│", "ZeroSearchSep" })
                local match_start = #prefix + col0 - text_offset
                local match_end = math.min(match_start + (match.match_len or #(session.query or "")), #c_line)
                if match.col > 0 and match_start >= #prefix and match_end > match_start then
                    table.insert(marks, { c_row, match_start, match_end, "ZeroSearchMatch" })
                end
            end
        end

        if fi < #session.files then add("", { type = "spacer" }) end
    end

    if session.truncated and #lines > 0 then
        add("", { type = "spacer" })
        local row = add(string.format("  ... truncated at %d matches (refine the query)", M.MAX_RESULTS),
            { type = "spacer" })
        table.insert(marks, { row, 0, #lines[#lines], "Comment" })
    end

    local buf = session.results_buf
    if not vim.api.nvim_buf_is_valid(buf) then return end
    util.set_lines(buf, #lines == 0 and { "  0 results found." } or lines)
    vim.api.nvim_buf_clear_namespace(buf, session.ns, 0, -1)
    for _, m in ipairs(marks) do
        pcall(vim.api.nvim_buf_set_extmark, buf, session.ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
    end

    if M.last.selected_index > 0 then
        if #session.nodes >= M.last.selected_index then
            M.set_selection(M.last.selected_index)
            M.last.selected_index = 0
        end
    elseif session.selected_index == 0 and #session.nodes > 0 then
        M.set_selection(1)
    else
        M.set_selection(session.selected_index)
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

local function read_content(session, file)
    if session.is_local then
        local f = io.open(file, "rb")
        if not f then return nil end
        local content = f:read("*a")
        f:close()
        return content
    end
    return remote.read_file(session.user, session.host, session.port, file)
end

--- 立即渲染当前选中节点的预览。内容按文件缓存在 session 内（失败也缓存为
--- false，避免对同一个拉不下来的文件反复同步 RPC）。
local function render_preview(session)
    if M.current_session ~= session or session.closed then return end

    local node = session.nodes[session.selected_index]
    if not node or node.type == "spacer" then
        session._preview_key = nil
        util.set_lines(session.preview_buf, {})
        return
    end

    -- render_tree 每 50ms 重绘都会 set_selection；同一节点不重复刷新预览
    local key = node.file .. "\n" .. tostring(node.lnum) .. ":" .. tostring(node.col)
    if session._preview_key == key then return end

    session.file_cache = session.file_cache or {}
    local content = session.file_cache[node.file]
    if content == nil then
        content = read_content(session, node.file) or false
        session.file_cache[node.file] = content
        -- 同步拉取期间 UI 可能已被关闭
        if M.current_session ~= session or session.closed then return end
    end
    session._preview_key = key
    if not content or not vim.api.nvim_buf_is_valid(session.preview_buf) then return end

    util.set_lines(session.preview_buf, (buffer_io.content_to_lines(content)))
    local ft = vim.filetype.match({ filename = node.file })
    if ft then pcall(vim.api.nvim_set_option_value, "filetype", ft, { buf = session.preview_buf }) end

    local win = session.preview_win
    if not vim.api.nvim_win_is_valid(win) then return end
    local is_match = node.type == "match"
    pcall(vim.api.nvim_win_set_cursor, win, { is_match and node.lnum or 1, is_match and math.max(0, node.col - 1) or 0 })
    vim.api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
    pcall(vim.api.nvim_buf_clear_namespace, session.preview_buf, session.ns, 0, -1)
    if is_match then
        pcall(vim.api.nvim_buf_add_highlight, session.preview_buf, session.ns, "Search", node.lnum - 1, 0, -1)
    end
end

--- 防抖预览：选择变化后 PREVIEW_DEBOUNCE_MS 内没有新变化才真正拉文件。
function M.update_preview()
    local session = M.current_session
    if not session or session.closed then return end
    session.preview_timer = session.preview_timer or uv.new_timer()
    session.preview_timer:stop()
    session.preview_timer:start(M.PREVIEW_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
        render_preview(session)
    end))
end

function M.set_selection(idx)
    local session = M.current_session
    if not session or #session.nodes == 0 then return end

    idx = math.max(1, math.min(idx, #session.nodes))
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

    if vim.api.nvim_win_is_valid(session.results_win) then
        pcall(vim.api.nvim_win_set_cursor, session.results_win, { idx, 0 })
    end
    local buf = session.results_buf
    if vim.api.nvim_buf_is_valid(buf) then
        session.cursor_ns = session.cursor_ns or vim.api.nvim_create_namespace("zero_search_cursor")
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
    for _, k in ipairs({ "timer1", "timer2", "preview_timer" }) do
        util.close_timer(session[k])
        session[k] = nil
    end
    for _, name in ipairs({ "path", "input", "results", "preview" }) do
        local win, buf = session[name .. "_win"], session[name .. "_buf"]
        if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
        if buf and vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    end
    M.last.selected_index = session.selected_index or 0
    if M.current_session == session then
        M.current_session = nil
    end
    vim.cmd("stopinsert")
end

-- =============================================================================
-- 执行搜索
-- =============================================================================

--- 新一轮搜索前清空 session 的结果状态和两个 buffer
local function reset(session, query)
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
    util.set_lines(session.results_buf, {})
    util.set_lines(session.preview_buf, {})
    if vim.api.nvim_buf_is_valid(session.results_buf) then
        pcall(vim.api.nvim_buf_clear_namespace, session.results_buf, session.ns, 0, -1)
    end
end

--- 本轮搜索的 on_event / on_done；is_live 为 false 时（关了 / 换代了）一律丢弃。
local function make_handlers(session, is_live)
    local function on_event(ev)
        if not is_live() or session.truncated then return end
        if ev.kind == "match" then
            local entry = session.file_map[ev.file]
            if not entry then
                entry = { file = ev.file, expanded = true, matches = {} }
                session.file_map[ev.file] = entry
                table.insert(session.files, entry)
            end
            table.insert(entry.matches, { lnum = ev.lnum, col = ev.col, text = ev.text, match_len = ev.match_len })
            session.match_count = session.match_count + 1
            if session.match_count >= M.MAX_RESULTS then
                -- 到上限：停掉 rg，保留已有结果 + truncated 提示。
                -- 不换代号，让 on_done 照常收尾渲染。
                session.truncated = true
                if session.job_id then pcall(vim.fn.jobstop, session.job_id) end
                if session.stream_sid then pcall(cmd.cancel, session.stream_sid) end
            end
            schedule_render(session)
        elseif ev.kind == "stderr" then
            -- stderr 只留前 4KB，够诊断
            local buf = session._stderr_buf or ""
            if #buf < 4096 then session._stderr_buf = buf .. ev.text end
        elseif ev.kind == "parse_error" then
            session._parse_errors = session._parse_errors + 1
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
            -- 主动 cancel 已经换过代号走不到这里；能到这里的是 daemon 侧中断
            -- （连接断 / daemon 退出），提示一下。
            if not reason:match("^cancelled") then
                log.warn("Search: search aborted (" .. reason .. ")")
            end
        elseif code and code >= 2 then
            -- rg 退出码：0 = 有匹配；1 = 无匹配；2 = 出错（但可能已有部分结果，
            -- 例如部分文件无权限读取）→ 有结果时降级成 warning
            local msg = (session._stderr_buf or ""):gsub("^sh: %d+: ", "")
            if msg == "" then msg = "rg exited with code " .. tostring(code) end
            if has_results then
                log.warn("Search: rg reported errors (partial results):\n" .. msg)
            else
                log.error("Search: " .. msg)
            end
        end
        if session._parse_errors > 0 and not has_results then
            log.warn(("Search: rg --json 解析失败 %d 行（远端 rg 可能太老或不存在）"):format(session._parse_errors))
        end

        M.render_tree()
        if M.last.selected_index > 0 and #session.nodes > 0 then
            M.set_selection(math.min(M.last.selected_index, #session.nodes))
            M.last.selected_index = 0
        end
    end

    return on_event, on_done
end

local function start_local(session, args, on_event, on_done)
    local parser = rg_parser.new()
    session._local_parser = parser
    local function feed_all(events)
        for _, ev in ipairs(events or {}) do on_event(ev) end
    end
    local job_id = vim.fn.jobstart(args, {
        on_stdout = function(_, data)
            if data and #data > 0 then feed_all(parser:feed(table.concat(data, "\n"))) end
        end,
        on_stderr = function(_, data)
            local s = data and table.concat(data, "\n") or ""
            if #s > 0 then on_event({ kind = "stderr", text = s }) end
        end,
        on_exit = function(_, code)
            if session._local_parser == parser then feed_all(parser:finalize()) end
            on_done(code, nil)
        end,
    })
    if job_id <= 0 then
        session._local_parser = nil
        log.error("Search: failed to start rg (" .. (job_id == -1 and "rg not found in PATH" or "invalid arguments") .. ")")
        return
    end
    session.job_id = job_id
end

local function start_remote(session, args, on_event, on_done, is_live)
    local sid, err = cmd.stream({ user = session.user, host = session.host, port = session.port }, {
        argv = cmd.with_remote_path(args),
        parser = rg_parser.new(),
        owner_buf = session.results_buf,
        owner_win = session.results_win,
    }, {
        on_event = on_event,
        on_exit = function(code, _signal, reason) on_done(code, reason) end,
    })
    if not sid then
        log.error("Search: cmd.stream failed: " .. tostring(err))
        return
    end
    -- stream 启动期间（同步 RPC）UI 可能已被关掉 / 已换代
    if not is_live() then
        pcall(cmd.cancel, sid)
        return
    end
    session.stream_sid = sid
end

--- 按 path / query 输入框和 toggle_state 重新搜索（取消在飞的上一轮）。
function M.execute_search()
    local session = M.current_session
    if not session or session.closed then return end

    local path = vim.api.nvim_buf_get_lines(session.path_buf, 0, 1, false)[1] or "/"
    local query = vim.api.nvim_buf_get_lines(session.input_buf, 0, 1, false)[1] or ""
    local ts = session.toggle_state
    M.last.query = query
    M.last.path = path
    M.last.case_sensitive = ts.case_sensitive
    M.last.whole_word = ts.whole_word
    M.last.file_types = ts.file_types

    cancel_inflight(session)
    -- 先换代号再决定是否 early return：清空 query 时旧 stream 的迟到结果
    -- 不能再回填列表
    session.id = next_gen()
    local gen = session.id
    reset(session, query)
    if query == "" or path == "" then return end

    local function is_live()
        return M.current_session == session and not session.closed and session.id == gen
    end
    local on_event, on_done = make_handlers(session, is_live)
    local args = build_rg_args(query, path, ts)
    if session.is_local then
        start_local(session, args, on_event, on_done)
    else
        start_remote(session, args, on_event, on_done, is_live)
    end
end

-- =============================================================================
-- 打开
-- =============================================================================

local function open_selected(session)
    local node = session.nodes[session.selected_index]
    if not node or node.type == "spacer" then return end
    if node.type == "file" then return M.toggle_fold() end

    M.close_ui(session)
    local target = session.is_local and node.file or uri.format(session.user, session.host, session.port, node.file)
    vim.cmd("edit " .. vim.fn.fnameescape(target))
    vim.schedule(function()
        pcall(vim.api.nvim_win_set_cursor, 0, { node.lnum, math.max(0, node.col - 1) })
        vim.cmd("normal! zz")
    end)
end

---@param opts { is_local?: boolean, user?: string, host?: string, port?: integer, initial_path?: string }
function M.open_ui(opts)
    local title
    if opts.is_local then
        title = "Local"
    else
        local chan, err = remote.ensure_connection(opts.user, opts.host, opts.port)
        if not chan then
            log.error("Cannot connect for search: " .. tostring(err))
            return
        end
        title = string.format("%s@%s:%s", opts.user, opts.host, opts.port)
    end

    -- 旧 UI 还开着（比如 WinClosed 之外的路径漏关）：先完整 teardown
    if M.current_session then M.close_ui() end
    define_highlights()

    local session = {
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
        toggle_state = {
            case_sensitive = M.last.case_sensitive,
            whole_word = M.last.whole_word,
            file_types = vim.deepcopy(M.last.file_types),
        },
    }
    M.current_session = session

    -- 回调全部绑定到这个 session：防抖 timer / WinClosed 的 vim.schedule
    -- 迟到时不能作用到下一次打开的 session 上
    local function live(fn)
        return function(...)
            if M.current_session == session and not session.closed then return fn(...) end
        end
    end

    view.open(session, {
        title = title,
        path = opts.initial_path or M.last.path or "/",
        query = M.last.query or "",
    }, {
        on_change = live(M.execute_search),
        on_close = function() M.close_ui(session) end,
        on_enter = live(function() open_selected(session) end),
        on_toggle_fold = live(M.toggle_fold),
        on_select_next = live(function() M.set_selection(session.selected_index + 1) end),
        -- 返回 true = 已在第一项，交给 view 把焦点移回 query
        on_select_prev = live(function()
            if session.selected_index <= 1 then return true end
            M.set_selection(session.selected_index - 1)
            return false
        end),
    })

    if M.last.query ~= "" then
        vim.cmd("stopinsert")
        M.execute_search()
        view.focus(session, "results")
    end
end

function M.live_grep()
    local user, host, port, path = uri.parse(vim.api.nvim_buf_get_name(0))
    if not user then
        return M.open_ui({ is_local = true, initial_path = vim.fn.getcwd() })
    end
    local dir = path:match("/$") and path or vim.fs.dirname(path)
    if dir == "" or dir == "." then dir = "/" end
    M.open_ui({ user = user, host = host, port = port, initial_path = dir })
end

return M
