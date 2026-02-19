-- Ensure lua/ directory is in package.path
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local remote = require('zero-nvim.init')

local function run_test()
    print("Running Password Auth Test...")

    -- Mock State
    local system_calls = 0
    local input_called = false
    local password_provided = "secret123"

    -- Mock vim.ui.input
    vim.ui = vim.ui or {}
    vim.ui.input = function(opts, on_confirm)
        -- print("Mock vim.ui.input called with prompt: " .. opts.prompt)
        input_called = true
        on_confirm(password_provided)
    end

    -- Mock vim.system
    local original_system = vim.system
    vim.system = function(cmd, opts, on_exit)
        system_calls = system_calls + 1
        -- print("Mock vim.system called (" .. system_calls .. "): " .. table.concat(cmd, " "))

        if system_calls == 1 then
            -- First call: Fail (BatchMode=yes)
            local cmd_str = table.concat(cmd, " ")
            if not string.match(cmd_str, "BatchMode=yes") then
                error("First call should have BatchMode=yes")
            end
            
            -- Simulate failure
            vim.schedule(function()
                on_exit({ code = 255, stdout = "", stderr = "Permission denied (publickey,password)." })
            end)
        elseif system_calls == 2 then
            -- Second call: Retry with password
            local cmd_str = table.concat(cmd, " ")
            if string.match(cmd_str, "BatchMode=yes") then
                error("Second call should NOT have BatchMode=yes")
            end

            -- Verify Environment
            if not opts.env then
                error("Second call should have env vars")
            end
            if opts.env["ZERO_NVIM_PASSWORD"] ~= password_provided then
                error("Password env var mismatch")
            end
            if not opts.env["SSH_ASKPASS"] then
                error("SSH_ASKPASS not set")
            end

            -- Simulate success
            vim.schedule(function()
                on_exit({ code = 0, stdout = "Content with Password", stderr = "" })
            end)
        end

        return { kill = function() end, wait = function() end }
    end

    -- Setup
    remote.setup()
    local buf = vim.api.nvim_create_buf(true, false)
    local uri = "remote://user@host:/path/file"
    vim.api.nvim_buf_set_name(buf, uri)

    -- Trigger
    -- print("Triggering BufReadCmd...")
    vim.api.nvim_exec_autocmds("BufReadCmd", { group = "ZeroNvim", buffer = buf })

    -- Wait for async operations
    local finished = false
    vim.wait(2000, function()
        if system_calls == 2 then
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            if #lines > 0 and lines[1] == "Content with Password" then
                finished = true
                return true
            end
        end
        return false
    end)

    if not finished then
        error("Test Timed Out or Failed. System calls: " .. system_calls)
    end

    if not input_called then
        error("vim.ui.input was not called")
    end

    print("PASS: Password Auth Test passed.")
end

run_test()
