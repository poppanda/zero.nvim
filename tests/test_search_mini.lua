-- search_mini：字面匹配（[ . * ~ \ /）与整词边界
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local mini = require("zero-nvim.search_mini")

local function check(cond, msg)
    if not cond then error(msg, 2) end
end

local buf = vim.api.nvim_create_buf(false, true)
local function find(lines, query, opts)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return mini._find_matches(buf, query, opts or {})
end
local function cols(ms)
    local out = {}
    for _, m in ipairs(ms) do out[#out + 1] = ("%d:%d-%d"):format(m.lnum, m.col, m.end_col) end
    return table.concat(out, ",")
end

-- 字面 `[`：以前在 magic 模式下直接让 vim.regex 抛错
local ms = find({ "a[0] = b[1]" }, "[")
check(ms ~= nil, "'[' must not be an invalid pattern")
check(cols(ms) == "1:1-2,1:8-9", "'[' literal: " .. cols(ms))

ms = find({ "arr[i]", "arri]" }, "[i]")
check(cols(ms) == "1:3-6", "'[i]' should not act as a char class: " .. cols(ms))

-- `.` 不是任意字符
ms = find({ "a.b axb" }, "a.b")
check(cols(ms) == "1:0-3", "'.' literal: " .. cols(ms))

-- `*` 不是重复
ms = find({ "x*y xxy xy" }, "x*y")
check(cols(ms) == "1:0-3", "'*' literal: " .. cols(ms))

-- `~` 不是"上次替换串"
ms = find({ "~/foo ~" }, "~")
check(cols(ms) == "1:0-1,1:6-7", "'~' literal: " .. cols(ms))

-- 反斜杠 / 斜杠
ms = find({ [[a\nb a/b]] }, [[\n]])
check(cols(ms) == "1:1-3", "backslash literal: " .. cols(ms))
ms = find({ "a/b" }, "/")
check(cols(ms) == "1:1-2", "slash literal: " .. cols(ms))

-- 大小写
ms = find({ "Foo foo FOO" }, "foo", { case_sensitive = false })
check(#ms == 3, "ignore case should find 3")
ms = find({ "Foo foo FOO" }, "foo", { case_sensitive = true })
check(cols(ms) == "1:4-7", "case sensitive: " .. cols(ms))

-- 同一行多个相邻匹配
ms = find({ "aaaa" }, "aa")
check(cols(ms) == "1:0-2,1:2-4", "adjacent matches: " .. cols(ms))

-- 整词：start 偏移不能制造伪词边界（"foofoo" 第二个 foo 不是整词）
ms = find({ "foofoo foo xfoo foo_ foo" }, "foo", { whole_word = true })
check(cols(ms) == "1:7-10,1:21-24", "whole word with offsets: " .. cols(ms))

ms = find({ "foo foo" }, "foo", { whole_word = true })
check(cols(ms) == "1:0-3,1:4-7", "whole word consecutive: " .. cols(ms))

-- 多字节行
ms = find({ "中文 [x] 中文" }, "中文")
check(#ms == 2 and ms[2].col == #"中文 [x] ", "multibyte columns: " .. cols(ms))

-- 上限
local many = {}
for i = 1, 50 do many[i] = "x x x" end
ms = mini._find_matches(buf, "x", {}, 10)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, many)
ms = mini._find_matches(buf, "x", {}, 10)
check(#ms == 10, "max matches cap")

print("test_search_mini: ok")
