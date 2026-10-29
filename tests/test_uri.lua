package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local uri = require("zero-nvim.uri")

local function eq(a, b, what)
    if not vim.deep_equal(a, b) then
        error(string.format("%s: expected %s, got %s", what, vim.inspect(b), vim.inspect(a)), 2)
    end
end

eq({ uri.parse("zero://u@h:2222/a/b") }, { "u", "h", 2222, "/a/b" }, "parse with port")
eq({ uri.parse("zero://u@h/a/b") }, { "u", "h", 22, "/a/b" }, "parse default port")
eq({ uri.parse("zero://u@[::1]:2200/x") }, { "u", "::1", 2200, "/x" }, "parse ipv6 with port")
eq({ uri.parse("zero://u@[fe80::1]/x/") }, { "u", "fe80::1", 22, "/x/" }, "parse ipv6 default port")
eq(uri.parse("zero://h/a"), nil, "no user")
eq(uri.parse("file:///a"), nil, "other scheme")
eq(uri.parse(nil), nil, "nil")

eq(uri.normalize("zero://u@h/p"), "zero://u@h:22/p", "normalize adds port")
eq(uri.normalize("zero://u@h:22/p"), "zero://u@h:22/p", "normalize idempotent")
eq(uri.normalize("zero://u@h:22//a///b/"), "zero://u@h:22/a/b/", "normalize collapses slashes")
eq(uri.normalize("zero://u@h:22/a/./b/."), "zero://u@h:22/a/b/", "normalize drops ./")
eq(uri.normalize("zero://u@[::1]/p"), "zero://u@[::1]:22/p", "normalize ipv6")
eq(uri.normalize("nope"), nil, "normalize invalid")

eq(uri.format("u", "::1", 22, "/p"), "zero://u@[::1]:22/p", "format ipv6 brackets")

eq(uri.parent_dir("/a/b/"), "/a/", "parent of dir")
eq(uri.parent_dir("/a/b"), "/a/", "parent of file")
eq(uri.parent_dir("/a"), "/", "parent of top-level")
eq(uri.parent_dir("/"), "/", "parent of root")
eq(uri.as_dir("/a/b"), "/a/b/", "as_dir")
eq(uri.as_dir("/a/b//"), "/a/b/", "as_dir collapse")
eq(uri.join("/a/b", "c", true), "/a/b/c/", "join dir")
eq(uri.join("/a/b/", "c.txt"), "/a/b/c.txt", "join file")

print("uri test passed")
