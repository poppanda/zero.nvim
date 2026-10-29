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

local function run(query)
    -- 改 query 走 on_lines 防抖（350ms）触发搜索，再等 rg 结束 + 预览防抖
    vim.api.nvim_buf_set_lines(s.input_buf, 0, -1, false, { query })
    vim.wait(450, function() return false end)
    vim.wait(3000, function() return s.job_id == nil end, 10)
    vim.wait(200, function() return false end)
end

-- 1. 结果树：2 个文件 + spacer，匹配行带行号
run("needle")
check(#s.files == 2 and s.match_count == 3, "expected 2 files / 3 matches, got " .. #s.files .. "/" .. s.match_count)
local lines = vim.api.nvim_buf_get_lines(s.results_buf, 0, -1, false)
check(#lines == #s.nodes, "one node per rendered line")
check(lines[2]:match("^%s+1 │ local needle"), "match row: " .. tostring(lines[2]))
check(s.selected_index == 1 and s.nodes[1].type == "file", "first row selected")

-- 2. 预览：选中 match 行后预览窗口显示文件内容
local function press(buf, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.lhs == lhs then return m.callback() end
    end
    error("no mapping " .. lhs)
end
press(s.results_buf, "j")
vim.wait(300, function() return false end)
local node = s.nodes[s.selected_index]
check(node.type == "match", "j moves onto a match row")
local pv = vim.api.nvim_buf_get_lines(s.preview_buf, 0, -1, false)
check(#pv == 2 and pv[1]:match("needle"), "preview shows file content: " .. vim.inspect(pv))

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
