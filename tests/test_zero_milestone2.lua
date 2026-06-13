-- Ensure lua/ directory is in package.path
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local remote = require('zero-nvim.init')

local function run_test()
    print("Running Milestone 2 Test (Daemon Integration)...")

    -- Mocks
    local original_jobstart = vim.fn.jobstart
    local original_executable = vim.fn.executable
    local original_rpcrequest = vim.fn.rpcrequest
    local original_input = vim.ui.input
    local original_notify = vim.notify

    local mock_channel_id = 100
    local job_started = false
    local rpc_calls = {}
    local input_prompted = false
    local input_callback = nil

    -- Mock jobstart
    vim.fn.jobstart = function(cmd, opts)
        job_started = true
        print("Mock: jobstart called")
        if opts and opts.on_exit then
            -- Simulate daemon running
        end
        return mock_channel_id
    end
    vim.fn.executable = function(path)
        if path == "/tmp/zero-nvim-daemon-test" then
            return 1
        end
        return original_executable(path)
    end

    -- Mock rpcrequest
    vim.fn.rpcrequest = function(chan, method, ...)
        local args = {...}
        table.insert(rpc_calls, { method = method, args = args })
        print("Mock: rpcrequest called: " .. method)

        if chan ~= mock_channel_id then
            error("Invalid channel id")
        end

        if method == "connect" then
            local user, host, password = args[1], args[2], args[4]
            -- Simulate failure if password is nil (first try)
            if password == nil then
                 error("AUTH_FAILED: Authentication failed")
            end
            -- Simulate success if password provided
            return true
        elseif method == "fetch_path" then
            return { "file", "File Content\nLine 2" }
        end
        return nil
    end

    -- Mock vim.ui.input
    vim.ui.input = function(opts, on_confirm)
        input_prompted = true
        print("Mock: vim.ui.input prompted: " .. opts.prompt)
        input_callback = on_confirm
    end
    
    -- Mock notify
    vim.notify = function(msg, level)
        -- print("Notify: " .. msg)
    end

    -- Setup
    remote.setup({ daemon = { path = "/tmp/zero-nvim-daemon-test" } })

    -- TEST CASE 1: Connection with Password (simulation)
    print("\n--- Test Case 1: Connect with retry/password ---")
    local buf = vim.api.nvim_create_buf(true, false)
    local uri = "zero://user@localhost:22/tmp/file"
    vim.api.nvim_buf_set_name(buf, uri)

    -- Trigger BufReadCmd
    vim.api.nvim_exec_autocmds("BufReadCmd", { group = "ZeroNvim", buffer = buf })

    -- Wait for schedule to trigger ensure_connection -> connect(nil) -> fail -> input prompt
    vim.wait(100, function() return input_prompted end)
    
    if input_prompted then
        print("Pass: Password prompt appeared.")
        -- Simulate user typing password
        if input_callback then
            -- The plugin calls handle_connect_and_fetch inside vim.schedule usually?
            -- Actually my implementation does:
            -- vim.ui.input(..., function(input) 
            --    if input then 
            --       vim.schedule(function() handle_connect_and_fetch(...) end) 
            --    end 
            -- end)
            
            input_callback("secret")
            
            -- Wait for retry logic
            vim.wait(200, function() 
                -- Wait until we see fetch_path called
                for _, call in ipairs(rpc_calls) do
                    if call.method == "fetch_path" then return true end
                end
                return false
            end)
            
            -- Check RPC calls
            local connect_count = 0
            local fetch_called = false
            
            for _, call in ipairs(rpc_calls) do
                if call.method == "connect" then
                    connect_count = connect_count + 1
                elseif call.method == "fetch_path" then
                    fetch_called = true
                end
            end
            
            if connect_count >= 2 and fetch_called then
                print("Pass: RPC calls flow correct (Connect(fail) -> Connect(success) -> Fetch).")
            else
                print("Fail: RPC calls mismatch. Calls: " .. vim.inspect(rpc_calls))
            end

        else
             print("Fail: No input callback captured.")
        end

    else
        print("Fail: Input was not prompted.")
        -- Debug info
        print("Job started: " .. tostring(job_started))
        print("RPC calls: " .. vim.inspect(rpc_calls))
    end
    
    -- Restore
    vim.fn.jobstart = original_jobstart
    vim.fn.executable = original_executable
    vim.fn.rpcrequest = original_rpcrequest
    vim.ui.input = original_input
    vim.notify = original_notify
    
    print("\nTest Finished.")
end

run_test()
