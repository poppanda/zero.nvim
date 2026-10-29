--- LSP 自动重启 / 退避重连：client 退出 / 传输层出错后的状态簿记与恢复调度。
--- 真正的启动由 lsp/init.lua 经 set_starter 注入（避免循环 require）。
---
--- on_exit / on_error → restart_from_entry（最多 MAX_RESTART_ATTEMPTS 次快速
--- 重启，间隔递增）→ 仍失败转入 schedule_revive（BACKOFF_SECS 慢速退避，累计
--- MAX_DORMANT_SECS 后彻底休眠；:ZeroLspRestart / VimResume 可唤起）。
local client_select = require("zero-nvim.lsp.client_select")
local uri = require("zero-nvim.uri")
local util = require("zero-nvim.util")
local log = require("zero-nvim.log")

local M = {}

local MAX_RESTART_ATTEMPTS = 3
local BACKOFF_SECS = { 1, 2, 4, 8, 16, 30, 60 }
local MAX_DORMANT_SECS = 30 * 60

local state = {
    active_lsps = {},
    intentional_stops = {},
    pending_transport_restarts = {},
    stale_restart_exits = {},
    dormant_lsps = {},
}

---@type fun(entry: table): integer?, string?
local start_client

--- 注入启动函数：fn(entry) 以 force_new 启动新 client，返回 client_id, err。
function M.set_starter(fn)
    start_client = fn
end

-- ───── 状态簿记 ─────────────────────────────────────────────────────────────

function M.track(client_id, entry)
    state.active_lsps[client_id] = entry
end

function M.entry(client_id)
    return state.active_lsps[client_id]
end

function M.reset_attempts(client_id)
    local entry = state.active_lsps[client_id]
    if entry then entry.attempts = 0 end
end

function M.mark_intentional_stop(client_id)
    state.intentional_stops[client_id] = true
end

function M.consume_intentional_stop(client_id)
    local marked = state.intentional_stops[client_id] ~= nil
    state.intentional_stops[client_id] = nil
    return marked
end

function M.mark_stale_exit(client_id)
    state.stale_restart_exits[client_id] = true
end

function M.consume_stale_exit(client_id)
    local marked = state.stale_restart_exits[client_id] ~= nil
    state.stale_restart_exits[client_id] = nil
    return marked
end

function M.set_pending_transport_restart(client_id, pending)
    state.pending_transport_restarts[client_id] = pending
end

function M.consume_pending_transport_restart(client_id)
    local pending = state.pending_transport_restarts[client_id]
    state.pending_transport_restarts[client_id] = nil
    return pending
end

--- client 退出后该做什么：{ kind = "ignore" | "notify_exit" | "restart", ... }。
function M.resolve_exit(client_id, entry, attached, code)
    state.active_lsps[client_id] = nil

    if M.consume_stale_exit(client_id) then
        M.consume_pending_transport_restart(client_id)
        M.consume_intentional_stop(client_id)
        return { kind = "ignore" }
    end

    local pending = M.consume_pending_transport_restart(client_id)
    if pending then
        return {
            kind = "restart",
            entry = pending.entry or entry,
            attached = pending.attached or attached,
            reason = pending.reason,
        }
    end

    if M.consume_intentional_stop(client_id) then
        return { kind = "notify_exit", intentional = true, level = "info" }
    end

    if not entry then
        return { kind = "notify_exit", level = (code == 0 or code == nil) and "info" or "warn" }
    end

    -- 注册过的 client 即使 code=0 也重启：SSH 空闲断开在本地看起来就是干净的 EOF。
    return {
        kind = "restart",
        entry = entry,
        attached = attached,
        reason = code == 0 and "连接断开 (EOF)" or "异常退出",
    }
end

function M.queue_transport_restart(client_id, entry, attached, reason)
    if not entry or state.intentional_stops[client_id] then return false end
    M.set_pending_transport_restart(client_id, { entry = entry, attached = attached, reason = reason })
    return true
end

function M.resolve_transport_fallback(client_id)
    if not M.entry(client_id) or not state.pending_transport_restarts[client_id] then
        return { kind = "ignore" }
    end
    local pending = M.consume_pending_transport_restart(client_id)
    return { kind = "restart", entry = pending.entry, attached = pending.attached, reason = pending.reason }
end

function M.dormant_key_for(entry)
    return client_select.client_key(entry.server_name, entry.user, entry.host, entry.port, entry.root_dir)
end

function M.get_dormant(key)
    return state.dormant_lsps[key]
end

function M.set_dormant(key, dormant)
    state.dormant_lsps[key] = dormant
