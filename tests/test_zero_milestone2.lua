-- Milestone 2: BufReadCmd against a mocked daemon whose first connect fails
-- with AUTH_FAILED → one synchronous password prompt → connect(password) → fetch.
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local calls = {}
local prompted = 0

vim.fn.executable = (function(orig)
    return function(p) if p == "/tmp/zero-nvim-daemon-test" then return 1 end return orig(p) end
end)(vim.fn.executable)
vim.fn.jobstart = function() return 100 end
vim.notify = function() end
-- 交互式密码输入只在有 UI 时弹出
vim.api.nvim_list_uis = function() return { { width = 80, height = 24 } } end
vim.fn.inputsecret = function()
    prompted = prompted + 1
    return "secret"
end
vim.fn.rpcrequest = function(chan, method, ...)
    local args = { ... }
    table.insert(calls, { method = method, args = args })
    assert(chan == 100, "invalid channel id")
    if method == "connect" then
        if args[4] == nil then error("AUTH_FAILED: Authentication failed") end
        return true
    elseif method == "fetch_path" then
        return { "file", "File Content\nLine 2" }
    end
    return nil
end

require("zero-nvim").setup({ daemon = { path = "/tmp/zero-nvim-daemon-test" } })

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buf, "zero://user@localhost:22/tmp/file")
vim.api.nvim_exec_autocmds("BufReadCmd", { group = "ZeroNvim", buffer = buf })

local methods = vim.tbl_map(function(c) return c.method end, calls)
assert(prompted == 1, "password prompted once, got " .. prompted)
assert(vim.deep_equal(methods, { "connect", "connect", "fetch_path" }), "rpc flow: " .. vim.inspect(methods))
assert(calls[2].args[4] == "secret", "second connect carries the password")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "File Content", "Line 2" }), "content loaded")
assert(vim.b[buf].zero_loaded == true and not vim.b[buf].zero_load_failed, "buffer flagged loaded")

print("milestone 2 test passed")
