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

local autocmd_group
local function get_group()
    if not autocmd_group then
        autocmd_group = vim.api.nvim_create_augroup("ZeroNvimCmdAutoCancel", { clear = false })
    end
    return autocmd_group
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

    -- 自动 cancel：buffer wipeout
    if spec.owner_buf and vim.api.nvim_buf_is_valid(spec.owner_buf) then
        vim.api.nvim_create_autocmd("BufWipeout", {
            group = get_group(),
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
            group = get_group(),
            pattern = tostring(spec.owner_win),
            once = true,
            callback = function()
                M.cancel(sid)
            end,
        })
    end

    return sid
end

--- 从 daemon 端发起 cancel。仅设置 flag，不立刻清理 _sessions——等 daemon 的
--- exit/aborted 事件回来再删，才能拿到真实退出信息。
function M.cancel(sid)
    local s = M._sessions[sid]
    if not s or s.cancelled then return end
    s.cancelled = true
    local zero = require("zero-nvim")
    local chan = zero._get_daemon_chan()
    if chan then
        pcall(vim.fn.rpcnotify, chan, "cmd_cancel", sid)
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
    if not s then return end

    if kind == "stdout" then
        if s.parser and s.parser.feed then
            local events = s.parser:feed(payload)
            if events then
                for _, ev in ipairs(events) do
                    s.on_event(ev)
                end
            end
        else
            s.on_event({ kind = "stdout", text = payload })
        end
    elseif kind == "stderr" then
        if s.parser and s.parser.feed_err then
            local events = s.parser:feed_err(payload)
            if events then
                for _, ev in ipairs(events) do
                    s.on_event(ev)
                end
            end
        else
            s.on_event({ kind = "stderr", text = payload })
        end
    elseif kind == "exit" then
        -- payload = { code, signal_or_nil, duration_ms }
        if s.parser and s.parser.finalize then
            local tail = s.parser:finalize() or {}
            for _, ev in ipairs(tail) do
                s.on_event(ev)
            end
        end
        s.finished = true
        local code = payload[1] or -1
        local signal = payload[2]
        local duration_ms = payload[3] or 0
        s.on_exit(code, signal, nil, duration_ms)
        M._sessions[sid] = nil
    elseif kind == "aborted" then
        if s.parser and s.parser.finalize then
            local tail = s.parser:finalize() or {}
            for _, ev in ipairs(tail) do
                s.on_event(ev)
            end
        end
        s.finished = true
        local reason = type(payload) == "string" and payload or "aborted"
        s.on_exit(-1, nil, reason, 0)
        M._sessions[sid] = nil
    end
end

--- 调试辅助：当前活跃 session 数
function M.active_count()
    local n = 0
    for _ in pairs(M._sessions) do n = n + 1 end
    return n
end

return M
