-- =============================================================================
-- scripts/e2e_phase3a_init.lua — Phase 3A 远端 E2E 验证用 minimal init
-- =============================================================================
-- 不污染用户日常 nvim 配置：用一个临时数据目录起独立 session，把 fork neogit
-- + zero-nvim + plenary 全挂上来，user 在里面手动跑 :Neogit cwd=zero://...
--
-- 用法：
--   nvim -u /Users/smile./Code/Neovim/zero.nvim/scripts/e2e_phase3a_init.lua
--
-- 然后在 nvim 里：
--   :Neogit cwd=zero://USER@HOST:PORT/path/to/remote/repo
--
-- 关闭：:qa! 即可。配置 / state 都在 /tmp/zero-e2e-3a/，不影响平时用的 nvim。

-- 1) 临时数据目录（避免污染 ~/.local/share/nvim 之类的真实状态）
local TMP = "/tmp/zero-e2e-3a"
vim.fn.mkdir(TMP .. "/data", "p")
vim.fn.mkdir(TMP .. "/state", "p")
vim.fn.mkdir(TMP .. "/cache", "p")
vim.env.XDG_DATA_HOME = TMP .. "/data"
vim.env.XDG_STATE_HOME = TMP .. "/state"
vim.env.XDG_CACHE_HOME = TMP .. "/cache"
-- 调试模式：daemon stderr → /tmp/zero-daemon.log（panic / SIGPIPE 事后可查）
vim.env.ZERO_NVIM_DEBUG = "1"
-- 起个干净 log（保留上次会话内容会让排查更乱）
vim.fn.delete("/tmp/zero-daemon.log")

-- 2) 把三个插件挂到 rtp。如果你 lazy 把 plenary / nvim-web-devicons 装在别处，
--    改下面两个路径即可；fork 路径写死在 ~/Code/Neovim/neogit。
local HOME = os.getenv("HOME")
local PATHS = {
    HOME .. "/Code/Neovim/zero.nvim",                    -- zero-nvim 主体
    HOME .. "/Code/Neovim/neogit",                       -- fork neogit (zero-nvim-backend 分支)
    HOME .. "/.local/share/nvim/lazy/plenary.nvim",      -- neogit 强依赖
    HOME .. "/.local/share/nvim/lazy/nvim-web-devicons", -- neogit 软依赖（没装也能跑）
}
for _, p in ipairs(PATHS) do
    if vim.fn.isdirectory(p) == 1 then
        vim.opt.runtimepath:prepend(p)
    end
end

-- 3) 起 zero-nvim：daemon 配置默认（debug build 跑 cargo build 出的 binary）。
--    如果你平时用 release build 或自定义路径，改 build_type / daemon_path。
require("zero-nvim").setup({
    -- explorer = "zero",  -- 默认即 zero，不用 oil 适配，避免干扰本测试
    -- build_type = "release",  -- 如果用 release 改这里
})

-- 4) 起 neogit（fork）：默认 setup 即可——zero-nvim.setup 内部已经把 backend
--    register 到 fork 的 backends registry 上。
require("neogit").setup({
    -- 关掉 watcher 也可以；默认是开的，3A 用我们的 backend.watch
    -- filewatcher = { enabled = true },
})

-- 5) 友好提示：启动后告诉用户怎么用
vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
        vim.schedule(function()
            local lines = {
                "================ Phase 3A E2E ================",
                "fork neogit + zero-nvim 已挂载。",
                "",
                "现在执行（替换成你的远端 repo）：",
                "  :Neogit cwd=zero://USER@HOST:PORT/path/to/repo",
                "",
                "关闭：:qa!",
                "==============================================",
            }
            vim.api.nvim_echo(vim.tbl_map(function(l) return { l, "MoreMsg" } end, lines), false, {})
        end)
    end,
})
