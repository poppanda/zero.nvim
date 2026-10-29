-- =============================================================================
-- lsp_servers.lua — built-in preset table for `:ZeroLspAdd`
-- =============================================================================
-- Maps a server binary name (or common alias) to the minimum config the wizard
-- needs to write into a project: filetypes (required for auto-start matching),
-- cmd (defaults to {server, "--stdio"} when omitted), settings (rare).
--
-- Mason wrappers (e.g. ~/.local/share/nvim/mason/bin/basedpyright) and the
-- upstream binaries (basedpyright-langserver) are both executable; we list the
-- upstream name in cmd so the entry is explicit, but lookup() also matches the
-- mason wrapper name so picking from the bin list works seamlessly.

local M = {}

---@class ZeroLspPreset
---@field filetypes string[]
---@field cmd? string[]
---@field settings? table

---@type table<string, ZeroLspPreset>
M.presets = {
    ["basedpyright"]                 = { filetypes = { "python" }, cmd = { "basedpyright-langserver", "--stdio" } },
    ["pyright"]                      = { filetypes = { "python" }, cmd = { "pyright-langserver", "--stdio" } },
    ["ruff"]                         = { filetypes = { "python" }, cmd = { "ruff", "server" } },
    ["gopls"]                        = { filetypes = { "go", "gomod", "gowork" }, cmd = { "gopls" } },
    ["lua-language-server"]          = { filetypes = { "lua" }, cmd = { "lua-language-server" } },
    ["rust-analyzer"]                = { filetypes = { "rust" }, cmd = { "rust-analyzer" } },
    ["clangd"]                       = { filetypes = { "c", "cpp", "objc", "objcpp" }, cmd = { "clangd" } },
    ["typescript-language-server"]   = {
        filetypes = { "typescript", "javascript", "typescriptreact", "javascriptreact" },
        cmd = { "typescript-language-server", "--stdio" },
    },
    ["biome"]                        = {
        filetypes = { "javascript", "typescript", "json", "jsonc" },
        cmd = { "biome", "lsp-proxy" },
    },
    ["bash-language-server"]         = { filetypes = { "sh", "bash" }, cmd = { "bash-language-server", "start" } },
    ["yaml-language-server"]         = { filetypes = { "yaml" }, cmd = { "yaml-language-server", "--stdio" } },
    ["vscode-json-language-server"]  = { filetypes = { "json", "jsonc" }, cmd = { "vscode-json-language-server", "--stdio" } },
}

-- Common short aliases / mason wrapper names that should resolve to a preset.
local aliases = {
    ["lua_ls"]                       = "lua-language-server",
    ["lualangserver"]                = "lua-language-server",
    ["ts_ls"]                        = "typescript-language-server",
    ["tsserver"]                     = "typescript-language-server",
    ["yamlls"]                       = "yaml-language-server",
    ["jsonls"]                       = "vscode-json-language-server",
    ["bashls"]                       = "bash-language-server",
    ["bash-ls"]                      = "bash-language-server",
    ["rust_analyzer"]                = "rust-analyzer",
}

---Look up a preset for a given name.
---Tries exact match, then alias table.
---@param name string
---@return ZeroLspPreset?
---@return string? canonical_name
function M.lookup(name)
    if not name or name == "" then return nil end
    if M.presets[name] then return M.presets[name], name end
    local canonical = aliases[name]
    if canonical and M.presets[canonical] then
        return M.presets[canonical], canonical
    end
    return nil
end

return M
