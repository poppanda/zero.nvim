--- zero-nvim 入口：setup(opts) + :Zero* 命令注册。
--- 具体实现分布在 buffers / link / remote / lsp 等模块。
local M = {}

local config = require("zero-nvim.config")
local log = require("zero-nvim.log")
local daemon = require("zero-nvim.daemon")
local uri = require("zero-nvim.uri")
local buffers = require("zero-nvim.buffers")
local link = require("zero-nvim.link")
local locations = require("zero-nvim.lsp.locations")

-- LSP 模块较重，用到时再加载
local function lsp() return require("zero-nvim.lsp") end
local function lsp_restart() return require("zero-nvim.lsp.restart") end

-- ---------------------------------------------------------------------------
-- 命令
-- ---------------------------------------------------------------------------

local function filter_prefix(items, lead)
    return vim.tbl_filter(function(s) return vim.startswith(s, lead) end, items)
end

--- 第一个参数的补全：当前 buffer 所在远端的 mason bins。
local function complete_mason_bins(lead, line)
    if #vim.split(line, "%s+") > 2 then return {} end
    return filter_prefix(lsp().mason_bins(uri.parse(vim.api.nvim_buf_get_name(0))), lead)
end

local function zero_lsp_add(cmd_opts)
    local user, host, port, path = uri.parse(vim.api.nvim_buf_get_name(0))
    if not user then
        log.error("open a file inside a configured remote project first")
        return
    end
    local project_name, project_config = require("zero-nvim.project.manager").match_project(host, path, user, port)
    if not project_name then
        log.error(string.format("no project matches %s:%s — run :ZeroProject add first", host, path))
        return
    end
    require("zero-nvim.lsp.add_wizard").open({
        user = user, host = host, port = port,
        project_name = project_name,
        project_config = project_config,
        prefill_server = cmd_opts.fargs[1],
    })
end

local function zero_project(cmd_opts)
    local sub, arg = cmd_opts.fargs[1], cmd_opts.fargs[2]
    local project_ui = require("zero-nvim.project.ui")
    if not sub or sub == "" then
        project_ui.show_project_picker()
    elseif sub == "add" then
        project_ui.add_current_project()
    elseif sub == "check" then
        project_ui.check_health(arg)
    else
        log.error("Unknown subcommand: " .. sub)
    end
end

