--- :ZeroSearch 的四窗口浮窗布局（path / query / results / preview）+ 按键。
--- 状态与搜索逻辑都在 search/init.lua；这里只建窗口、绑键、改 footer。
local float = require("zero-nvim.ui.float")
local util = require("zero-nvim.util")
local type_picker = require("zero-nvim.search.type_picker")

local M = {}

local ui_seq = 0
local DEBOUNCE_MS = 350

local WINHL = {
    prompt = "NormalFloat:TelescopePromptNormal,FloatBorder:TelescopePromptBorder",
    results = "NormalFloat:TelescopeResultsNormal,FloatBorder:TelescopeResultsBorder",
    preview = "NormalFloat:TelescopePreviewNormal,FloatBorder:TelescopePreviewBorder",
}

local WIN_FIELD = { path = "path_win", query = "input_win", results = "results_win" }

--- 聚焦某个输入/结果窗口并记录到 session.focus
---@param name "path"|"query"|"results"
function M.focus(session, name)
    local win = session[WIN_FIELD[name]]
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        session.focus = name
    end
end

--- 按 session.toggle_state 刷新 path（类型）和 query（Aa / word）两个 footer
function M.update_footers(session)
    local ts = session.toggle_state
    if vim.api.nvim_win_is_valid(session.input_win) then
        vim.api.nvim_win_set_config(session.input_win,
            { footer = float.toggle_footer(ts.case_sensitive, ts.whole_word), footer_pos = "right" })
    end
    if vim.api.nvim_win_is_valid(session.path_win) then
        local label = #ts.file_types == 0 and "*" or table.concat(ts.file_types, ",")
        vim.api.nvim_win_set_config(session.path_win,
            { footer = string.format("  [%s] C-t:Type  ", label), footer_pos = "right" })
    end
end

local function open_win(buf, enter, cfg, winhl)
    local win = vim.api.nvim_open_win(buf, enter, vim.tbl_extend("force", {
        relative = "editor",
        style = "minimal",
        border = "rounded",
        title_pos = "center",
    }, cfg))
    vim.wo[win].winhl = winhl
    return win
end

--- 输入 buffer 改动后防抖回调。timer 由 search.close_ui teardown 时关闭；
--- 关闭后 on_lines 返回 true 自动 detach。
local function debounce_on_lines(buf, cb)
    local timer = (vim.uv or vim.loop).new_timer()
    vim.api.nvim_buf_attach(buf, false, {
        on_lines = function()
            if timer:is_closing() then return true end
            timer:stop()
            timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
                if not timer:is_closing() then cb() end
            end))
        end,
    })
    return timer
end

