-- search / search_mini 浮窗 teardown：关掉任一浮窗 → 全部关闭、timer 关闭、session 清空
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local function check(cond, msg)
    if not cond then error(msg, 2) end
end
local function flush() vim.wait(50, function() return false end) end

local search = require("zero-nvim.search")

-- 1. 全局搜索：关掉 preview 窗口（非 q/<Esc> 路径）
search.last_query = ""
search.open_ui({ is_local = true, initial_path = vim.fn.getcwd() })
local s = search.current_session
check(s and vim.api.nvim_win_is_valid(s.results_win), "search UI should open")
local wins = { s.path_win, s.input_win, s.results_win, s.preview_win }
local t1, t2 = s.timer1, s.timer2
vim.api.nvim_win_close(s.preview_win, true)
flush()
check(search.current_session == nil, "current_session should be cleared after WinClosed")
for _, w in ipairs(wins) do
    check(not vim.api.nvim_win_is_valid(w), "all search floats should be closed")
end
check(t1:is_closing() and t2:is_closing(), "debounce timers should be closed")
-- 重复 close 无害
search.close_ui(s)

-- 2. 清空 query 会换代号（旧 stream 迟到结果被丢弃）
search.open_ui({ is_local = true, initial_path = vim.fn.getcwd() })
s = search.current_session
local id_before = s.id
search.execute_search(false, false)
check(s.id ~= id_before, "execute_search with empty query must bump generation")
search.close_ui()
check(search.current_session == nil, "q path teardown")

-- 3. mini search：关掉结果窗口 → 输入窗口也关
local src = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(src, 0, -1, false, { "hello [world]", "hello again" })
local ui_mini = require("zero-nvim.ui.search_mini")
local captured
local orig_create = ui_mini.create_ui
ui_mini.create_ui = function(st)
    captured = st
    return orig_create(st)
end
require("zero-nvim.search_mini").open()
check(captured and vim.api.nvim_win_is_valid(captured.results_win), "mini UI should open")
local in_win, timer = captured.input_win, captured.timer
vim.api.nvim_win_close(captured.results_win, true)
flush()
check(not vim.api.nvim_win_is_valid(in_win), "mini input float should close with results float")
check(captured.active == false and captured.timer == nil, "mini state should be torn down")
check(timer:is_closing(), "mini timer should be closed")

print("test_search_ui_teardown: ok")
