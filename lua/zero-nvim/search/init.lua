--- :ZeroSearch 控制器：rg 调度（本地 jobstart / 远端 cmd.stream）、结果状态、
--- 选择与预览。窗口 / 渲染在 search/view.lua。
local M = {}

local uri = require("zero-nvim.uri")
local cmd = require("zero-nvim.cmd")
local log = require("zero-nvim.log")
local util = require("zero-nvim.util")
local remote = require("zero-nvim.remote")
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
local MAX_RESULTS = 5000
-- 预览防抖（ms）：j/k 连按时不对每一行都同步拉远端文件
local PREVIEW_DEBOUNCE_MS = 100
-- 增量渲染节流（ms）：流式结果每批最多重绘一次
local RENDER_THROTTLE_MS = 50

-- 单调递增的搜索代号：每次 run_search（包括清空 query）都会 +1，
-- 旧 stream 的迟到事件靠它丢弃。vim.loop.now() 同一毫秒内会撞。
local search_gen = 0
local function next_gen()
    search_gen = search_gen + 1
    return search_gen
end

local uv = vim.uv or vim.loop

local function is_open(session)
    return M.current_session == session and not session.closed
end

local function build_rg_args(query, path, ts)
    -- --max-columns：超长行（minified js / 单行 json）只给预览片段，避免几 MB
    -- 的行塞进 msgpack + 渲染
    local args = { "rg", "--json", "--max-columns=500", "--max-columns-preview" }
    table.insert(args, ts.case_sensitive and "--case-sensitive" or "--ignore-case")
    if ts.whole_word then table.insert(args, "--word-regexp") end
    for _, ft in ipairs(ts.file_types) do
        if type_picker.is_builtin(ft) then
            vim.list_extend(args, { "--type", ft })
        else
            vim.list_extend(args, { "--glob", "*." .. ft })
        end
    end
    return vim.list_extend(args, { "--", query, path })
end

-- =============================================================================
-- 选择 / 预览
-- =============================================================================

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
    if not is_open(session) then return end

    local node = session.nodes[session.selected_index]
    if not node or node.type == "spacer" then
        session.preview_key = nil
        return view.show_preview(session, node, nil)
    end

    -- 每次重绘都会 set_selection；同一节点不重复刷新预览
    local key = node.file .. "\n" .. tostring(node.lnum) .. ":" .. tostring(node.col)
    if session.preview_key == key then return end

    local content = session.file_cache[node.file]
    if content == nil then
        content = read_content(session, node.file) or false
        session.file_cache[node.file] = content
        -- 同步拉取期间 UI 可能已被关闭
        if not is_open(session) then return end
    end
    session.preview_key = key
    view.show_preview(session, node, content)
end

--- 防抖预览：选择变化后 PREVIEW_DEBOUNCE_MS 内没有新变化才真正拉文件。
local function schedule_preview(session)
    if session.closed then return end
    session.preview_timer = session.preview_timer or uv.new_timer()
    session.preview_timer:stop()
    session.preview_timer:start(PREVIEW_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
        render_preview(session)
    end))
end

--- 选中第 idx 个节点；落在 spacer 上时沿移动方向再跳一格。
local function set_selection(session, idx)
    if #session.nodes == 0 then return end
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
    view.highlight_row(session, idx)
    schedule_preview(session)
end

--- 重绘结果树并维持选中项。上次关闭 UI 时的选中位置（M.last.selected_index）
--- 等结果足够多时恢复；final（搜索结束）时结果不够也恢复（夹到最后一项）。
local function render(session, final)
    session.nodes = view.render_results(session, session.truncated and MAX_RESULTS or nil)
    local restore = M.last.selected_index
    if restore == 0 then
        set_selection(session, math.max(1, session.selected_index))
    elseif #session.nodes > 0 and (final or #session.nodes >= restore) then
        M.last.selected_index = 0
        set_selection(session, restore)
    end
end

local function schedule_render(session)
    if session.render_scheduled then return end
    session.render_scheduled = true
    vim.defer_fn(function()
        session.render_scheduled = false
        if is_open(session) then render(session) end
    end, RENDER_THROTTLE_MS)
end

local function toggle_fold(session)
    local node = session.nodes[session.selected_index]
    if node and node.type == "file" then
        node.ref.expanded = not node.ref.expanded
        render(session)
    end
