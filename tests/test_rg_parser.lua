-- rg --json parser：跨 chunk 切分、CRLF、无 submatch、bytes 字段、finalize
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local rg = require("zero-nvim.cmd.parsers.rg")

local function check(cond, msg)
    if not cond then error(msg, 2) end
end

local function enc(obj) return vim.json.encode(obj) end

local function match_line(path, lnum, text, subs)
    return enc({
        type = "match",
        data = {
            path = path,
            lines = text,
            line_number = lnum,
            submatches = subs,
        },
    })
end

local function feed_all(p, chunks)
    local out = {}
    for _, c in ipairs(chunks) do
        vim.list_extend(out, p:feed(c) or {})
    end
    return out
end

-- 1. 一行 JSON 被切到多个 chunk 里
do
    local p = rg.new()
    local line = match_line({ text = "/a.lua" }, 3, { text = "local foo = 1\n" },
        { { match = { text = "foo" }, start = 6, ["end"] = 9 } }) .. "\n"
    local chunks = {}
    for i = 1, #line, 7 do chunks[#chunks + 1] = line:sub(i, i + 6) end
    local evs = feed_all(p, chunks)
    check(#evs == 1, "split chunks: expected 1 event, got " .. #evs)
    local ev = evs[1]
    check(ev.kind == "match" and ev.file == "/a.lua" and ev.lnum == 3, "split chunks: bad match event")
    check(ev.col == 7 and ev.match_len == 3, "split chunks: bad col/len")
    check(ev.text == "local foo = 1", "split chunks: trailing newline not stripped: " .. vim.inspect(ev.text))
end

-- 2. CRLF 行尾（JSON 行和匹配文本本身）
do
    local p = rg.new()
    local line = match_line({ text = "/b.txt" }, 1, { text = "hello\r\n" },
        { { match = { text = "hello" }, start = 0, ["end"] = 5 } }) .. "\r\n"
    local evs = p:feed(enc({ type = "begin", data = { path = { text = "/b.txt" } } }) .. "\r\n" .. line)
    check(#evs == 2, "crlf: expected 2 events, got " .. #evs)
    check(evs[1].kind == "file_begin" and evs[1].file == "/b.txt", "crlf: file_begin")
    check(evs[2].text == "hello", "crlf: text should drop \\r\\n: " .. vim.inspect(evs[2].text))
end

-- 3. 没有 submatches 的 match / 多个 submatch
do
    local p = rg.new()
    local evs = p:feed(match_line({ text = "/c" }, 9, { text = "x\n" }, {}) .. "\n"
        .. match_line({ text = "/c" }, 10, { text = "ab ab\n" }, {
            { match = { text = "ab" }, start = 0, ["end"] = 2 },
            { match = { text = "ab" }, start = 3, ["end"] = 5 },
        }) .. "\n")
    check(#evs == 3, "submatches: expected 3 events, got " .. #evs)
    check(evs[1].col == 1 and evs[1].match_len == 0, "no submatch: col 1 len 0")
    check(evs[2].col == 1 and evs[3].col == 4, "multi submatch cols")
    -- 完全缺 submatches 字段也不能崩
    local evs2 = p:feed(enc({ type = "match", data = { path = { text = "/d" }, lines = { text = "y" }, line_number = 1 } }) .. "\n")
    check(#evs2 == 1 and evs2[1].match_len == 0, "missing submatches field")
end

-- 4. 非 UTF-8 路径/行：rg 用 base64 {bytes=...}
do
    local p = rg.new()
    local raw_path = "/data/caf\xe9.txt"
    local raw_line = "na\xefve match\n"
    local evs = p:feed(match_line({ bytes = vim.base64.encode(raw_path) }, 2,
        { bytes = vim.base64.encode(raw_line) },
        { { match = { text = "match" }, start = 6, ["end"] = 11 } }) .. "\n")
    check(#evs == 1, "bytes: expected 1 event, got " .. #evs)
    check(evs[1].file == raw_path, "bytes: path not decoded: " .. vim.inspect(evs[1].file))
    check(evs[1].text == "na\xefve match", "bytes: line not decoded")
end

-- 5. 非 JSON 行 → parse_error；summary 忽略；空行跳过
do
    local p = rg.new()
    local evs = p:feed("rg: unrecognized flag --json\n\n" .. enc({ type = "summary", data = {} }) .. "\n")
    check(#evs == 1 and evs[1].kind == "parse_error", "parse_error / summary handling")
end

-- 6. finalize 冲刷没有结尾换行的最后一行；再次 finalize 为空
do
    local p = rg.new()
    local line = match_line({ text = "/e" }, 5, { text = "tail" },
        { { match = { text = "tail" }, start = 0, ["end"] = 4 } })
    local evs = p:feed(line)
    check(#evs == 0, "partial line should be buffered")
    local tail = p:finalize()
    check(#tail == 1 and tail[1].kind == "match" and tail[1].lnum == 5, "finalize should flush partial last line")
    check(#p:finalize() == 0, "second finalize should be empty")
end

-- 7. stderr 透传
do
    local p = rg.new()
    local evs = p:feed_err("permission denied")
    check(#evs == 1 and evs[1].kind == "stderr" and evs[1].text == "permission denied", "stderr passthrough")
end

print("test_rg_parser: ok")
