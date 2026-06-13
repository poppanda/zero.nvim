-- Milestone 3 Test: Directory handling and Caching logic
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"
local remote = require('zero-nvim.init')

local function run_test()
    print("Running Milestone 3 Test (Directory Support)...")

    local mock_channel_id = 101
    local rpc_calls = {}

    vim.fn.jobstart = function() return mock_channel_id end
    vim.fn.rpcrequest = function(chan, method, ...)
        local args = {...}
        table.insert(rpc_calls, { method = method, args = args })
        if method == "stat" then return "directory" end
        if method == "read_dir" then
            return {
                { name = "file1.txt", type = "file" },
                { name = "subdir", type = "directory" }
            }
        end
        if method == "fetch_path" then return { "directory" } end
        return true
    end
    vim.rpcnotify = function(chan, method, ...)
        table.insert(rpc_calls, { method = method, args = {...}, notify = true })
    end

    remote.setup()

    local buf = vim.api.nvim_create_buf(true, false)
    local uri = "zero://user@localhost:22/home/user/project"
    vim.api.nvim_buf_set_name(buf, uri)

    -- Trigger fetch
    remote.handle_fetch(buf, "user", "localhost", 22, "/home/user/project")

    -- Verify RPC calls
    local found_fetch_path = false
    local found_readdir = false
    local found_scan = false

    for _, call in ipairs(rpc_calls) do
        if call.method == "fetch_path" then found_fetch_path = true end
        if call.method == "read_dir" then found_readdir = true end
        if call.method == "scan_project" then found_scan = true end
    end

    if found_fetch_path and found_readdir and found_scan then
        print("Pass: FetchPath, ReadDir and ScanProject called.")
    else
        error(string.format("Fail: Missing RPC calls. FetchPath:%s, ReadDir:%s, Scan:%s",
            tostring(found_fetch_path), tostring(found_readdir), tostring(found_scan)))
    end

    -- Verify buffer content
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local found_file = false
    local found_dir = false
    for _, line in ipairs(lines) do
        if string.match(line, "file1.txt") then found_file = true end
        if string.match(line, "subdir/") then found_dir = true end
    end

    if found_file and found_dir then
        print("Pass: Buffer contains directory entries.")
    else
        error("Fail: Buffer missing entries. Content: " .. vim.inspect(lines))
    end

    print("All Milestone 3 tests passed!")
end

run_test()
