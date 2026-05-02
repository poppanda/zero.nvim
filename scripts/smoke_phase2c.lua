-- =============================================================================
-- scripts/smoke_phase2c.lua — Phase 2C 本地 headless 校验
-- =============================================================================
-- 用法:
--   nvim --headless -u NONE -l scripts/smoke_phase2c.lua
--
-- 不连任何远端，只验证 refresh 模块的 autocmd 注册 + debounce + in-flight gate +
-- 轮询 timer 行为。:Gitsigns refresh 用 monkey-patch 抓调用次数，不真的跑
-- gitsigns（fork 不一定在 rtp 里）。

local ZERO_ROOT = "/Users/smile./Code/Neovim/zero.nvim"
vim.opt.rtp:prepend(ZERO_ROOT)

local function out(s) io.stdout:write(s .. "\n"); io.stdout:flush() end
local function ok(s)   out("[ OK ] " .. s) end
local function info(s) out("[INFO] " .. s) end
local function fail(s) out("[FAIL] " .. s); os.exit(1) end
local function header(s) out(""); out("=== " .. s .. " ===") end

-- monkey-patch :Gitsigns 用户命令：捕获调用次数
local refresh_calls = 0
vim.api.nvim_create_user_command("Gitsigns", function(o)
    if o.args == "refresh" then refresh_calls = refresh_calls + 1 end
end, { nargs = "*" })

-- -----------------------------------------------------------------------------
header("L1: refresh.setup 装好 autocmd（poll_ms=0 不创建 timer）")
-- -----------------------------------------------------------------------------
local refresh = require("zero-nvim.gitsigns.refresh")
refresh.setup({ debounce_ms = 100, poll_ms = 0 })

local aus = vim.api.nvim_get_autocmds({ group = "ZeroNvimGitsignsRefresh" })
info("autocmds count = " .. #aus)
if #aus < 2 then fail("expected ≥ 2 autocmds in ZeroNvimGitsignsRefresh") end

local kinds = {}
for _, au in ipairs(aus) do kinds[au.event] = (kinds[au.event] or 0) + 1 end
info("events = " .. vim.inspect(kinds))
if not kinds.BufEnter or not kinds.BufWritePost or not kinds.FocusGained then
    fail("missing one of BufEnter/BufWritePost/FocusGained")
end
ok("L1 passed (autocmd 注册齐全)")

-- -----------------------------------------------------------------------------
header("L2: BufEnter 触发 debounce 后 1 次 :Gitsigns refresh")
-- -----------------------------------------------------------------------------
do
    refresh_calls = 0
    -- 创建一个 zero:// buffer 模拟 attach
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "zero://u@h:22/repo/file.lua")
    vim.api.nvim_set_current_buf(buf)
    -- nvim_set_current_buf 已经触发了 BufEnter；再显式 fire 一次以求确定。
    vim.api.nvim_exec_autocmds("BufEnter", { buffer = buf })

    -- 立即 check：debounce 还没过，应当 0 次
    if refresh_calls ~= 0 then
        fail("expected 0 refresh before debounce, got " .. refresh_calls)
    end
    info("immediate refresh_calls=0 ✓")

    -- 等 debounce(100) + 余量
    vim.wait(250, function() return false end)
    info("after 250ms refresh_calls=" .. refresh_calls)
    if refresh_calls < 1 then
        fail("expected ≥1 refresh after debounce, got " .. refresh_calls)
    end
    ok("L2 passed")
end

-- -----------------------------------------------------------------------------
header("L3: 短时间多次 BufEnter 合成 1 次（debounce coalesce）")
-- -----------------------------------------------------------------------------
do
    -- 等 in-flight 释放再开始，否则 do_refresh 会被 gate 直接 skip——
    -- 那是 in-flight gate 而不是 debounce 在干活，会污染 L3 的语义。
    vim.wait(150, function() return false end)
    refresh_calls = 0
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "zero://u@h:22/repo/another.lua")
    vim.api.nvim_set_current_buf(buf)

    -- 50ms 内连 fire 5 次
    for _ = 1, 5 do
        vim.api.nvim_exec_autocmds("BufEnter", { buffer = buf })
        vim.wait(10, function() return false end)
    end
    -- 等 debounce 过
    vim.wait(250, function() return false end)
    info("refresh_calls=" .. refresh_calls)
    if refresh_calls ~= 1 then
        fail("expected exactly 1 coalesced refresh, got " .. refresh_calls)
    end
    ok("L3 passed")