--- 创建并打开搜索 UI，窗口 / buffer / timer / augroup 字段直接写进 session。
---@param session table 需已含 toggle_state = { case_sensitive, whole_word, file_types }
---@param opts { title: string, path: string, query: string }
---@param cb table { on_change, on_close, on_enter, on_select_next, on_select_prev, on_toggle_fold }
function M.open(session, opts, cb)
    local ew, eh = util.editor_size()
    local w, h = math.floor(ew * 0.85), math.floor(eh * 0.85)
    local r, c = math.floor((eh - h) / 2), math.floor((ew - w) / 2)
    local rw = math.floor(w * 0.4)
    local body_h = h - 6

    session.path_buf = vim.api.nvim_create_buf(false, true)
    session.input_buf = vim.api.nvim_create_buf(false, true)
    session.results_buf = vim.api.nvim_create_buf(false, true)
    session.preview_buf = vim.api.nvim_create_buf(false, true)

    session.path_win = open_win(session.path_buf, true, {
        row = r, col = c, width = w, height = 1,
        title = string.format(" 📂 Search Path (%s) ", opts.title),
    }, WINHL.prompt)
    session.input_win = open_win(session.input_buf, false, {
        row = r + 3, col = c, width = w, height = 1,
        title = " 🔍 Keywords ",
    }, WINHL.prompt)
    session.results_win = open_win(session.results_buf, false, {
        row = r + 6, col = c, width = rw, height = body_h,
        title = " Results ",
        footer = " j/k/h/l:Nav | C-w:Word | C-c:Case ", footer_pos = "left",
    }, WINHL.results)
    vim.wo[session.results_win].cursorline = false
    session.preview_win = open_win(session.preview_buf, false, {
        row = r + 6, col = c + rw + 2, width = w - rw - 2, height = body_h,
        title = " Preview ",
        footer = " CR:Open | i:Insert | q/Esc:Quit ", footer_pos = "right",
    }, WINHL.preview)

    vim.bo[session.results_buf].modifiable = false
    vim.bo[session.preview_buf].modifiable = false
    session.ns = vim.api.nvim_create_namespace("ZeroSearchUI")
    vim.api.nvim_buf_set_lines(session.path_buf, 0, -1, false, { opts.path })
    vim.api.nvim_buf_set_lines(session.input_buf, 0, -1, false, { opts.query })
    vim.api.nvim_win_set_cursor(session.input_win, { 1, #opts.query })
    M.update_footers(session)

    -- 先写入初始内容再 attach，避免恢复上次 query 时触发一次防抖搜索
    session.timer1 = debounce_on_lines(session.path_buf, cb.on_change)
    session.timer2 = debounce_on_lines(session.input_buf, cb.on_change)

    local ts = session.toggle_state
    local function toggle(field)
        return function()
            ts[field] = not ts[field]
            M.update_footers(session)
            cb.on_change()
        end
    end
    local function open_type_picker()
        vim.cmd("stopinsert")
        type_picker.open({
            row = r + 3,
            col = c + w - 30,
            selected = ts.file_types,
            on_close = function(types)
                ts.file_types = types
                M.update_footers(session)
                M.focus(session, "query")
                cb.on_change()
            end,
        })
    end
    local function focus(name) return function() M.focus(session, name) end end
    local function prev_or_query()
        if cb.on_select_prev() then M.focus(session, "query") end
    end

    -- 三个 buffer 共用的按键
    for _, buf in ipairs({ session.path_buf, session.input_buf, session.results_buf }) do
        local o = { buffer = buf, silent = true }
        local now = { buffer = buf, silent = true, nowait = true }
        vim.keymap.set("n", "q", cb.on_close, o)
        vim.keymap.set("n", "<Esc>", cb.on_close, o)
        -- C-c 切大小写（不是关闭）
        vim.keymap.set({ "i", "n" }, "<C-c>", toggle("case_sensitive"), now)
        vim.keymap.set({ "i", "n" }, "<C-w>", toggle("whole_word"), now)
        vim.keymap.set({ "i", "n" }, "<C-t>", open_type_picker, now)
        -- 只有 path / query 输入框里 i 才进 insert
        vim.keymap.set("n", "i", function()
            local cur = vim.api.nvim_get_current_win()
            if cur == session.path_win or cur == session.input_win then vim.cmd("startinsert") end
        end, o)
        -- insert 里 Esc → 跳到结果
        vim.keymap.set("i", "<Esc>", function()
            vim.cmd("stopinsert")
            M.focus(session, "results")
        end, o)
        vim.keymap.set({ "i", "n" }, "<CR>", cb.on_enter, o)
    end

    -- 各窗口的导航：path ↓ query ↓ results；results 顶部再 k 回 query
    local nav = {
        [session.path_buf] = { j = focus("query"), ["<Down>"] = focus("query"), J = focus("query") },
        [session.input_buf] = {
            k = focus("path"), ["<Up>"] = focus("path"), K = focus("path"),
            j = focus("results"), ["<Down>"] = focus("results"), J = focus("results"),
        },
        [session.results_buf] = {
            k = prev_or_query, ["<Up>"] = prev_or_query,
            j = cb.on_select_next, ["<Down>"] = cb.on_select_next,
            K = focus("query"), J = focus("path"),
            h = cb.on_toggle_fold, l = cb.on_toggle_fold,
            ["<Left>"] = cb.on_toggle_fold, ["<Right>"] = cb.on_toggle_fold,
        },
    }
    for buf, maps in pairs(nav) do
        for lhs, fn in pairs(maps) do
            vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true })
        end
    end

    -- 任一浮窗被关闭（:q / <C-w>o / :only 等非 q/<Esc> 路径）→ 整个 UI 一起关。
    -- 每个 UI 实例一个 augroup，teardown 时由 search.close_ui 删除。
    ui_seq = ui_seq + 1
    session.augroup = vim.api.nvim_create_augroup("ZeroSearchUI_" .. ui_seq, { clear = true })
    for _, win in ipairs({ session.path_win, session.input_win, session.results_win, session.preview_win }) do
        vim.api.nvim_create_autocmd("WinClosed", {
            group = session.augroup,
            pattern = tostring(win),
            once = true,
            -- WinClosed 期间不能关别的窗口，延到下一 tick
            callback = function() vim.schedule(cb.on_close) end,
        })
    end

    M.focus(session, "query")
    vim.cmd("startinsert!")
end

return M