end

-- =============================================================================
-- 执行搜索
-- =============================================================================

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
    session.local_parser = nil
end

--- 新一轮搜索前清空 session 的结果状态和两个 buffer
local function reset(session, query)
    session.query = query
    session.files = {}
    session.file_map = {}
    session.nodes = {}
    session.selected_index = 0
    session.match_count = 0
    session.truncated = false
    session.stderr = ""
    session.parse_errors = 0
    session.preview_key = nil
    view.clear(session)
end

--- rg 结束（或被 daemon 中断）时汇报错误
local function report_exit(session, code, reason)
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
        local msg = session.stderr:gsub("^sh: %d+: ", "")
        if msg == "" then msg = "rg exited with code " .. tostring(code) end
        if has_results then
            log.warn("Search: rg reported errors (partial results):\n" .. msg)
        else
            log.error("Search: " .. msg)
        end
    end
    if session.parse_errors > 0 and not has_results then
        log.warn(("Search: rg --json 解析失败 %d 行（远端 rg 可能太老或不存在）"):format(session.parse_errors))
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
            if session.match_count >= MAX_RESULTS then
                -- 到上限：停掉 rg，保留已有结果 + truncated 提示。
                -- 不换代号，让 on_done 照常收尾渲染。
                session.truncated = true
                if session.job_id then pcall(vim.fn.jobstop, session.job_id) end
                if session.stream_sid then pcall(cmd.cancel, session.stream_sid) end
            end
            schedule_render(session)
        elseif ev.kind == "stderr" then
            -- stderr 只留前 4KB，够诊断
            if #session.stderr < 4096 then session.stderr = session.stderr .. ev.text end
        elseif ev.kind == "parse_error" then
            session.parse_errors = session.parse_errors + 1
        end
        -- file_begin / file_end 忽略：match 上来时 lazy 创建条目
    end

    local function on_done(code, reason)
        if not is_live() then return end
        session.job_id = nil
        session.stream_sid = nil
        session.local_parser = nil
        report_exit(session, code, reason)
        render(session, true)
    end

    return on_event, on_done
end

local function start_local(session, args, on_event, on_done)
    local parser = rg_parser.new()
    session.local_parser = parser
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
            -- 已被 cancel_inflight 换掉的 parser 不再 flush
            if session.local_parser == parser then feed_all(parser:finalize()) end
            on_done(code, nil)
        end,
    })
    if job_id <= 0 then
        session.local_parser = nil
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
local function run_search(session)
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
        return is_open(session) and session.id == gen
    end
    local on_event, on_done = make_handlers(session, is_live)
    local args = build_rg_args(query, path, ts)
    if session.is_local then
        start_local(session, args, on_event, on_done)
    else
        start_remote(session, args, on_event, on_done, is_live)
    end
end

--- 对当前打开的 UI 重新搜索
function M.execute_search()
    local session = M.current_session
    if session and not session.closed then run_search(session) end
end

-- =============================================================================
-- 打开 / 关闭
-- =============================================================================

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
    M.last.selected_index = session.selected_index
    if M.current_session == session then
        M.current_session = nil
    end
    vim.cmd("stopinsert")
end

local function open_selected(session)
    local node = session.nodes[session.selected_index]
    if not node or node.type == "spacer" then return end
    if node.type == "file" then return toggle_fold(session) end

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

    local session = {
        is_local = opts.is_local,
        user = opts.user,
        host = opts.host,
        port = opts.port,
        files = {},
        file_map = {},
        file_cache = {},
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
        return function()
            if is_open(session) then return fn(session) end
        end
    end

    view.open(session, {
        title = title,
        path = opts.initial_path or M.last.path or "/",
        query = M.last.query,
    }, {
        on_change = live(run_search),
        on_close = function() M.close_ui(session) end,
        on_enter = live(open_selected),
        on_toggle_fold = live(toggle_fold),
        on_select_next = live(function() set_selection(session, session.selected_index + 1) end),
        -- 返回 true = 已在第一项，交给 view 把焦点移回 query
        on_select_prev = live(function()
            if session.selected_index <= 1 then return true end
            set_selection(session, session.selected_index - 1)
            return false
        end),
    })

    if M.last.query ~= "" then
        vim.cmd("stopinsert")
        run_search(session)
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