end

function M.clear_dormant(key)
    local dormant = state.dormant_lsps[key]
    if dormant then util.close_timer(dormant.timer) end
    state.dormant_lsps[key] = nil
end

---@return integer
function M.dormant_count()
    return vim.tbl_count(state.dormant_lsps)
end

function M._reset_for_tests()
    for _, dormant in pairs(state.dormant_lsps) do
        util.close_timer(dormant.timer)
    end
    for k in pairs(state) do state[k] = {} end
end

-- ───── 恢复调度 ─────────────────────────────────────────────────────────────

local TRANSPORT_ERROR_PATTERNS = { "read_error", "write_error", "econnreset", "epipe", "connection reset", "closed", "eof" }

local function is_transport_error(code, err)
    -- 优先看符号名：err 文本随传输层（TCP socket / ssh 子进程 / LSP proxy）差异
    -- 很大，单靠字符串匹配不可靠；Neovim 经 vim.lsp.client_errors 归一化了 rpc 层原因。
    if type(code) == "number" and vim.lsp.client_errors then
        local name = vim.lsp.client_errors[code]
        if name == "READ_ERROR" or name == "WRITE_ERROR"
            or name == "SERVER_REQUEST_HANDLER_ERROR"
            or name == "NOTIFICATION_HANDLER_ERROR" then
            return true
        end
    end
    local msg = (tostring(code or "") .. " " .. tostring(err or "")):lower()
    for _, pat in ipairs(TRANSPORT_ERROR_PATTERNS) do
        if msg:find(pat, 1, true) then return true end
    end
    return false
end

local function attached_buffers(client_id)
    local attached = {}
    local client = vim.lsp.get_client_by_id(client_id)
    for b in pairs(client and client.attached_buffers or {}) do
        if vim.api.nvim_buf_is_valid(b) then table.insert(attached, b) end
    end
    return attached
end

--- 恢复成功后：停掉同 (server, remote, root) 的旧 client，把原来附着的
--- buffer 挂到新 client 上。
---@return integer count reattached buffers
local function adopt_replacement(entry, new_id, attached)
    local tkey = uri.target_key(entry.user, entry.host, entry.port)
    for _, client in ipairs(vim.lsp.get_clients({ name = client_select.client_name(entry.server_name) })) do
        if client.id ~= new_id and client.config
            and client.config._zero_target == tkey
            and client.config.root_dir == entry.root_dir then
            M.mark_stale_exit(client.id)
            pcall(client.stop, true)
        end
    end
    local count = 0
    for _, b in ipairs(attached or {}) do
        if vim.api.nvim_buf_is_valid(b) then
            pcall(vim.lsp.buf_attach_client, b, new_id)
            count = count + 1
        end
    end
    return count
end

local schedule_revive

local function do_revive_attempt(entry, attached, prior_attempts)
    local new_id = start_client(entry)
    if not new_id then
        schedule_revive(entry, attached, prior_attempts)
        return
    end
    M.clear_dormant(M.dormant_key_for(entry))
    adopt_replacement(entry, new_id, attached)
    vim.schedule(function()
        log.info(string.format("LSP '%s' 已恢复 (退避第 %d 次)",
            client_select.client_name(entry.server_name), prior_attempts + 1))
    end)
end

