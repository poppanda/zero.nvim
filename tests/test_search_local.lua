-- :ZeroSearch 本地端到端（需要 PATH 里有 rg，没有则跳过）：结果树、预览、
-- 迟到事件丢弃、truncated 提示
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local function check(cond, msg)
    if not cond then error(msg, 2) end
end

if vim.fn.executable("rg") == 0 then
    print("test_search_local: skipped (rg not found)")
    return
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local function write(name, lines) vim.fn.writefile(lines, dir .. "/" .. name) end
write("a.lua", { "local needle = 1", "print(needle)" })
write("b.txt", { "no match here", "another needle" })

local search = require("zero-nvim.search")
search.last.query = ""
search.open_ui({ is_local = true, initial_path = dir })
local s = search.current_session

--- 等本轮搜索完全落定：代号已换（防抖已触发）、rg 已结束、无待执行的增量渲染。
--- 不用固定 sleep：防抖 / 节流 timer 在负载下会晚到。
local function wait_settled(gen)
    local ok = vim.wait(5000, function()
        return s.id ~= gen and s.job_id == nil and not s.render_scheduled
    end, 10)
    check(ok, "search did not settle")
end

local function run(query)
    -- 改 query 走 on_lines 防抖（350ms）触发搜索
    local gen = s.id
    vim.api.nvim_buf_set_lines(s.input_buf, 0, -1, false, { query })
    wait_settled(gen)
end

local function press(buf, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.lhs == lhs then return m.callback() end
    end
    error("no mapping " .. lhs)
end

--- 等选中节点的预览渲染完（预览有 100ms 防抖）
local function wait_preview()
    local node = s.nodes[s.selected_index]
    local key = node.file .. "\n" .. tostring(node.lnum) .. ":" .. tostring(node.col)
    check(vim.wait(2000, function() return s.preview_key == key end, 10), "preview not rendered")
end

-- 1. 结果树：2 个文件 + spacer，匹配行带行号（rg 多线程，文件顺序不固定）
run("needle")
check(#s.files == 2 and s.match_count == 3, "expected 2 files / 3 matches, got " .. #s.files .. "/" .. s.match_count)
local lines = vim.api.nvim_buf_get_lines(s.results_buf, 0, -1, false)
check(#lines == #s.nodes, "one node per rendered line")
local a_row
for i, n in ipairs(s.nodes) do
    if n.type == "file" and n.file:match("/a%.lua$") then a_row = i end
end
check(a_row and lines[a_row + 1]:match("^%s+1 │ local needle"), "match row: " .. tostring(a_row and lines[a_row + 1]))
check(s.selected_index == 1 and s.nodes[1].type == "file", "first row selected")

-- 2. 预览：选中 match 行后预览窗口显示文件内容
press(s.results_buf, "j")
local node = s.nodes[s.selected_index]
check(s.selected_index == 2 and node.type == "match", "j moves onto a match row")
wait_preview()
local pv = vim.api.nvim_buf_get_lines(s.preview_buf, 0, -1, false)
local expect = vim.fn.readfile(node.file)
check(vim.deep_equal(pv, expect), "preview shows file content: " .. vim.inspect(pv))

-- 2b. 带上次 query 重开：恢复上次选中位置
search.close_ui()
search.open_ui({ is_local = true, initial_path = dir })
s = search.current_session
wait_settled(-1)
check(s.selected_index == 2, "selection restored on reopen, got " .. s.selected_index)

-- 3. 清空 query：结果清空，旧代号被换掉
local gen = s.id
run("")
check(s.id ~= gen and #s.files == 0, "empty query clears results")

-- 4. truncated：超过 5000 条结果时停 rg 并显示提示
local many = {}
for i = 1, 6000 do many[i] = "hit " .. i end
write("many.txt", many)
run("hit")
check(s.truncated and s.match_count == 5000, "truncated at 5000, got " .. tostring(s.match_count))
lines = vim.api.nvim_buf_get_lines(s.results_buf, 0, -1, false)
check(lines[#lines]:match("truncated at 5000"), "truncated note rendered")

search.close_ui()
check(search.current_session == nil, "closed")
vim.fn.delete(dir, "rf")
print("test_search_local: ok")
