-- Read/write flow against a mocked daemon (no network): canonical buffer
-- names, single fetch per :edit, load-failure write guard, synchronous
-- writes, range writes, CRLF, NOT_CONNECTED reconnect, batched LSP preload,
-- alias redirect, append, failed-load re-preload, daemon-exit cleanup, oil-mode guard.
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local files = {
    ["/f.txt"] = "a\nb\nc\n",
    ["/dos.txt"] = "x\r\ny\r\n",
    ["/r1.lua"] = "one\n",
    ["/r2.lua"] = "two\n",
}
local dirs = { ["/dir"] = true, ["/dir/"] = true }
local calls = {}
local fail_once = {}

vim.fn.executable = (function(orig)
    return function(p) if p == "/tmp/zero-test-daemon" then return 1 end return orig(p) end
end)(vim.fn.executable)
local job_opts
vim.fn.jobstart = function(_, o) job_opts = o; return 77 end
vim.rpcnotify = function() end
vim.notify = function() end
vim.fn.rpcrequest = function(chan, method, ...)
    local a = { ... }
    table.insert(calls, { method = method, args = a })
    if fail_once[method] then
        local e = fail_once[method]
        fail_once[method] = nil
        error(e)
    end
    if method == "connect" then return true end
    if method == "fetch_path" then
        local p = a[4]
        if dirs[p] then return { "directory" } end
        if p == "/denied.txt" or p == "/denied2.txt" then error("Permission denied") end
        if not files[p] then error("路径不存在: " .. p) end
        return { "file", files[p] }
    end
    if method == "fetch_paths" then
        local out = {}
        for _, p in ipairs(a[4]) do out[p] = files[p] end
        return out
    end
    if method == "read_dir" then return { { name = "sub", type = "directory" }, { name = "x.txt", type = "file" } } end
    if method == "write_file" then files[a[4]] = a[5]; return true end
    return true
end

local zero = require("zero-nvim")
zero.setup({ daemon = { path = "/tmp/zero-test-daemon" } })

local function count(method)
    local n = 0
    for _, c in ipairs(calls) do if c.method == method then n = n + 1 end end
    return n
end
local function check(cond, msg) if not cond then error(msg .. "\ncalls: " .. vim.inspect(calls), 2) end end

-- 1. :edit without port → canonical name, exactly one fetch
vim.cmd("edit zero://u@h/f.txt")
local buf = vim.api.nvim_get_current_buf()
check(vim.api.nvim_buf_get_name(buf) == "zero://u@h:22/f.txt", "buffer renamed to canonical: " .. vim.api.nvim_buf_get_name(buf))
check(count("fetch_path") == 1, "single fetch per :edit")
check(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "c" }), "content loaded")
check(vim.bo[buf].modified == false, "unmodified after load")
check(vim.bo[buf].buflisted, "listed when shown in a window")

-- 2. synchronous write clears modified immediately (so :wq works)
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "A" })
vim.cmd("write")
check(files["/f.txt"] == "A\nb\nc\n", "written content: " .. vim.inspect(files["/f.txt"]))
check(vim.bo[buf].modified == false, "modified cleared synchronously")

-- 3. range write to another target leaves this buffer's modified alone
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "Z" })
vim.cmd("2,3write zero://u@h:22/other.txt")
check(files["/other.txt"] == "b\nc\n", "range write content: " .. vim.inspect(files["/other.txt"]))
check(vim.bo[buf].modified == true, "range write must not clear modified")
vim.cmd("write zero://u@h:22/copy.txt")
check(files["/copy.txt"] == "Z\nb\nc\n", "full write to other target")
check(vim.bo[buf].modified == true, "write to other target must not clear modified")
vim.cmd("write")

-- 4. failed read → write refused, :w! overrides
vim.cmd("edit zero://u@h:22/denied.txt")
local dbuf = vim.api.nvim_get_current_buf()
check(vim.b[dbuf].zero_load_failed == true, "load failure flagged")
check(vim.bo[dbuf].modifiable == false, "failed buffer not modifiable")
local writes = count("write_file")
vim.cmd("write")
check(count("write_file") == writes, "write refused for a never-loaded buffer")
vim.cmd("write!")
check(count("write_file") == writes + 1, ":w! overrides the guard")

-- 5. missing file → new empty buffer, saving creates it
vim.cmd("edit zero://u@h:22/new.txt")
local nbuf = vim.api.nvim_get_current_buf()
check(vim.bo[nbuf].modifiable and not vim.b[nbuf].zero_load_failed, "missing file is a writable new buffer")
vim.api.nvim_buf_set_lines(nbuf, 0, -1, false, { "hello" })
vim.cmd("write")
check(files["/new.txt"] == "hello\n", "new file written")

-- 6. CRLF preserved
vim.cmd("edit zero://u@h:22/dos.txt")
local cbuf = vim.api.nvim_get_current_buf()
check(vim.bo[cbuf].fileformat == "dos", "dos detected")
check(vim.deep_equal(vim.api.nvim_buf_get_lines(cbuf, 0, -1, false), { "x", "y" }), "CR stripped")
vim.bo[cbuf].modified = true
vim.cmd("write")
check(files["/dos.txt"] == "x\r\ny\r\n", "CRLF written back: " .. vim.inspect(files["/dos.txt"]))