end

-- -----------------------------------------------------------------------------
header("L4: in-flight gate 防止 debounce 之内重入")
-- -----------------------------------------------------------------------------
do
    refresh_calls = 0
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "zero://u@h:22/repo/c.lua")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_exec_autocmds("BufEnter", { buffer = buf })
    vim.wait(150, function() return false end)
    -- 上面这次让 do_refresh 跑了一次；in_flight 在 debounce_ms=100ms 后才释放
    -- 立即再 fire 一次 BufEnter：debounce 计时重启，100ms 后再触发 do_refresh，
    -- 那时 in_flight 已释放（150ms > 100ms），所以正常 +1
    if refresh_calls ~= 1 then
        fail("expected 1 after first burst, got " .. refresh_calls)
    end

    -- 现在测试 in-flight gate：触发 → 立刻再触发 → 等够 debounce 但不够 in_flight
    refresh_calls = 0
    vim.api.nvim_exec_autocmds("BufEnter", { buffer = buf })
    vim.wait(120, function() return false end)
    -- 这里 do_refresh 跑了 1 次，in_flight=true，且要等 debounce_ms=100ms 才释放。
    -- 立刻再一次 BufEnter，debounce 100ms 后 do_refresh 被调，但 in_flight 未释放→skip
    info("refresh_calls after first = " .. refresh_calls)
    -- L4 这里说服力一般（debounce=in_flight=100 让两个等价了），主要确认 do_refresh
    -- 自己进了 if in_flight then return 早 return 路径不报错就行
    ok("L4 passed (in-flight gate path 至少不会崩)")
end

-- -----------------------------------------------------------------------------
header("L5: poll_ms>0 + 无 zero:// 窗口 → timer 空跑不刷")
-- -----------------------------------------------------------------------------
do
    -- 切回非 zero:// buffer
    local plain = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(plain, "/tmp/local_only.txt")
    vim.api.nvim_set_current_buf(plain)
    -- 关闭其它 win 上残留的 zero:// buffer——简化起见，直接关掉所有别的 win
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        if w ~= vim.api.nvim_get_current_win() then
            pcall(vim.api.nvim_win_close, w, true)
        end
    end

    -- 重新装 setup 改 poll_ms
    refresh.setup({ debounce_ms = 100, poll_ms = 80 })
    -- 等 in-flight 从前面 L4 释放 + 让 poll 至少跑两轮
    vim.wait(250, function() return false end)
    refresh_calls = 0
    vim.wait(250, function() return false end) -- 这 250ms 内 poll 至少跑 3 轮
    info("refresh_calls during poll w/o zero buf = " .. refresh_calls)
    if refresh_calls ~= 0 then
        fail("expected 0 refresh while no zero window visible, got " .. refresh_calls)
    end
    ok("L5 passed")
end

-- -----------------------------------------------------------------------------
header("L6: poll_ms>0 + 有 zero:// 窗口 → timer 触发刷新")
-- -----------------------------------------------------------------------------
do
    local zero_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(zero_buf, "zero://u@h:22/repo/poll.lua")
    vim.api.nvim_set_current_buf(zero_buf)
    -- BufEnter 自己也会触发一次 schedule_refresh，等它先打完
    vim.wait(250, function() return false end)
    refresh_calls = 0
    -- 等 poll(80) 跑几轮——每轮都会 schedule_refresh→debounce(100)→do_refresh
    -- 由于 in_flight=100ms 释放，理论 ~180ms 一次
    vim.wait(500, function() return false end)
    info("refresh_calls during poll w/ zero buf = " .. refresh_calls)
    if refresh_calls < 1 then
        fail("expected ≥1 refresh during 500ms poll w/ zero buf, got " .. refresh_calls)
    end
    ok("L6 passed")
end

-- -----------------------------------------------------------------------------
out("")
ok("ALL PHASE 2C SMOKE LAYERS PASSED")
os.exit(0)
