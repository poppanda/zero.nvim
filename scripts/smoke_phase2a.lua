-- =============================================================================
-- scripts/smoke_phase2a.lua — Phase 2A 端到端烟雾测试
-- =============================================================================
-- 用法:
--   nvim --headless -u NONE -l scripts/smoke_phase2a.lua \
--     <user> <host> <port> <remote_path>
--
-- 例:
--   nvim --headless -u NONE -l scripts/smoke_phase2a.lua \
--     home 47.117.104.181 22022 /home/home/Code/2025-code-craft-preliminary/code/disk.cpp
--
-- 测试链路（自下而上 6 层）:
--   L1: cmd.stream 直连 + echo  —— 验证 daemon notification 通路
--   L2: cmd.stream 直连 + git   —— 验证远端 PATH + git
--   L3: backend.system          —— 验证 gitsigns→daemon 适配
--   L4: gitsigns.attach          —— 验证完整 attach 流程
--   L5: backend.system + stdin  —— Phase 2B：写命令链路（cat - 回显校验）
--   L6: backend.system + 流式回调 —— Phase 2B：blame --incremental 回调契约
--
-- 每层只在前一层通过后才跑。任何一层卡住 / 报错都会立刻打 FAIL 并退出。

local args = _G.arg or {}
if #args < 4 then
    io.stderr:write("usage: nvim --headless -u NONE -l smoke_phase2a.lua <user> <host> <port> <remote_path>\n")
    os.exit(2)
end

local USER       = args[1]
local HOST       = args[2]
local PORT       = tonumber(args[3])
local REMOTE_PATH = args[4]
local TARGET     = { user = USER, host = HOST, port = PORT }

local ZERO_ROOT     = "/Users/smile./Code/Neovim/zero.nvim"
local GITSIGNS_ROOT = "/Users/smile./Code/Neovim/gitsigns.nvim"

-- -----------------------------------------------------------------------------
-- 输出工具：直写 stdout 不被 :messages 吞
-- -----------------------------------------------------------------------------
local function out(s)
    io.stdout:write(s .. "\n"); io.stdout:flush()
end
local function ok(s)   out("[ OK ] " .. s) end
local function info(s) out("[INFO] " .. s) end
local function fail(s) out("[FAIL] " .. s); os.exit(1) end
local function header(s)
    out("")
    out("=== " .. s .. " ===")
end

-- -----------------------------------------------------------------------------
-- 等待直到某个条件成立或超时（轮询 1ms）
-- -----------------------------------------------------------------------------
local function wait_until(predicate, timeout_ms, label)
    local start = vim.loop.now()
    while vim.loop.now() - start < timeout_ms do
        if predicate() then return true end
        vim.wait(50, function() return false end)
    end
    fail((label or "wait_until") .. " timed out after " .. timeout_ms .. "ms")
end

-- -----------------------------------------------------------------------------
-- 0. rtp 注入 + 初始化 zero-nvim
-- -----------------------------------------------------------------------------
header("0. bootstrap")
vim.opt.rtp:prepend(ZERO_ROOT)
vim.opt.rtp:prepend(GITSIGNS_ROOT)

-- 屏蔽 vim.notify 的同步 io 干扰（gitsigns / zero-nvim 都会用）
local orig_notify = vim.notify
vim.notify = function(msg, level)
    -- 只把 ERROR 转出来；其他级别静默
    if level == vim.log.levels.ERROR then
        out("[notify-ERR] " .. tostring(msg))
    end
end

require("zero-nvim").setup({})
ok("zero-nvim setup() done")

require("gitsigns").setup({ debug_mode = true })
ok("gitsigns setup() done")

-- backend 应已在 zero-nvim.setup() 末尾注册
local backends = require("gitsigns.backends")
local zb = backends.get("zero")
if not zb then fail("gitsigns.backends.get('zero') returned nil") end
ok("zero backend registered")

-- 触发 daemon 启动
local zero = require("zero-nvim")
local chan = zero.ensure_connection(USER, HOST, PORT)
if not chan then fail("ensure_connection returned nil") end
ok("daemon started, connected " .. USER .. "@" .. HOST .. ":" .. PORT)