-- 7. NOT_CONNECTED → reconnect + retry once
local connects = count("connect")
fail_once.write_file = "NOT_CONNECTED: u@h:22"
vim.bo[cbuf].modified = true
vim.cmd("write")
check(count("connect") == connects + 1, "reconnected after NOT_CONNECTED")
check(vim.bo[cbuf].modified == false, "retry succeeded")

-- 8. directory without trailing slash → renamed with slash
vim.cmd("edit zero://u@h:22/dir")
local dirbuf = vim.api.nvim_get_current_buf()
check(vim.api.nvim_buf_get_name(dirbuf) == "zero://u@h:22/dir/", "dir name gets trailing slash: " .. vim.api.nvim_buf_get_name(dirbuf))
check(vim.b[dirbuf].zero_is_dir == true, "dir flagged")

-- 9. LSP locations: one batched fetch_paths, buffers loaded but unlisted
local before_paths, before_path = count("fetch_paths"), count("fetch_path")
local items = vim.lsp.util.locations_to_items({
    { uri = "zero://u@h:22/r1.lua", range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } } },
    { uri = "zero://u@h//r2.lua", range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } } },
}, "utf-16")
check(count("fetch_paths") == before_paths + 1, "batched fetch_paths")
check(count("fetch_path") == before_path, "no per-file fetch after batch")
check(#items == 2 and items[1].text == "one" and items[2].text == "two", "item text: " .. vim.inspect(items))
for _, it in ipairs(items) do
    local b = vim.fn.bufnr(it.filename)
    check(b > 0 and not vim.bo[b].buflisted, "quickfix-only buffer stays unlisted: " .. it.filename)
end

-- 10. readfile() patch honours max / binary
check(vim.deep_equal(vim.fn.readfile("zero://u@h:22/f.txt", "", 2), { "Z", "b" }), "readfile max")
check(vim.deep_equal(vim.fn.readfile("zero://u@h:22/f.txt", "b"), { "Z", "b", "c", "" }), "readfile binary")
check(not pcall(vim.fn.readfile, "zero://u@h:22/denied2.txt"), "readfile raises on failure")


-- 11. non-canonical alias of an open buffer → window moves to the canonical buffer
vim.cmd("edit zero://u@h:22/f.txt")
local canon_buf = vim.api.nvim_get_current_buf()
vim.cmd("edit zero://u@h//f.txt")
local alias_buf = vim.api.nvim_get_current_buf()
check(alias_buf ~= canon_buf and vim.b[alias_buf].zero_alias_of == canon_buf, "alias flagged")
vim.wait(50, function() return not vim.api.nvim_buf_is_valid(alias_buf) end)
check(vim.api.nvim_get_current_buf() == canon_buf, "window redirected to canonical buffer")
check(not vim.api.nvim_buf_is_valid(alias_buf), "alias buffer wiped")

-- 12. :w >> appends to the remote content
vim.cmd("edit zero://u@h:22/f.txt")
local before = files["/f.txt"]
vim.cmd("1write >> zero://u@h:22/f.txt")
check(files["/f.txt"] == before .. "Z\n", "appended: " .. vim.inspect(files["/f.txt"]))

-- 13. LSP preload retries a buffer whose earlier load failed
fail_once.fetch_path = "Permission denied"
vim.cmd("edit zero://u@h:22/r3.lua")
local fbuf = vim.api.nvim_get_current_buf()
check(vim.b[fbuf].zero_load_failed, "r3 load failed")
vim.cmd("buffer " .. canon_buf)
files["/r3.lua"] = "now ok\n"
vim.lsp.util.locations_to_items({
    { uri = "zero://u@h:22/r3.lua", range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } } },
}, "utf-16")
check(not vim.b[fbuf].zero_load_failed, "failed buffer reloaded by preload")
check(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)[1] == "now ok", "reloaded content")

-- 14. daemon exit: per-host state wiped, streams aborted, next request reconnects
local remote = require("zero-nvim.remote")
remote.host_cache("u", "h", 22).marker = true
local aborted
local exec = require("zero-nvim.cmd.exec")
local orig_abort = exec.abort_all
exec.abort_all = function(reason) aborted = reason end
job_opts.on_exit(77, 1)
exec.abort_all = orig_abort
check(aborted and aborted:find("daemon exited", 1, true), "streams aborted")
check(remote.host_cache("u", "h", 22).marker == nil, "host cache wiped")
check(not remote.is_connected("u", "h", 22), "connection state wiped")
local c0 = count("connect")
remote.request("u", "h", 22, "stat", "/f.txt")
check(count("connect") == c0 + 1, "reconnect after daemon restart")

-- 15. oil explorer: no BufReadCmd / BufWriteCmd of ours, File{Write,Append}Cmd kept
zero.setup({ daemon = { path = "/tmp/zero-test-daemon" }, explorer = "oil" })
local evs = {}
for _, a in ipairs(vim.api.nvim_get_autocmds({ group = "ZeroNvim", pattern = "zero://*" })) do evs[a.event] = true end
check(not evs.BufReadCmd and not evs.BufWriteCmd, "oil mode: no BufReadCmd/BufWriteCmd")
check(evs.FileWriteCmd and evs.FileAppendCmd, "oil mode: range/append writes still handled")
zero.setup({ daemon = { path = "/tmp/zero-test-daemon" } })

print("remote read/write test passed")