local commands = {
    ZeroLink = {
        function(o) link.run(o.fargs) end,
        nargs = "*",
        desc = "Connect to remote server via SSH config",
        complete = function(lead, line)
            if #vim.split(line, "%s+") > 2 then return {} end
            local hosts = vim.tbl_map(function(e) return e.host end, require("zero-nvim.ssh_config").parse())
            return filter_prefix(hosts, lead)
        end,
    },
    ZeroProject = {
        zero_project,
        nargs = "*",
        desc = "Manage ZeroNvim projects (add, check, or list)",
        complete = function(lead, line)
            local parts = vim.split(line, "%s+")
            if #parts == 2 then return filter_prefix({ "add", "check" }, lead) end
            if #parts == 3 and parts[2] == "check" then
                return filter_prefix(vim.tbl_keys(require("zero-nvim.project.manager").list()), lead)
            end
            return {}
        end,
    },
    ZeroSearch = {
        function() require("zero-nvim.search").live_grep() end,
        nargs = 0,
        desc = "Search remote server (ripgrep)",
    },
    ZeroSearchMini = {
        function() require("zero-nvim.search_mini").open() end,
        nargs = 0,
        desc = "Local buffer search and replace using floating windows",
    },
    -- project 配置里的 cmd / settings 在 start_lsp 内按 config key 解析，
    -- 客户端名与 autostart / prewarm 一致。
    ZeroLspStart = {
        function(o) lsp().start_lsp(0, o.fargs, nil) end,
        nargs = "+",
        desc = "Start remote LSP via TCP proxy (e.g. :ZeroLspStart basedpyright --stdio)",
        complete = complete_mason_bins,
    },
    -- 停掉 Neovim 侧 client 会关闭 TCP socket，daemon 那边的 ssh 子进程随之退出。
    ZeroLspStop = {
        function(o)
            local clients = lsp().stop(o.fargs[1], vim.api.nvim_get_current_buf())
            if #clients == 0 then
                log.warn("no matching LSP client found")
            end
            for _, c in ipairs(clients) do log.info("stopped LSP " .. c.name) end
        end,
        nargs = "?",
        desc = "Stop remote LSP client (e.g. :ZeroLspStop basedpyright or :ZeroLspStop)",
        complete = function(lead)
            local names = {}
            for _, c in ipairs(vim.lsp.get_clients()) do
                if c.name:match("^zero%-") then table.insert(names, (c.name:gsub("^zero%-", ""))) end
            end
            return filter_prefix(names, lead)
        end,
    },
    -- 立刻让所有 dormant LSP（退避重试中）重试一次，并复位 30 分钟时窗。
    ZeroLspRestart = {
        function()
            local count = lsp_restart().revive_dormant_now()
            if count > 0 then
                log.info(string.format("kicked %d dormant LSP%s", count, count == 1 and "" or "s"))
            else
                log.info("no dormant LSPs to revive")
            end
        end,
        nargs = 0,
        desc = "Kick dormant zero-* LSP clients into an immediate retry",
    },
    ZeroLspAdd = {
        zero_lsp_add,
        nargs = "?",
        desc = "Add an LSP server to the current project (interactive)",
        complete = complete_mason_bins,
    },
}

-- ---------------------------------------------------------------------------
-- setup
-- ---------------------------------------------------------------------------

--- LSP 相关 autocmd：按项目配置 autostart、依赖文件挂同主机 server、
--- 恢复时唤醒 dormant client。
local function setup_lsp_autocmds(group)
    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        callback = function(args)
            if uri.is_zero(vim.api.nvim_buf_get_name(args.buf)) then
                lsp().autostart(args.buf, args.match)
            end
        end,
    })
    -- 依赖文件（site-packages、~/.cargo 等）不在项目 root 下，不会触发 autostart：
    -- 挂上同主机正在运行的同名 server。bufload 的临时 autocmd window 不算真正打开；
    -- schedule 出去避开 win_set_buf 期间的限制。
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        pattern = "zero://*",
        callback = function(args)
            if vim.fn.win_gettype() == "autocmd" or args.file:match("/$") then return end
            vim.schedule(function() lsp().attach_matching(args.buf) end)
        end,
    })
    -- 合盖再开 / 切回 Neovim 时网络多半已恢复，没必要等退避计时器走完。
    vim.api.nvim_create_autocmd({ "VimResume", "FocusGained" }, {
        group = group,
        callback = function()
            lsp_restart().revive_dormant_now()
        end,
    })
end

--- True once setup() has run (plugin/zero-nvim.lua uses it to avoid
--- overriding a user's earlier setup(opts) with defaults).
function M.is_configured()
    return config.is_configured()
end

--- 幂等：augroup 每次清空重建，全局补丁只装一次。
function M.setup(opts)
    local options = config.setup(opts)
    local group = vim.api.nvim_create_augroup("ZeroNvim", { clear = true })

    vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = daemon.set_leaving })
    buffers.setup(group, options.explorer)
    locations.install()
    setup_lsp_autocmds(group)

    for name, spec in pairs(commands) do
        vim.api.nvim_create_user_command(name, spec[1],
            { nargs = spec.nargs, desc = spec.desc, complete = spec.complete })
    end

    -- gitsigns / neogit 的远端 backend（需要暴露 backends 的 fork；上游版本静默跳过）
    require("zero-nvim.gitsigns.backend").setup(options.gitsigns)
    require("zero-nvim.neogit.backend").setup(options.neogit)
end

return M