-- -----------------------------------------------------------------------------
-- L1: cmd.stream 直连 + echo
-- -----------------------------------------------------------------------------
header("L1: cmd.stream + echo (daemon notification 通路)")

do
    local got_event, got_exit, exit_code, exit_reason = false, false, nil, nil
    local stdout_buf = ""

    local sid, err = require("zero-nvim.cmd").stream(TARGET, {
        argv = { "echo", "hello-from-remote" },
    }, {
        on_event = function(ev)
            got_event = true
            if ev.kind == "stdout" then stdout_buf = stdout_buf .. ev.text end
        end,
        on_exit = function(code, _sig, reason, _dur)
            got_exit  = true
            exit_code = code
            exit_reason = reason
        end,
    })

    if not sid then fail("cmd.stream returned nil err=" .. tostring(err)) end
    info("sid=" .. sid)

    wait_until(function() return got_exit end, 10000, "L1 exit")
    info("got_event=" .. tostring(got_event)
        .. " exit_code=" .. tostring(exit_code)
        .. " reason=" .. tostring(exit_reason)
        .. " stdout=" .. vim.inspect(stdout_buf))

    if exit_reason then fail("L1 aborted: " .. exit_reason) end
    if exit_code ~= 0 then fail("L1 non-zero exit: " .. tostring(exit_code)) end
    if not stdout_buf:find("hello-from-remote", 1, true) then
        fail("L1 stdout missing expected text")
    end
    ok("L1 passed")
end

-- -----------------------------------------------------------------------------
-- L2: cmd.stream + git rev-parse (PATH + git 可用性)
-- -----------------------------------------------------------------------------
header("L2: cmd.stream + git rev-parse")

local REMOTE_DIR = REMOTE_PATH:match("(.*)/[^/]+$") or REMOTE_PATH
local toplevel
do
    local got_exit, exit_code, exit_reason = false, nil, nil
    local stdout_buf, stderr_buf = "", ""

    local PATH_PREFIX = "/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:/home/linuxbrew/.linuxbrew/bin"
    local sid, err = require("zero-nvim.cmd").stream(TARGET, {
        argv = {
            "sh", "-c",
            ('PATH="%s:$PATH" exec "$@"'):format(PATH_PREFIX),
            "--",
            "git", "rev-parse", "--show-toplevel",
        },
        cwd = REMOTE_DIR,
    }, {
        on_event = function(ev)
            if     ev.kind == "stdout" then stdout_buf = stdout_buf .. ev.text
            elseif ev.kind == "stderr" then stderr_buf = stderr_buf .. ev.text end
        end,
        on_exit = function(code, _sig, reason)
            got_exit = true; exit_code = code; exit_reason = reason
        end,
    })
    if not sid then fail("cmd.stream returned nil err=" .. tostring(err)) end

    wait_until(function() return got_exit end, 10000, "L2 exit")
    info("exit_code=" .. tostring(exit_code) .. " reason=" .. tostring(exit_reason))
    info("stdout=" .. vim.inspect(stdout_buf))
    info("stderr=" .. vim.inspect(stderr_buf))

    if exit_reason then fail("L2 aborted: " .. exit_reason) end
    if exit_code ~= 0 then
        fail("L2 git rev-parse failed code=" .. tostring(exit_code) .. " stderr=" .. stderr_buf)
    end
    toplevel = stdout_buf:gsub("[%s\n]+$", "")
    if toplevel == "" then fail("L2 empty toplevel") end
    ok("L2 passed; toplevel=" .. toplevel)
end

-- -----------------------------------------------------------------------------
-- L3: backend.system (gitsigns→daemon 适配)
-- -----------------------------------------------------------------------------
header("L3: backend.system (gitsigns 接口)")

