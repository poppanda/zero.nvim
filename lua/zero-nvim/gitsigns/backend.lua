-- =============================================================================
-- zero-nvim/gitsigns/backend.lua — gitsigns 数据层后端
-- =============================================================================
-- 把 gitsigns 跑 git 命令的工作转给 zero-nvim daemon，让远程 zero:// buffer
-- 也能渲染 diff signs / hunk 跳转 / blame 等功能。
--
-- 注册时机：在 zero-nvim 的 setup() 里（用户已经 require gitsigns 之后）。
-- 不会污染普通本地文件——pattern 限定 ^zero://，gitsigns 默认 local backend
-- 处理其他 buffer。

local cmd = require("zero-nvim.cmd")

local M = {}

--- ctx = { target, path, id }；id 含 user/host/port，确保不同主机的同名
--- gitdir 不会撞 Repo 缓存。
M.detect = require("zero-nvim.uri").backend_ctx

---@param ctx table
---@param _bufpath string  -- original buffer name (unused; ctx already holds the parsed path)
---@return string  -- daemon-canonical 的 remote 绝对路径
function M.resolve_path(ctx, _bufpath)
    return ctx.path
end

--- gitsigns 的 system 是 callback 风格 (cmd, opts, on_exit)；on_exit 接收 SystemCompleted。
--- 我们用 cmd.stream 累积 stdout/stderr，于 exit 事件回调时合成 SystemCompleted。
---
--- opts.cwd 是远端绝对路径（gitsigns 传入 toplevel）；env 是 lua dict，
--- stdin 可能是字符串或 string[]；timeout 是秒，daemon 期望毫秒。
---
--- 流式回调（vim.SystemOpts.stdout / .stderr）：当 caller 提供函数时，每个 chunk
--- 立刻 `cb(nil, text)`；EOF（exit/aborted）调一次 `cb(nil, nil)` 关闭流。这是
--- gitsigns blame --incremental 用 buffered_line_reader（coroutine yield）等数据
--- 的契约——少了那个 nil 收尾，coroutine 永远阻塞，blame 不会出结果。
--- 用了流式回调的通道，对应 SystemCompleted.stdout/stderr 留空（与 vim.system 语义一致）。
---@param argv string[]
---@param opts table
---@param ctx table
---@param gitsigns_on_exit fun(obj: table)
function M.system(argv, opts, ctx, gitsigns_on_exit)
    -- gitsigns 的 stage_hunks 用 string[] patch；daemon stdin 是 bytes。
    -- vim.system 对 string[] 的语义是 *每* 行都补一个 '\n'（含末尾），等价于
    -- table.concat(arr, "\n") .. "\n"。漏掉这个末尾 '\n'，git apply 会报
    -- "corrupt patch at line N"（patch 必须以 \n 结尾），stage_hunk 直接失败。
    local stdin = opts.stdin
    if type(stdin) == "table" then
        stdin = table.concat(stdin, "\n") .. "\n"
    end

    local stdout_cb = type(opts.stdout) == "function" and opts.stdout or nil
    local stderr_cb = type(opts.stderr) == "function" and opts.stderr or nil

    local stdout_chunks, stderr_chunks = {}, {}

    local _, err = cmd.stream(ctx.target, {
        argv = cmd.with_remote_path(argv),
        cwd = opts.cwd,
        env = cmd.env_pairs(opts.env),
        stdin = stdin,
        timeout_ms = opts.timeout and (opts.timeout * 1000) or nil,
    }, {
        on_event = function(ev)
            if ev.kind == "stdout" then
                if stdout_cb then
                    stdout_cb(nil, ev.text)
                else
                    stdout_chunks[#stdout_chunks + 1] = ev.text
                end
            elseif ev.kind == "stderr" then
                if stderr_cb then
                    stderr_cb(nil, ev.text)
                else
                    stderr_chunks[#stderr_chunks + 1] = ev.text
                end
            end
        end,
        on_exit = function(code, signal, reason, _dur)
            -- 流式回调用 nil 收尾——blame 的 coroutine reader 靠这个跳出 yield。
            if stdout_cb then stdout_cb(nil, nil) end
            if stderr_cb then stderr_cb(nil, nil) end
            gitsigns_on_exit({
                stdout = stdout_cb and "" or table.concat(stdout_chunks),
                stderr = stderr_cb and "" or table.concat(stderr_chunks),
                -- aborted（比如 buffer wipeout 触发取消）→ 用 -1 让 gitsigns ignore_error 路径处理；
                -- 正常退出走 daemon 报告的 code。
                code = reason and -1 or (code or 0),
                signal = signal or 0,
            })
        end,
    })

    if err then
        -- 启动失败（连接没建好、target 不可达等）：直接合成失败 SystemCompleted。
        -- 流式回调也要发 nil，避免 blame 的 coroutine 永远等。
        vim.schedule(function()
            if stdout_cb then stdout_cb(nil, nil) end
            if stderr_cb then stderr_cb(nil, nil) end
            gitsigns_on_exit({ stdout = "", stderr = tostring(err), code = -1, signal = 0 })
        end)
    end
end

--- 把 backend 注册到 fork 版 gitsigns。fork 提供 `gitsigns.backends` 模块。
--- 如果用户装的是 upstream gitsigns（没这个模块），静默跳过——本地仍可用。
---
--- opts: { refresh = { debounce_ms?, poll_ms? } } —— 透传给 refresh 子模块。
--- refresh 不依赖 backends 注册成功（autocmd 永远要装，本地 fallback 也好用），
--- 所以即使上面 pcall 失败也照常 setup。
---@param opts table?
function M.setup(opts)
    opts = opts or {}
    local ok, backends = pcall(require, "gitsigns.backends")
    if ok then
        backends.register({
            id = "zero",
            pattern = "^zero://",
            detect = M.detect,
            resolve_path = M.resolve_path,
            system = M.system,
        })
    end
    require("zero-nvim.gitsigns.refresh").setup(opts.refresh)
end

return M