--- 慢速退避。取消语义：revive_dormant_now 先清 dormant entry 再重排，旧 timer
--- 即便已进入回调也会在头部检查时早返回。
schedule_revive = function(entry, attached, prior_attempts)
    local key = M.dormant_key_for(entry)
    local existing = state.dormant_lsps[key]
    if existing then util.close_timer(existing.timer) end

    -- started_at 起累计 MAX_DORMANT_SECS 后彻底休眠，防止长期挂着空发 RPC
    local started_at = (existing and existing.started_at) or os.time()
    local elapsed = os.time() - started_at
    if elapsed >= MAX_DORMANT_SECS then
        M.clear_dormant(key)
        vim.schedule(function()
            log.error(string.format(
                "LSP 'zero-%s' 已重试 %d 分钟仍未恢复，进入休眠。`:ZeroLspRestart` 可手动唤起。",
                entry.server_name, math.floor(elapsed / 60)))
        end)
        return
    end

    local attempts = prior_attempts + 1
    local timer = vim.defer_fn(function()
        local d = state.dormant_lsps[key]
        if not d then return end -- 已被 revive_dormant_now 取消或别处恢复
        d.timer = nil
        do_revive_attempt(entry, d.attached, attempts)
    end, BACKOFF_SECS[math.min(attempts, #BACKOFF_SECS)] * 1000)

    M.set_dormant(key, { entry = entry, attached = attached, attempts = attempts, started_at = started_at, timer = timer })

    if prior_attempts == 0 then
        vim.schedule(function()
            log.info(string.format("LSP 'zero-%s' 进入退避重连 (%d-60s 间隔，最多 %d 分钟)",
                entry.server_name, BACKOFF_SECS[1], math.floor(MAX_DORMANT_SECS / 60)))
        end)
    end
end

--- 快速重启：最多 MAX_RESTART_ATTEMPTS 次（间隔递增），之后转入慢速退避。
local function restart_from_entry(client_id, entry, attached, reason)
    state.active_lsps[client_id] = nil
    -- 用户主动停的 / 无 entry：只消费标记，不重启
    if M.consume_intentional_stop(client_id) or not entry then return end

    local lsp_name = client_select.client_name(entry.server_name)
    if entry.attempts >= MAX_RESTART_ATTEMPTS then
        -- 覆盖长期断网 / 笔记本休眠：用户 ~30min 内回来都能自愈，不用手动救。
        vim.schedule(function()
            log.warn(string.format("LSP '%s' 已快速重启 %d 次仍失败，转入退避重试", lsp_name, entry.attempts))
        end)
        entry.attempts = 0 -- 退避循环用自己的尝试计数
        schedule_revive(entry, attached, 0)
        return
    end

    entry.attempts = entry.attempts + 1
    vim.defer_fn(function()
        log.info(string.format("LSP '%s' %s，自动重启 (第 %d 次)...", lsp_name, reason, entry.attempts))
        local new_id, err = start_client(entry)
        if not new_id then
            -- 多半是 daemon RPC 失败（网络断了 / ssh 连不上），继续快速循环也是徒劳
            log.warn(string.format("LSP '%s' 重启失败 (%s)，转入退避重试", lsp_name, tostring(err)))
            schedule_revive(entry, attached, 0)
            return
        end
        local new_entry = M.entry(new_id)
        if new_entry then new_entry.attempts = entry.attempts end
        local n = adopt_replacement(entry, new_id, attached)
        if n > 0 then
            log.info(string.format("LSP '%s' 已恢复，重新附着 %d 个 buffer", lsp_name, n))
        end
    end, 500 * entry.attempts)
end

--- vim.lsp client 的 on_exit。
function M.on_exit(client_id, lsp_name, code, signal)
    local action = M.resolve_exit(client_id, M.entry(client_id), attached_buffers(client_id), code)
    if action.kind == "notify_exit" then
        vim.schedule(function()
            log.notify(string.format("LSP '%s' exited (code=%s, signal=%s)", lsp_name, tostring(code), tostring(signal)),
                action.level == "warn" and vim.log.levels.WARN or vim.log.levels.INFO)
        end)
    elseif action.kind == "restart" then
        restart_from_entry(client_id, action.entry, action.attached, action.reason)
    end
end

--- vim.lsp client 的 on_error：传输层错误 → 停掉 client 并排队重启（on_exit
--- 正常会消费；3s 内没等到 exit 就自己重启），其他错误只报告。
function M.on_error(client_id, lsp_name, code, err)
    if client_id and is_transport_error(code, err)
        and M.queue_transport_restart(client_id, M.entry(client_id), attached_buffers(client_id), "连接断开") then
        local client = vim.lsp.get_client_by_id(client_id)
        if client then pcall(client.stop, true) end
        vim.defer_fn(function()
            local action = M.resolve_transport_fallback(client_id)
            if action.kind == "restart" then
                restart_from_entry(client_id, action.entry, action.attached, action.reason)
            end
        end, 3000)
        return
    end
    vim.schedule(function()
        log.error(string.format("LSP '%s' error (code=%s): %s", lsp_name, tostring(code), tostring(err)))
    end)
end

--- 取消所有退避 timer 并立刻重试一次（:ZeroLspRestart / VimResume / FocusGained：
--- 用户回来时网络多半已恢复）。先清 dormant entry，schedule_revive 会把
--- started_at 重新计时（30min 时窗刷新）。
---@return integer count number of dormant entries revived
function M.revive_dormant_now()
    local count = 0
    for _, key in ipairs(vim.tbl_keys(state.dormant_lsps)) do
        local d = state.dormant_lsps[key]
        M.clear_dormant(key)
        vim.defer_fn(function() do_revive_attempt(d.entry, d.attached, 0) end, 50)
        count = count + 1
    end
    return count
end

return M
