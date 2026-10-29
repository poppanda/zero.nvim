-- cmd/exec.lua：事件顺序、cancel 后丢弃事件、abort_all、回调抛错不泄漏 session
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local chan = 7
local notified = {}
local cancels = {}
package.loaded["zero-nvim.daemon"] = {
    channel = function() return chan end,
}
vim.fn.rpcnotify = function(c, method, sid)
    table.insert(cancels, { chan = c, method = method, sid = sid })
    return 0
end
vim.notify = function(msg, level)
    table.insert(notified, { msg = msg, level = level })
end

local exec = require("zero-nvim.cmd.exec")
local parsers = require("zero-nvim.cmd.parsers")

local function check(cond, msg)
    if not cond then error(msg, 2) end
end
local function flush() vim.wait(20, function() return false end) end

local function new_session(parser, extra)
    local log = { events = {}, exits = {} }
    local spec = {
        parser = parser,
        on_event = function(ev) table.insert(log.events, ev) end,
        on_exit = function(code, signal, reason, dur)
            table.insert(log.exits, { code = code, signal = signal, reason = reason, dur = dur })
        end,
    }
    for k, v in pairs(extra or {}) do spec[k] = v end
    return exec.register(spec), log
end

-- 1. 事件顺序 + finalize 尾巴在 on_exit 之前 + exit 之后 session 被移除
do
    local sid, log = new_session(parsers.lines())
    exec._dispatch(sid, "stdout", "a\nb")
    exec._dispatch(sid, "stderr", "warn")
    exec._dispatch(sid, "stdout", "c\nd")
    exec._dispatch(sid, "exit", { 0, nil, 12 })
    local kinds = {}
    for _, ev in ipairs(log.events) do kinds[#kinds + 1] = ev.kind .. ":" .. ev.text end
    check(table.concat(kinds, ",") == "line:a,stderr:warn,line:bc,line:d",
        "event ordering: " .. table.concat(kinds, ","))
    check(#log.exits == 1 and log.exits[1].code == 0 and log.exits[1].reason == nil and log.exits[1].dur == 12,
        "exit payload")
    check(exec._sessions[sid] == nil, "session removed after exit")
    -- 迟到事件被忽略
    exec._dispatch(sid, "stdout", "late\n")
    exec._dispatch(sid, "exit", { 1 })
    check(#log.events == 4 and #log.exits == 1, "late events after exit must be ignored")
end

-- 2. cancel 后 stdout/stderr 被丢弃，最终 aborted 只投递一次
do
    local sid, log = new_session(parsers.lines())
    exec._dispatch(sid, "stdout", "one\n")
    exec.cancel(sid)
    check(cancels[#cancels].method == "cmd_cancel" and cancels[#cancels].sid == sid, "cmd_cancel notified")
    exec.cancel(sid) -- 重复 cancel 不再发 notify
    local n_cancels = #cancels
    exec._dispatch(sid, "stdout", "two\npartial")
    exec._dispatch(sid, "stderr", "err")
    check(#log.events == 1, "events after cancel must be dropped, got " .. #log.events)
    exec._dispatch(sid, "aborted", "cancelled (exit=143)")
    exec._dispatch(sid, "aborted", "cancelled (exit=143)")
    check(#log.exits == 1 and log.exits[1].reason == "cancelled (exit=143)" and log.exits[1].code == -1,
        "aborted delivered once with reason")
    check(#log.events == 1, "finalize tail of cancelled session must be dropped")
    check(exec._sessions[sid] == nil and #cancels == n_cancels, "cancelled session cleaned")
end

-- 3. daemon 不在时 cancel 直接本地收尾
do
    chan = nil
    local sid, log = new_session(nil)
    exec.cancel(sid)
    check(#log.exits == 1 and log.exits[1].reason:match("^cancelled"), "cancel without daemon finishes locally")
    check(exec._sessions[sid] == nil, "session removed")
    chan = 7
end

-- 4. 回调抛错不泄漏 session，也不向上抛
do
    local sid = exec.register({
        parser = parsers.lines(),
        on_event = function() error("on_event boom") end,
        on_exit = function() error("on_exit boom") end,
    })
    local ok = pcall(exec._dispatch, sid, "stdout", "x\n")
    check(ok, "_dispatch must not propagate on_event errors")
    ok = pcall(exec._dispatch, sid, "exit", { 0 })
    check(ok, "_dispatch must not propagate on_exit errors")
    check(exec._sessions[sid] == nil, "session leaked after on_exit error")
    flush()
    local saw = 0
    for _, n in ipairs(notified) do
        if n.msg:match("boom") then saw = saw + 1 end
    end
    check(saw >= 2, "callback errors should be reported, saw " .. saw)
end

-- 5. owner_buf：BufWipeout 触发 cancel；结束后 augroup 被删
do
    local buf = vim.api.nvim_create_buf(false, true)
    local sid, log = new_session(nil, { owner_buf = buf })
    local s = exec._sessions[sid]
    check(s.augroup ~= nil, "owner_buf session should own an augroup")
    local group = s.augroup
    vim.api.nvim_buf_delete(buf, { force = true })
    check(s.cancelled, "BufWipeout should cancel the session")
    exec._dispatch(sid, "aborted", "cancelled: owner gone")
    check(#log.exits == 1, "exit after wipeout")
    local ok = pcall(vim.api.nvim_get_autocmds, { group = group })
    check(not ok, "augroup should be deleted after finish")
end

-- 6. abort_all：所有在飞 session 走 aborted 路径（含 finalize），可重复调用
do
    local sid1, log1 = new_session(parsers.lines())
    local sid2, log2 = new_session(nil)
    exec._dispatch(sid1, "stdout", "pending-no-newline")
    exec.abort_all("aborted: daemon exited")
    check(#log1.exits == 1 and log1.exits[1].reason == "aborted: daemon exited" and log1.exits[1].code == -1,
        "abort_all on_exit shape (1)")
    check(#log2.exits == 1 and log2.exits[1].reason == "aborted: daemon exited", "abort_all on_exit shape (2)")
    check(#log1.events == 1 and log1.events[1].text == "pending-no-newline", "abort_all should run parser finalize")
    check(exec.active_count() == 0, "abort_all clears sessions")
    exec.abort_all()
    check(#log1.exits == 1 and #log2.exits == 1, "abort_all twice must not re-deliver")
    exec._dispatch(sid1, "exit", { 0 })
    check(#log1.exits == 1, "events after abort_all ignored")
    -- 默认 reason
    local _, log3 = new_session(nil)
    exec.abort_all()
    check(type(log3.exits[1].reason) == "string" and log3.exits[1].reason:match("^aborted"), "default reason")
end

print("test_exec_dispatch: ok")