do
    local ctx = zb.detect("zero://" .. USER .. "@" .. HOST .. ":" .. PORT .. REMOTE_PATH)
    if not ctx then fail("backend.detect returned nil") end
    info("ctx=" .. vim.inspect(ctx))

    local got_exit, result = false, nil
    -- gitsigns 风格调用：cmd 是裸 git 命令，opts 含 cwd/env/text/stdin
    zb.system(
        { "git", "rev-parse", "--show-toplevel" },
        { cwd = toplevel, env = { LC_ALL = "C", LANGUAGE = "C" }, text = true },
        ctx,
        function(r)
            got_exit = true; result = r
        end
    )
    wait_until(function() return got_exit end, 10000, "L3 exit")
    info("result=" .. vim.inspect(result))

    if result.code ~= 0 then
        fail("L3 backend.system non-zero code=" .. tostring(result.code) .. " stderr=" .. tostring(result.stderr))
    end
    if not result.stdout or result.stdout == "" then
        fail("L3 empty stdout")
    end
    ok("L3 passed")
end

-- -----------------------------------------------------------------------------
-- L4: gitsigns.attach 完整流程
-- -----------------------------------------------------------------------------
header("L4: gitsigns.attach 完整流程")

do
    -- 走真实 :edit 路径——触发 BufReadCmd → handle_fetch → BufReadPost → gitsigns attach。
    -- 这是用户实际操作的代码路径，比 nvim_buf_set_name 更可信。
    local bufname = "zero://" .. USER .. "@" .. HOST .. ":" .. PORT .. REMOTE_PATH
    vim.cmd("edit " .. vim.fn.fnameescape(bufname))
    local bufnr = vim.api.nvim_get_current_buf()
    -- 模拟 oil 的副作用：oil 用 buftype="acwrite" 处理远端文件 buffer，
    -- 这正是真实场景下 gitsigns "Non-normal buffer" 被卡住的入口。
    vim.bo[bufnr].buftype = "acwrite"
    -- buftype 改了之后再 fire 一次 BufReadPost，让 gitsigns 重新评估。
    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })
    info("opened bufnr=" .. bufnr .. " name=" .. vim.api.nvim_buf_get_name(bufnr))
    info("buf line count=" .. vim.api.nvim_buf_line_count(bufnr) .. " buftype=" .. vim.bo[bufnr].buftype)

    -- :edit 已经触发 BufReadCmd→BufReadPost→gitsigns attach autocmd 链。
    -- 不再显式调 attach，验证的就是 autocmd 自己跑通。

    -- 强判定：等 cache entry 出现且其 git_obj 已 resolve（说明 backend 走通了 ls-files / cat-file 链）
    local cache_mod = require("gitsigns.cache")
    wait_until(function()
        local entry = cache_mod.cache[bufnr]
        return entry and entry.git_obj and entry.git_obj.relpath ~= nil
    end, 20000, "L4 cache entry with resolved git_obj")

    local entry = cache_mod.cache[bufnr]
    info("relpath=" .. tostring(entry.git_obj.relpath))
    info("object_name=" .. tostring(entry.git_obj.object_name))
    info("toplevel=" .. tostring(entry.git_obj.repo.toplevel))
    info("backend.id=" .. tostring(entry.git_obj.repo.backend and entry.git_obj.repo.backend.id))

    -- 等 hunks 计算完成（baseline 已拿到 + diff_int 跑过）
    wait_until(function()
        return entry.hunks ~= nil
    end, 15000, "L4 hunks computed")
    info("#hunks=" .. tostring(#entry.hunks))
    info("gitsigns_status=" .. tostring(vim.b[bufnr].gitsigns_status))

    -- 输出 debug_messages 给排查用
    local dm = vim.fn.execute("Gitsigns debug_messages")
    out("---- debug_messages start ----")
    out(dm)
    out("---- debug_messages end ----")

    if entry.git_obj.repo.backend and entry.git_obj.repo.backend.id ~= "zero" then
        fail("L4 attached via wrong backend: " .. tostring(entry.git_obj.repo.backend.id))
    end
    ok("L4 passed")
end

-- -----------------------------------------------------------------------------
-- L5: backend.system + stdin (Phase 2B 写命令链路前置)
-- -----------------------------------------------------------------------------
header("L5: backend.system + stdin (cat - 回显校验)")

do
    -- gitsigns stage_hunks 传 string[] patch（每行不带 '\n'）。vim.system 的语义是
    -- 每行 + '\n'（含末尾）—— 用 table 形式喂 cat - 同时验证：
    --   1) daemon stdin 完整透传（不漏字节、不加字节）
    --   2) backend 对 string[] 的拼接含末尾 '\n'（漏这个 git apply 直接 reject）
    local lines = {}
    for i = 1, 100 do
        lines[#lines + 1] = ("line %03d: %s"):format(i, string.rep("x", 50))
    end
    local expected = table.concat(lines, "\n") .. "\n"

    local ctx = zb.detect("zero://" .. USER .. "@" .. HOST .. ":" .. PORT .. REMOTE_PATH)
    local got_exit, result = false, nil
    zb.system(
        { "cat", "-" },
        { stdin = lines, text = true },     -- 注意：传 table，触发末尾 '\n' 补全路径
        ctx,
        function(r)
            got_exit = true; result = r
        end
    )
    wait_until(function() return got_exit end, 10000, "L5 exit")
    info("code=" .. tostring(result.code) .. " stdout_len=" .. tostring(#result.stdout)
        .. " expected_len=" .. tostring(#expected))

    if result.code ~= 0 then
        fail("L5 cat returned non-zero code=" .. tostring(result.code) .. " stderr=" .. tostring(result.stderr))
    end
    if result.stdout ~= expected then
        local last = result.stdout:sub(-1)
        fail(("L5 stdin round-trip mismatch: expected %d bytes, got %d (last_byte=%s)"):format(
            #expected, #result.stdout,
            last == "\n" and "\\n" or string.format("%q", last)
        ))
    end
    ok("L5 passed (" .. #expected .. " bytes round-trip, trailing \\n preserved)")
end

-- -----------------------------------------------------------------------------
-- L6: backend.system + 流式 stdout 回调 (Phase 2B blame 路径契约)
-- -----------------------------------------------------------------------------
header("L6: backend.system + opts.stdout 流式回调 (blame --incremental)")

do
    local ctx = zb.detect("zero://" .. USER .. "@" .. HOST .. ":" .. PORT .. REMOTE_PATH)

    -- 计算 relpath：基于 L2 拿到的 toplevel
    local relpath
    if REMOTE_PATH:sub(1, #toplevel + 1) == toplevel .. "/" then
        relpath = REMOTE_PATH:sub(#toplevel + 2)
    else
        fail("L6 cannot derive relpath: REMOTE_PATH=" .. REMOTE_PATH .. " toplevel=" .. toplevel)
    end
    info("relpath=" .. relpath)

    local chunk_count, eof_seen = 0, false
    local accumulated = {}
    local function on_stdout(_, data)
        if data == nil then
            eof_seen = true
        else
            chunk_count = chunk_count + 1
            accumulated[#accumulated + 1] = data
        end
    end

    local got_exit, result = false, nil
    zb.system(
        { "git", "blame", "--incremental", "HEAD", "--", relpath },
        {
            cwd = toplevel,
            env = { LC_ALL = "C", LANGUAGE = "C" },
            text = true,
            stdout = on_stdout,
        },
        ctx,
        function(r) got_exit = true; result = r end
    )

    wait_until(function() return got_exit end, 15000, "L6 exit")
    info("chunk_count=" .. chunk_count .. " eof_seen=" .. tostring(eof_seen))
    info("code=" .. tostring(result.code) .. " result.stdout_len=" .. tostring(#result.stdout))

    if result.code ~= 0 then
        fail("L6 blame non-zero code=" .. tostring(result.code) .. " stderr=" .. tostring(result.stderr))
    end
    if not eof_seen then
        fail("L6 opts.stdout was never called with nil (EOF) — coroutine readers will hang")
    end
    if chunk_count == 0 then
        fail("L6 opts.stdout never received data chunks")
    end
    if #result.stdout ~= 0 then
        fail("L6 result.stdout should be empty when callback used (vim.system semantics), got len=" .. #result.stdout)
    end
    -- blame --incremental 第一行是 "<sha> <orig> <final> <size>"
    local joined = table.concat(accumulated)
    if not joined:match("^%x+ %d+ %d+ %d+") then
        fail("L6 blame output doesn't look like --incremental format: " .. joined:sub(1, 80))
    end
    ok("L6 passed (" .. chunk_count .. " chunks, EOF nil received)")
end

-- -----------------------------------------------------------------------------
out("")
ok("ALL LAYERS PASSED")
os.exit(0)
