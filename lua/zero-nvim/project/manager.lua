local M = {}
local store = require("zero-nvim.project.store")
local log = require("zero-nvim.log")

---@class ZeroProject
---@field name string
---@field config ZeroProjectConfig

---Add or update a project
---@param name string
---@param config ZeroProjectConfig
function M.add(name, config)
    local projects = store.load()
    projects[name] = config
    -- Update timestamp
    projects[name].created_at = os.time()
    store.save(projects)
    log.info(string.format("project '%s' saved", name))
end

---Remove a project by name
---@param name string
function M.remove(name)
    local projects = store.load()
    if projects[name] then
        projects[name] = nil
        store.save(projects)
        log.info(string.format("project '%s' removed", name))
    else
        log.warn(string.format("project '%s' not found", name))
    end
end

---List all projects
---@return table<string, ZeroProjectConfig>
function M.list()
    return store.load()
end

---Get a specific project configuration
---@param name string
---@return ZeroProjectConfig?
function M.get(name)
    return store.load()[name]
end

---Insert or merge a single LSP server entry into a project.
---Deep-merges the new config onto any existing entry so partial updates
---(e.g. only changing settings) don't drop unrelated keys like cmd/filetypes.
---@param project_name string
---@param server_name string
---@param server_cfg table
---@return boolean ok
function M.upsert_lsp(project_name, server_name, server_cfg)
    local projects = store.load()
    local proj = projects[project_name]
    if not proj then
        log.error(string.format("project '%s' not found", project_name))
        return false
    end
    proj.lsp = proj.lsp or {}
    proj.lsp[server_name] = vim.tbl_deep_extend("force", proj.lsp[server_name] or {}, server_cfg)
    store.save(projects)
    return true
end

--- 去掉末尾的 "/"（"/" 本身 -> ""），用于 root 比较。
---@param path? string
---@return string
function M.norm_root(path)
    return ((path or ""):gsub("/+$", ""))
end

---Does a stored project config target the given connection?
---Missing user/port in the stored config act as wildcards (configs written
---before user/port were recorded keep matching).
---@param config ZeroProjectConfig
---@param host string
---@param user? string
---@param port? integer
---@return boolean matched
---@return integer specificity 0-2: how many of user/port matched explicitly
local function target_matches(config, host, user, port)
    if config.host ~= host then return false, 0 end
    local score = 0
    if config.user and config.user ~= "" and user then
        if config.user ~= user then return false, 0 end
        score = score + 1
    end
    if config.port and port then
        if tonumber(config.port) ~= tonumber(port) then return false, 0 end
        score = score + 1
    end
    return true, score
end

---Find the best matching project for a given remote path
---Uses Longest Prefix Match strategy on the root path, scoped to the
---connection (user@host:port).
---@param host string The remote host
---@param path string The absolute remote path
---@param user? string The remote user (nil = don't filter on user)
---@param port? integer The remote port (nil = don't filter on port)
---@return string? project_name
---@return ZeroProjectConfig? config
function M.match_project(host, path, user, port)
    if type(host) ~= "string" or type(path) ~= "string" then return nil, nil end
    local projects = store.load()
    local best_match_name = nil
    local best_match_len = -1
    local best_score = -1

    local clean_path = M.norm_root(path)

    for name, config in pairs(projects) do
        -- 坏配置（root 缺失 / 类型不对）直接跳过，避免 gsub 崩溃
        if type(config) == "table" and type(config.root) == "string" then
            local ok, score = target_matches(config, host, user, port)
            if ok then
                local clean_root = M.norm_root(config.root)
                local covers = clean_root == ""                      -- root "/" covers everything
                    or clean_path == clean_root
                    or clean_path:find(clean_root .. "/", 1, true) == 1
                if covers then
                    local len = #clean_root
                    local better = len > best_match_len
                        or (len == best_match_len and score > best_score)
                        or (len == best_match_len and score == best_score and name < best_match_name)
                    if better then
                        best_match_len = len
                        best_score = score
                        best_match_name = name
                    end
                end
            end
        end
    end

    if best_match_name then
        return best_match_name, projects[best_match_name]
    end

    return nil, nil
end

return M
