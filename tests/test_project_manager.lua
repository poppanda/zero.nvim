package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local store = require("zero-nvim.project.store")
local projects = {
    legacy = { host = "dev", root = "/srv/app" },                         -- no user/port: wildcard
    alice = { host = "dev", user = "alice", port = 22, root = "/srv/app/" },
    bob_sub = { host = "dev", user = "bob", port = 2222, root = "/srv/app/pkg" },
    broken = { host = "dev", user = "alice" },                            -- nil root must not crash
    other = { host = "prod", user = "alice", port = 22, root = "/srv" },
}
store.load = function() return projects end

local manager = require("zero-nvim.project.manager")

local function eq(a, b, what)
    if a ~= b then error(string.format("%s: expected %s, got %s", what, tostring(b), tostring(a)), 2) end
end

eq(manager.match_project("dev", "/srv/app/main.py", "alice", 22), "alice", "explicit user/port beats wildcard")
eq(manager.match_project("dev", "/srv/app/pkg/x.py", "alice", 22), "alice", "bob's deeper root ignored for alice")
eq(manager.match_project("dev", "/srv/app/pkg/x.py", "bob", 2222), "bob_sub", "bob gets his deeper root")
eq(manager.match_project("dev", "/srv/app/x.py", "carol", 22), "legacy", "legacy config matches any user")
eq(manager.match_project("dev", "/srv/app/pkg/x.py", "bob", 22), "legacy", "port mismatch skips bob_sub")
eq(manager.match_project("dev", "/srv/application/x.py", "alice", 22), nil, "prefix must stop at a path boundary")
eq(manager.match_project("dev", "/srv/app", "alice", 22), "alice", "root itself matches")
eq(manager.match_project("prod", "/srv/x", "alice", 22), "other", "other host")
eq(manager.match_project("dev", "/srv/app/x.py"), "alice", "no user/port given: longest root, then explicit (alice) wins tie")
eq(manager.match_project(nil, "/x"), nil, "nil host")

-- failed save must not dirty the (cached) table store.load returned
local orig_save = store.save
store.save = function() return false end
local cfg = { host = "dev", root = "/tmp/new" }
eq(manager.add("new", cfg), false, "add reports failed save")
eq(projects.new, nil, "failed add leaves cache untouched")
eq(cfg.created_at, nil, "add does not mutate the caller's config")
eq(manager.upsert_lsp("alice", "pyright", { cmd = { "pyright" } }), false, "upsert reports failed save")
eq(projects.alice.lsp, nil, "failed upsert leaves cache untouched")
eq(manager.remove("legacy"), false, "remove reports failed save")
eq(projects.legacy ~= nil, true, "failed remove leaves cache untouched")
store.save = orig_save

-- util.format_json: pure Lua, valid JSON, backslashes preserved
local json = require("zero-nvim.util").format_json({ b = { "x\\y", 1 }, a = { cmd = { "a\"b" } }, e = {} })
local decoded = vim.json.decode(json)
if decoded.b[1] ~= "x\\y" or decoded.a.cmd[1] ~= "a\"b" or decoded.b[2] ~= 1 then
    error("format_json roundtrip mismatch: " .. json)
end
if not json:find('\n  "a": {', 1, true) then
    error("format_json should pretty-print with sorted keys: " .. json)
end

print("project manager test passed")
