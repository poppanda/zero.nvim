package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local io_ = require("zero-nvim.buffer_io")

local function eq(a, b, what)
    if not vim.deep_equal(a, b) then
        error(string.format("%s: expected %s, got %s", what, vim.inspect(b), vim.inspect(a)), 2)
    end
end

local function roundtrip(content, what)
    local lines, info = io_.content_to_lines(content)
    local out = io_.lines_to_content(lines, { eol = info.eol, fixeol = not info.has_nul, fileformat = info.fileformat, bomb = info.bomb })
    eq(out, content, what .. " roundtrip")
    return lines, info
end

-- unix with trailing newline
local lines, info = roundtrip("a\nb\n", "unix")
eq(lines, { "a", "b" }, "unix lines")
eq(info.eol, true, "unix eol")
eq(info.fileformat, "unix", "unix ff")

-- no trailing newline: eol=false; fixeol adds it back unless binary
lines, info = io_.content_to_lines("a\nb")
eq(lines, { "a", "b" }, "noeol lines")
eq(info.eol, false, "noeol eol")
eq(io_.lines_to_content(lines, { eol = false, fixeol = true }), "a\nb\n", "fixeol adds newline")
eq(io_.lines_to_content(lines, { eol = false, fixeol = false }), "a\nb", "nofixeol keeps noeol")
eq(io_.lines_to_content(lines, { eol = false, fixeol = true, binary = true }), "a\nb", "binary ignores fixeol")

-- empty file stays empty; single newline stays a single newline
lines, info = roundtrip("", "empty")
eq(lines, { "" }, "empty lines")
eq(info.eol, false, "empty eol")
lines = roundtrip("\n", "single newline")
eq(lines, { "" }, "single newline lines")
-- typing into an empty file gets a final newline (fixeol)
eq(io_.lines_to_content({ "x" }, { eol = false, fixeol = true }), "x\n", "typed into empty")

-- CRLF
lines, info = roundtrip("a\r\nb\r\n", "dos")
eq(lines, { "a", "b" }, "dos lines")
eq(info.fileformat, "dos", "dos ff")
-- mixed endings stay unix (CR preserved in the line)
lines, info = roundtrip("a\r\nb\n", "mixed")
eq(info.fileformat, "unix", "mixed ff")
eq(lines, { "a\r", "b" }, "mixed lines")
-- dos write
eq(io_.lines_to_content({ "x", "y" }, { fileformat = "dos" }), "x\r\ny\r\n", "dos write")

-- BOM
lines, info = roundtrip("\239\187\191hi\n", "bom")
eq(info.bomb, true, "bom detected")
eq(lines, { "hi" }, "bom stripped")

-- binary / non-UTF-8 bytes and NUL pass through untouched
local bin = "\0\1\2\255\254\n\128abc\0"
lines, info = roundtrip(bin, "binary")
eq(info.has_nul, true, "has_nul")

-- through a real buffer (nvim_buf_set_lines / get_lines keep NUL + raw bytes)
local buf = vim.api.nvim_create_buf(false, true)
io_.apply(buf, bin)
eq(vim.bo[buf].modified, false, "apply leaves buffer unmodified")
eq(vim.b[buf].zero_loaded, true, "apply marks loaded")
local out, whole = io_.buffer_content(buf)
eq(out, bin, "binary via buffer")
eq(whole, true, "whole buffer")

io_.apply(buf, "1\r\n2\r\n3\r\n")
eq(vim.bo[buf].fileformat, "dos", "apply sets fileformat")
eq(vim.bo[buf].modified, false, "fileformat change does not mark modified")
out, whole = io_.buffer_content(buf, 2, 2)
eq(out, "2\r\n", "partial range")
eq(whole, false, "partial not whole")

io_.apply(buf, "x\ny")
eq(vim.bo[buf].eol, false, "apply sets noeol")
out = io_.buffer_content(buf, 1, 1)
eq(out, "x\n", "partial range before last line always ends with newline")

io_.mark_failed(buf)
eq(vim.b[buf].zero_load_failed, true, "mark_failed flag")
eq(vim.bo[buf].modifiable, false, "mark_failed nomodifiable")
eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "" }, "mark_failed empties buffer")

eq(io_.is_missing_error("Vim:Error invoking 'fetch_path': 路径不存在: /x"), true, "missing error")
eq(io_.is_missing_error("Permission denied"), false, "other error")

print("buffer_io test passed")

-- to_bytes: daemon Binary content normalised to a Lua byte string
eq(io_.to_bytes("\255\0x"), "\255\0x", "to_bytes string passthrough")
eq(io_.to_bytes({ 255, 0, 120 }), "\255\0x", "to_bytes byte list")
eq(io_.to_bytes({ _TYPE = "binary", _VAL = { "a\nb", "c" } }), "a\0b\nc", "to_bytes msgpack special dict")
eq(io_.to_bytes(nil), nil, "to_bytes nil")
eq(io_.to_bytes(vim.NIL), nil, "to_bytes vim.NIL")
eq(io_.content_to_lines({ 104, 105, 10 }), { "hi" }, "content_to_lines accepts byte list")
print("buffer_io to_bytes test passed")
