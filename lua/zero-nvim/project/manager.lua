local M = {}
local store = require("zero-nvim.project.store")

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
    vim.notify(string.format("Project '%s' saved.", name), vim.log.levels.INFO)
end

---Remove a project by name
---@param name string
function M.remove(name)
    local projects = store.load()
    if projects[name] then
        projects[name] = nil
        store.save(projects)
        vim.notify(string.format("Project '%s' removed.", name), vim.log.levels.INFO)
    else
        vim.notify(string.format("Project '%s' not found.", name), vim.log.levels.WARN)
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
    local projects = store.load()
    return projects[name]
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
        vim.notify(string.format("ZeroNvim: project '%s' not found", project_name), vim.log.levels.ERROR)
        return false
    end
    proj.lsp = proj.lsp or {}
    proj.lsp[server_name] = vim.tbl_deep_extend("force", proj.lsp[server_name] or {}, server_cfg)
    store.save(projects)
    return true
end

---Find the best matching project for a given remote path
---Uses Longest Prefix Match strategy on the root path
---@param host string The remote host
---@param path string The absolute remote path
---@return string? project_name
---@return ZeroProjectConfig? config
function M.match_project(host, path)
    local projects = store.load()
    local best_match_name = nil
    local best_match_len = 0

    for name, config in pairs(projects) do
        -- 1. Host must match (exact match for now)
        -- TODO: Handle aliases resolution if needed in future
        if config.host == host then
            -- 2. Path must start with project root
            -- Ensure root has trailing slash for correct prefix matching if needed,
            -- but simple string.find is usually enough for "is subdirectory" check if we handle boundaries.

            -- Simple normalization: remove trailing slashes for comparison
            local clean_root = config.root:gsub("/+$", "")
            local clean_path = path:gsub("/+$", "")

            if clean_path == clean_root or clean_path:find(clean_root .. "/", 1, true) == 1 then
                local len = #clean_root
                if len > best_match_len then
                    best_match_len = len
                    best_match_name = name
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
