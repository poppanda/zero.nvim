-- neogit backend 主机 gate：on_exit 回调抛错 / 看门狗超时都必须放行队列
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local function check(cond, msg)
    if not cond then error(msg, 2) end
end

local streams = {}
package.loaded["zero-nvim.cmd"] = {
    stream = function(target, spec, handlers)
        table.insert(streams, { target = target, spec = spec, handlers = handlers })
        return "sid-" .. #streams
    end,
    cancel = function() end,
    write_stdin = function() end,
    close_stdin = function() end,
    with_remote_path = function(argv) return argv end,
    env_pairs = function() return nil end,
}
local notes = {}
vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end

local backend = require("zero-nvim.neogit.backend")
local ctx = { target = { user = "u", host = "gate-host", port = 22 }, path = "/repo" }
local function cb(on_exit)
    return { on_stdout = function() end, on_stderr = function() end, on_exit = on_exit or function() end }
end
local function flush() vim.wait(30, function() return false end) end

-- 1. 第一条命令的 on_exit 抛错，第二条仍然能跑
backend.spawn({ cmd = { "git", "status" } }, cb(function() error("callback boom") end), ctx)
backend.spawn({ cmd = { "git", "log" } }, cb(), ctx)
check(#streams == 1, "second command should be queued behind the gate")
local ok = pcall(streams[1].handlers.on_exit, 0, nil, nil, 5)
check(not ok, "on_exit error should still propagate to exec (for reporting)")
flush()
check(#streams == 2, "gate must be released even if cb.on_exit throws")

-- 2. aborted（daemon 死亡 / abort_all）同样释放
streams[2].handlers.on_exit(-1, nil, "aborted: daemon exited", 0)
backend.spawn({ cmd = { "git", "branch" } }, cb(), ctx)
check(#streams == 3, "gate free after aborted exit")

-- 3. 看门狗：挂死的命令超时后放行
backend._gate_timeout_ms = 30
backend.spawn({ cmd = { "git", "diff" } }, cb(), ctx) -- 排在 #3 后面
streams[3].handlers.on_exit(0, nil, nil, 1)
flush()
check(#streams == 4, "4th should start after 3rd exits")
backend.spawn({ cmd = { "git", "show" } }, cb(), ctx)
check(#streams == 4, "5th queued behind hung 4th")
vim.wait(500, function() return #streams == 5 end)
check(#streams == 5, "watchdog should release a hung command")
local warned = false
for _, n in ipairs(notes) do
    if n.msg:match("still running") then warned = true end
end
check(warned, "watchdog should warn")
-- 4 迟到的 exit 不会重复释放（不会让 gate 出现两条并发）
backend.spawn({ cmd = { "git", "tag" } }, cb(), ctx)
streams[4].handlers.on_exit(0, nil, nil, 1)
flush()
check(#streams == 5, "late exit of timed-out command must not release gate again")
streams[5].handlers.on_exit(0, nil, nil, 1)
flush()
check(#streams == 6, "queue continues after 5th exits")
streams[6].handlers.on_exit(0, nil, nil, 1)

print("test_neogit_gate: ok")
