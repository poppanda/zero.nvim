-- =============================================================================
-- cmd/exec.lua — 流式命令的 session 注册 + 自动 cancel + 事件分发
-- =============================================================================
-- 职责：
--   1. 维护 _sessions[sid] 注册表
--   2. 接收 daemon 的 nvim_exec_lua 通知 (_dispatch 入口)
--   3. 根据 owner_buf / owner_win 的 BufWipeout / WinClosed 触发自动 cancel
--   4. parser:feed / feed_err / finalize 调用，把字节流翻译成 events
--
-- 这里不暴露用户 API，用户调用 cmd/init.lua 的 sync / sync_full / stream

local M = {}

-- session_id → session table
M._sessions = {}

local sid_counter = 0
local function gen_sid()
    sid_counter = sid_counter + 1
    return string.format("%d-%d", vim.loop.now(), sid_counter)
end

--- 回调保护：用户 on_event / on_exit 抛错不能打断 session 清理，也不能让
--- daemon 的 nvim_exec_lua 调用失败。错误异步 notify（可能处在 textlock 里）。
local function report(label, err)
    vim.schedule(function()
        vim.notify(("[zero-nvim/cmd] %s error: %s"):format(label, tostring(err)), vim.log.levels.ERROR)
    end)
end

local function safe_call(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then report(label, err) end
    return ok
end

local function delete_group(s)
    if s and s.augroup then
        pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
        s.augroup = nil
    end
end

--- 注册一条流式 session。返回 session_id。
---@param spec table { parser, on_event, on_exit, owner_buf?, owner_win? }
function M.register(spec)
    local sid = gen_sid()
    local session = {
        id = sid,
        parser = spec.parser,
        on_event = spec.on_event or function() end,
        on_exit = spec.on_exit or function() end,
        cancelled = false,
        finished = false,
    }
    M._sessions[sid] = session

    -- 每个 session 一个 augroup：结束时整组删除，避免 autocmd 随击键无限累积
    local need_group = (spec.owner_buf and vim.api.nvim_buf_is_valid(spec.owner_buf))
        or (spec.owner_win and vim.api.nvim_win_is_valid(spec.owner_win))
    if need_group then
        session.augroup = vim.api.nvim_create_augroup("ZeroNvimCmdAutoCancel_" .. sid, { clear = true })
    end

    -- 自动 cancel：buffer wipeout
    if spec.owner_buf and vim.api.nvim_buf_is_valid(spec.owner_buf) then
        vim.api.nvim_create_autocmd("BufWipeout", {
            group = session.augroup,
            buffer = spec.owner_buf,
            once = true,
            callback = function()
                M.cancel(sid)
            end,
        })
    end

    -- 自动 cancel：window closed
    if spec.owner_win and vim.api.nvim_win_is_valid(spec.owner_win) then
        vim.api.nvim_create_autocmd("WinClosed", {
            group = session.augroup,
            pattern = tostring(spec.owner_win),
            once = true,
            callback = function()
                M.cancel(sid)
            end,
        })
    end

    return sid
end

--- 静默注销（不回调）：用于 cmd_stream 启动失败时回滚 register。
function M.unregister(sid)
    local s = M._sessions[sid]
    M._sessions[sid] = nil
    delete_group(s)
end

--- 收尾：先从注册表摘除 + 删 augroup，再 finalize / on_exit——任何回调抛错
--- 都不会让 session 泄漏。cancelled session 的 finalize 尾巴事件也丢弃。
---@param s table session
---@param code integer
---@param signal any
---@param reason string?  nil = 正常 exit；非 nil = aborted 原因
---@param duration_ms integer
local function finish(s, code, signal, reason, duration_ms)
    if s.finished then return end
    s.finished = true
    if M._sessions[s.id] == s then M._sessions[s.id] = nil end
    delete_group(s)

    if s.parser and s.parser.finalize then
        local ok, tail = pcall(s.parser.finalize, s.parser)
        if not ok then report("parser", tail) end
        if ok and type(tail) == "table" and not s.cancelled then
            for _, ev in ipairs(tail) do
                safe_call("on_event", s.on_event, ev)
            end
        end
    end
    safe_call("on_exit", s.on_exit, code, signal, reason, duration_ms)
end

--- 从 daemon 端发起 cancel。仅设置 flag，不立刻清理 _sessions——等 daemon 的
--- exit/aborted 事件回来再删，才能拿到真实退出信息。
--- daemon 不在（channel 没了 / notify 失败）时不会再有事件回来，直接本地收尾。
function M.cancel(sid)
    local s = M._sessions[sid]
    if not s or s.cancelled then return end
    s.cancelled = true
    local ok_req, zero = pcall(require, "zero-nvim")
    local chan = ok_req and zero._get_daemon_chan and zero._get_daemon_chan() or nil
    local sent = false
    if chan then
        sent = pcall(vim.fn.rpcnotify, chan, "cmd_cancel", sid)
    end
    if not sent then
        finish(s, -1, nil, "cancelled: daemon not running", 0)
    end
end

--- 喂 parser 并分发事件；cancel 之后的 stdout/stderr 一律丢弃。
local function feed(s, method, fallback_kind, payload)
    if s.cancelled then return end
    if s.parser and s.parser[method] then
        local ok, events = pcall(s.parser[method], s.parser, payload)
        if not ok then
            report("parser", events)
            return
        end
        if type(events) == "table" then
            for _, ev in ipairs(events) do
                -- 回调里可能 cancel 了自己：剩下的事件也不再投递
                if s.cancelled or s.finished then return end
                safe_call("on_event", s.on_event, ev)
            end
        end
    else
        safe_call("on_event", s.on_event, { kind = fallback_kind, text = payload })
    end
end

--- daemon → Lua 的统一入口。daemon 通过：
---   nvim_exec_lua("require('zero-nvim.cmd.exec')._dispatch(...)", [sid, kind, payload])
--- 调用此函数。
---@param sid string
---@param kind string  "stdout" | "stderr" | "exit" | "aborted"
---@param payload any
function M._dispatch(sid, kind, payload)
    local s = M._sessions[sid]
    if not s or s.finished then return end

    if kind == "stdout" then
        feed(s, "feed", "stdout", payload)
    elseif kind == "stderr" then
        feed(s, "feed_err", "stderr", payload)
    elseif kind == "exit" then
        -- payload = { code, signal_or_nil, duration_ms }
        payload = type(payload) == "table" and payload or {}
        finish(s, payload[1] or -1, payload[2], nil, payload[3] or 0)
    elseif kind == "aborted" then
        local reason = type(payload) == "string" and payload or "aborted"
        finish(s, -1, nil, reason, 0)
    end
end

--- daemon 进程死亡时由 init.lua 调用：所有在飞 session 走 aborted 收尾
--- （finalize + on_exit(-1, nil, reason, 0)），然后清空注册表。可重复调用。
---@param reason string?
function M.abort_all(reason)
    reason = reason or "aborted: daemon exited"
    local pending = M._sessions
    M._sessions = {}
    for _, s in pairs(pending) do
        finish(s, -1, nil, reason, 0)
    end
end

--- 调试辅助：当前活跃 session 数
function M.active_count()
    local n = 0
    for _ in pairs(M._sessions) do n = n + 1 end
    return n
end

return M
