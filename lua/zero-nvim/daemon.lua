--- Daemon 进程生命周期：二进制查找、jobstart、退出/stderr 处理。
--- 其他模块只通过 channel() / ensure() 拿 RPC channel。
local config = require("zero-nvim.config")
local log = require("zero-nvim.log")

local M = {}

local state = {
    channel_id = nil,
    leaving = false, -- VimLeavePre 之后 daemon 退出属于正常流程，不再报错
    exit_listeners = {},
}

--- Plugin install root, derived from this file's own path. The daemon binary
--- is only ever resolved relative to it (never relative to cwd: running a
--- binary from whatever project the user happens to be in is unsafe).
local function plugin_root()
    local src = debug.getinfo(1, "S").source
    if type(src) ~= "string" or src:sub(1, 1) ~= "@" then return nil end
    local script_path = vim.fn.fnamemodify(src:sub(2), ":p")
    -- <root>/lua/zero-nvim/daemon.lua
    return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script_path)))
end

local function find_bin()
    local opts = config.get().daemon
    if opts.path and vim.fn.executable(opts.path) == 1 then
        return opts.path
    end
    local root = plugin_root()
    if not root then return nil end
    local detected_path = string.format("%s/daemon/target/%s/zero-nvim-daemon", root, opts.build_type)
    if vim.fn.executable(detected_path) == 1 then return detected_path end
    return nil
end

local function handle_exit(code)
    state.channel_id = nil
    local reason = string.format("daemon exited (code=%s)", tostring(code))
    for _, fn in ipairs(state.exit_listeners) do
        local ok, err = pcall(fn, code)
        if not ok then log.debug("daemon on_exit listener failed: " .. tostring(err)) end
    end
    -- 通知所有进行中的 stream session：daemon 没了，不会再有 exit 事件回来。
    require("zero-nvim.cmd.exec").abort_all(reason)
    local exiting = vim.v.exiting ~= nil and vim.v.exiting ~= vim.NIL
    if not state.leaving and not exiting then
        vim.schedule(function()
            log.error(string.format(
                "Daemon exited unexpectedly (code=%s); it will be restarted on next use.",
                tostring(code)))
        end)
    end
end

local function on_stderr(_, data)
    -- 调试模式：daemon stderr 同时 tee 到文件，方便 panic / SIGPIPE 死亡时
    -- 事后回看（vim.notify 历史可能被 :messages 截掉）。开关通过环境变量。
    local debug_log = os.getenv("ZERO_NVIM_DEBUG") and "/tmp/zero-daemon.log" or nil
    local f = debug_log and io.open(debug_log, "a") or nil
    for _, line in ipairs(data) do
        if line ~= "" then
            log.warn("Daemon: " .. line)
            if f then f:write(os.date("%H:%M:%S ") .. line .. "\n") end
        end
    end
    if f then f:close() end
end

--- 已启动 daemon 的 channel；不会自动启动。
---@return integer?
function M.channel()
    return state.channel_id
end

--- Daemon channel, starting the daemon on demand. Returns nil when the
--- binary cannot be found / started (an error has been logged).
---@return integer?
function M.ensure()
    if state.channel_id then return state.channel_id end
    local bin_path = find_bin()
    if not bin_path then
        log.error("Daemon binary not found. Build it with `make build` (or set daemon.path).")
        return nil
    end
    local job
    job = vim.fn.jobstart({ bin_path }, {
        rpc = true,
        on_exit = function(_, code)
            -- 旧 daemon 的迟到 on_exit 不能清掉新 daemon 的状态
            if state.channel_id ~= job then return end
            handle_exit(code)
        end,
        on_stderr = on_stderr,
    })
    -- jobstart: 0 = 参数非法，-1 = 不可执行；都不能当作有效 channel 缓存
    if type(job) ~= "number" or job <= 0 then
        log.error(string.format("Failed to start daemon %s (jobstart returned %s)", bin_path, tostring(job)))
        return nil
    end
    state.channel_id = job
    return job
end

--- 注册 daemon 退出回调（channel 已清空之后调用，参数为 exit code）。
--- 用于清理按连接缓存的状态。
---@param fn fun(code: integer)
function M.on_exit(fn)
    table.insert(state.exit_listeners, fn)
end

--- VimLeavePre 之后调用：此后的 daemon 退出不再报错。
function M.set_leaving()
    state.leaving = true
end

return M
