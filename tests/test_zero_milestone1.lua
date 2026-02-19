-- Ensure lua/ directory is in package.path
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local remote = require('zero-nvim.init')

local function run_test()
    print("Running Milestone 1 Test...")

    -- 1. Mock vim.system to intercept SSH calls
    local original_system = vim.system
    local last_cmd = nil
    local mock_stdout = "Hello from remote\nLine 2"

    vim.system = function(cmd, opts, on_exit)
        last_cmd = cmd
        -- Simulate async success
        vim.schedule(function()
            on_exit({ code = 0, stdout = mock_stdout, stderr = "" })
        end)
        -- Return dummy handle
        return { kill = function() end, wait = function() end }
    end

    -- 2. Setup plugin
    remote.setup()

    -- 3. Create a buffer with remote:// name
    local buf = vim.api.nvim_create_buf(true, false)
    local uri = "remote://testuser@192.168.1.10:/tmp/remote_file.txt"
    vim.api.nvim_buf_set_name(buf, uri)

    -- 4. Trigger the autocommand manually
    -- Note: In a real scenario, :edit would trigger this.
    -- Here we manually invoke the callback logic via doautocmd or just rely on the event.
    -- Since we are in -l mode, we need to ensure the main loop processes events.

    print("Triggering BufReadCmd for " .. uri)
    vim.api.nvim_exec_autocmds("BufReadCmd", { group = "ZeroNvim", buffer = buf })

    -- 5. Validate Command Execution
    if not last_cmd then
        error("FAIL: vim.system was not called!")
    end

    local expected_cmd_str = "ssh -o BatchMode=yes -o ConnectTimeout=5 testuser@192.168.1.10 cat /tmp/remote_file.txt"
    local actual_cmd_str = table.concat(last_cmd, " ")

    if actual_cmd_str ~= expected_cmd_str then
        error(string.format([[FAIL: Command mismatch.
Expected: %s
Got:      %s]], expected_cmd_str, actual_cmd_str))
    else
        print("PASS: SSH command constructed correctly.")
    end

    -- 6. Validate Buffer Content (Async)
    -- We need to wait for vim.schedule to run
    local done = false
    vim.wait(1000, function()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        if #lines > 0 and lines[1] ~= "" then
            return true
        end
        return false
    end)

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if #lines == 2 and lines[1] == "Hello from remote" and lines[2] == "Line 2" then
        print("PASS: Buffer content updated correctly.")
    else
        error("FAIL: Buffer content mismatch. Got: " .. vim.inspect(lines))
    end

    -- 7. Validate ReadOnly Status
    local readonly = vim.api.nvim_get_option_value('readonly', { buf = buf })
    if readonly then
        print("PASS: Buffer is readonly.")
    else
        error("FAIL: Buffer should be readonly.")
    end

    -- Restore
    vim.system = original_system
    print("All tests passed!")
end

-- Run the test
run_test()
