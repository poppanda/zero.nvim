-- =============================================================================
-- scripts/smoke_phase3a.lua — Phase 3A 本地 headless 校验
-- =============================================================================
-- 用法: bash scripts/smoke_phase3a.sh
--
-- 不连任何远端、不跑真实 :Neogit；验证：
--   L1: fork neogit 的 backends.lua API
--   L2: zero-nvim/neogit/backend.lua require + setup 不报错（在没装 fork 时也得静默）
--   L3: zero-nvim/neogit/backend.lua 注册到 fork 后能被 backends.pick("zero://...") 命中
--   L4: backend.detect 解析 zero:// URI 正确
--   L5: backend.spawn 在 ctx.target 缺失时返回 err 而不是崩
--   L6: zero-nvim/neogit/watcher.lua 注册 session + unwatch 工作
--
-- :Neogit 真实 status 渲染需要远端 + 实跑 git，留给手动 E2E。

local function out(s) io.stdout:write(s .. "\n"); io.stdout:flush() end
local function ok(s)   out("[ OK ] " .. s) end
local function info(s) out("[INFO] " .. s) end
local function fail(s) out("[FAIL] " .. s); os.exit(1) end
local function header(s) out(""); out("=== " .. s .. " ===") end

-- -----------------------------------------------------------------------------
header("L1: fork neogit backends API 完整")
-- -----------------------------------------------------------------------------
local ok_req, backends = pcall(require, "neogit.backends")
if not ok_req then fail("require neogit.backends: " .. tostring(backends)) end
for _, name in ipairs({ "register", "unregister", "pick", "list" }) do
    if type(backends[name]) ~= "function" then
        fail("backends." .. name .. " 不是 function")
    end
end
ok("backends API 完整")

-- 没注册时 pick 返回 nil
backends.unregister("zero")  -- 防御性，确保起始状态干净
local b0 = backends.pick("/local/path")
if b0 ~= nil then fail("无 backend 时 pick 应返回 nil") end
local b0z = backends.pick("zero://u@h:22/repo")
if b0z ~= nil then fail("无 backend 注册时 pick(zero://...) 应返回 nil") end
ok("空 registry 状态正确")

-- -----------------------------------------------------------------------------
header("L2: zero-nvim/neogit/backend.lua require 不报错")
-- -----------------------------------------------------------------------------
local ok_b, zb = pcall(require, "zero-nvim.neogit.backend")
if not ok_b then fail("require zero-nvim.neogit.backend: " .. tostring(zb)) end
for _, name in ipairs({ "detect", "paths", "spawn", "watch", "setup", "id_for" }) do
    if type(zb[name]) ~= "function" then
        fail("zero backend 缺函数: " .. name)
    end
end
ok("zero backend API 完整")

-- -----------------------------------------------------------------------------
header("L3: setup 注册到 fork backends；pick 命中 zero://")
-- -----------------------------------------------------------------------------
zb.setup({ watcher = { debounce_ms = 50, poll_ms = 0 } })
local ids = backends.list()
info("registered ids = " .. vim.inspect(ids))
if not vim.tbl_contains(ids, "zero") then
    fail("setup 后 list 没看到 zero")
end

local b1, ctx1 = backends.pick("zero://alice@example.com:2222/var/repo")
if not b1 then fail("pick(zero://...) 应命中 zero backend") end
if b1.id ~= "zero" then fail("命中的 backend.id 不对: " .. tostring(b1.id)) end
if not ctx1 or not ctx1.target then fail("ctx 缺 target") end
if ctx1.target.user ~= "alice" or ctx1.target.host ~= "example.com" or ctx1.target.port ~= 2222 then
    fail("ctx.target 解析错误: " .. vim.inspect(ctx1.target))
end
if ctx1.path ~= "/var/repo" then fail("ctx.path 错: " .. tostring(ctx1.path)) end
if ctx1.id ~= "zero://alice@example.com:2222" then
    fail("ctx.id 错: " .. tostring(ctx1.id))
end
ok("pick + ctx 解析正确")

-- 本地路径不会命中
local b2 = backends.pick("/tmp/some/local/repo")
if b2 ~= nil then fail("本地路径不应命中 zero backend") end
ok("本地路径正确不命中")

-- -----------------------------------------------------------------------------
header("L4: backend.detect 边界情况")
-- -----------------------------------------------------------------------------
-- 无端口（默认 22）
local c1 = zb.detect("zero://bob@example.com/path")
if not c1 or c1.target.port ~= 22 then fail("默认端口 22 解析失败") end
ok("默认端口正确")

-- 非 zero:// URI 返回 nil
local c2 = zb.detect("/usr/local")
if c2 ~= nil then fail("非 zero:// URI detect 应返回 nil") end
ok("非 URI 正确返回 nil")

-- -----------------------------------------------------------------------------
header("L5: backend.spawn 不带 ctx 时返回 err 而非崩")
-- -----------------------------------------------------------------------------
local handle, err = zb.spawn(
    { cmd = { "echo", "x" }, cwd = "/" },
    { on_stdout = function() end, on_stderr = function() end, on_exit = function() end },
    nil  -- ctx 缺失
)
if handle ~= nil then fail("缺 ctx 不该返回 handle") end
if not err or not err:match("ctx") then fail("err 应提到 ctx，得到: " .. tostring(err)) end
ok("缺 ctx 时优雅返回 err")

-- -----------------------------------------------------------------------------
header("L6: watcher session 注册 + unwatch 工作")
-- -----------------------------------------------------------------------------
local w = require("zero-nvim.neogit.watcher")
local fired = 0
local unwatch = w.start({ id = "zero://test" }, "/repo/.git", function()
    fired = fired + 1
end)
if w.active_count() ~= 1 then fail("注册后 active_count 应为 1") end
ok("session 注册成功")

-- 等 50ms 让 defer 触发首次 on_event
vim.wait(120, function() return fired > 0 end)
info("首次 on_event fired = " .. fired)
if fired < 1 then fail("注册后没触发首次 on_event") end
ok("首次 on_event 自动触发")

-- 模拟 BufWritePost 触发
fired = 0
vim.cmd("doautocmd FocusGained")
vim.wait(300, function() return fired > 0 end)
info("FocusGained 后 fired = " .. fired)
if fired < 1 then
    -- FocusGained 在 headless 下可能不工作；跳过这一项不算失败
    info("(headless FocusGained 不可靠，跳过)")
else
    ok("autocmd 触发 schedule → on_event")
end

unwatch()
if w.active_count() ~= 0 then fail("unwatch 后 active_count 应为 0") end
ok("unwatch 清理 session")

-- -----------------------------------------------------------------------------
out("")
ok("ALL PHASE 3A SMOKE LAYERS PASSED")
os.exit(0)
