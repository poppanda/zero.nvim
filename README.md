# zero-nvim

**zero-nvim** is a high-performance remote editing plugin for Neovim. It uses a local Rust daemon to multiplex SSH connections, providing a near-zero latency experience.

## Features

- **Persistent Connections**: SSH connections are reused across different files and directory listings.
- **In-Memory Caching**: Directory structures are cached in the daemon for instant navigation, with automatic cache invalidation on file changes.
- **ZeroLink UI**: Native floating window UI to parse `~/.ssh/config` and quickly pick remote hosts.
- **Full File Operations**: Support for reading, writing, creating, deleting, and renaming remote files via SFTP.
- **Oil.nvim Integration**: Native adapter for `oil.nvim` with full modification support and transparent protocol redirection.

## Installation

### 1. Build the Daemon

The plugin requires a Rust backend. Build it from the `daemon/` directory:

```bash
cd daemon
cargo build --release
```

### 2. Configure Neovim

Using `lazy.nvim`:

```lua
{
  "your-username/zero-nvim",
  build = "cd daemon && cargo build --release",
  opts = {
    explorer = "oil", -- Optional: automatically use oil.nvim for remote directories
    daemon = {
      build_type = "release",
    }
  }
}
```

## Integrations

### Oil.nvim

To use `oil.nvim` with `zero-nvim` for high-performance remote file management:

```lua
-- 1. Register the ZeroNvim adapter with Oil
require("oil").setup({
  adapters = {
    ["zero://"] = "zero",
  },
})

-- 2. (Optional) Enable transparent redirection in ZeroNvim
require("zero-nvim").setup({
  explorer = "oil",
})
```

**Usage:**

- If `explorer = "oil"` is enabled: `:e zero://user@host/path/to/dir/` will automatically open in Oil.
- Manual access: `:edit zero://user@host[:port]/path/to/dir/`

## Basic Usage

### ZeroLink (SSH Config Picker)

Easily connect to hosts defined in your `~/.ssh/config` using a floating UI:

```vim
:ZeroLink
```

- **No args**: Opens a Telescope-like picker for SSH hosts. Select a host and browse directories.
- **Specific target**: `:ZeroLink my_host /path/to/dir` opens it directly.

### Project Management (ZeroProject)

Manage your remote projects with a dedicated dashboard, supporting saved configurations and context-aware LSP settings.

```vim
:ZeroProject [subcommand]
```

- **`:ZeroProject` (No args)**: Opens the project picker dashboard.
  - `<CR>`: Open selected project.
  - `<C-a>`: Add current remote buffer as a new project.
  - `<C-e>`: Edit project configuration (JSON).
  - `<C-d>`: Delete project.
  - `<C-h>`: Run connectivity and environment Health Check.
- **`:ZeroProject add`**: Directly add the current remote buffer as a project.
- **`:ZeroProject check <name>`**: Run health check for a specific project.

**Project Configuration Example:**
When editing a project (`<C-e>`), you can override LSP settings for that specific remote environment:

```json
{
  "host": "dev-server",
  "root": "/var/www/backend",
  "lsp": {
    "basedpyright": {
      "filetypes": ["python"],
      "cmd": ["/var/www/backend/.venv/bin/basedpyright-langserver", "--stdio"],
      "settings": {
        "python": { "analysis": { "typeCheckingMode": "off" } }
      }
    }
  }
}
```

### Remote LSP (ZeroLspStart)

Start a language server on the remote host via a local TCP proxy:

```vim
:ZeroLspStart basedpyright --stdio
```

Tab-completion suggests binaries available in `~/.local/share/nvim/mason/bin/` on the remote server.

#### Auto-start by filetype

Add `filetypes` (and optionally `cmd`) to each server entry in `lsp.servers`. The LSP will start automatically whenever a matching remote file is opened — no manual `:ZeroLspStart` needed:

```lua
require("zero-nvim").setup({
  lsp = {
    servers = {
      basedpyright = {
        filetypes = { "python" },
        cmd = { "basedpyright", "--stdio" },
        settings = {
          python = { analysis = { typeCheckingMode = "off" } },
        },
      },
      ["typescript-language-server"] = {
        filetypes = { "typescript", "javascript" },
        cmd = { "typescript-language-server", "--stdio" },
      },
    },
  },
})
```

- **`filetypes`**: Triggers auto-start when the buffer filetype matches.
- **`cmd`**: Override the default `{ server_name, "--stdio" }` command.
- **`settings`**: Passed as LSP initialization settings.

If a project is registered via `:ZeroProject`, the LSP uses the **project root** as `rootUri` so cross-directory definitions and references work correctly. Per-project overrides (e.g. a virtualenv-specific binary) are configured in the project JSON (see `:ZeroProject` below).

After an LSP definition jump, the target file is automatically attached to the running LSP client — no manual re-start required.

### Search Project (ZeroSearch)

Search your project instantly via ripgrep with an enhanced, native Tree-Like UI format.

```vim
:ZeroSearch
```

- **Auto-Context Detection**: `:ZeroSearch` intelligently detects if you are in a local buffer or a remote buffer (`zero://`). If remote, it securely offloads the search to the Rust daemon. If local, it seamlessly falls back to a fast local `rg` process.
- **Tree-Like Grouping**: Results are grouped by file and visually indented with colored icons, line numbers, and search match extmarks.
- **Keyboard Navigation**:
  - `j` / `k`: Navigate through files and matched lines.
  - `h` / `l`: Expand or collapse file nodes to instantly hide/reveal matches.
  - `<C-c>`: Toggle Case-Sensitive exact matching.
  - `<C-w>`: Toggle Whole Word (Regex) exact matching.
  - `<CR>`: Jump precisely to the matched file and line.
- **Live Preview**: The right-hand window actively previews the file logic beneath your cursor.

### Local Buffer Search (ZeroSearchMini)

Search and replace within the current buffer using a minimal, stacked floating window UI.

```vim
:ZeroSearchMini
```

- **Compact UI**: Positioned at the bottom-right corner, conserving editing space while providing full search functionality.
- **Fast Navigation**: Employs real-time `vim.regex` matching. Use `j` and `k` seamlessly jump between input prompts and matches.
- **Persistent Memory**: Remembers your last query and cursor position between invocations.
- **Integrated Replace**:
  - `<C-r>`: Expand/collapse the replace line.
  - `r` or `<CR>` on the replace line applies the substitution and immediately advances to the next match.
- **Toggles**: Quickly switch Case-Sensitive (`<C-c>`) and Whole Word (`<C-w>`) matching directly from the input window.

### Manual Remote Protocol

Open any remote file or directory using the `zero://` protocol:

```vim
:e zero://user@host[:port]/path/to/file_or_dir
```

- **Built-in Directory View**:
  - `<CR>`: Open file or enter directory.
  - `..`: Go to parent directory.
  - `R`: Refresh cache.
- **Editing Files**: Simply use `:w` to save changes directly to the remote server.

## Troubleshooting

If you encounter `Handshake failed` or `Failed getting banner` (common behind proxies), use an SSH tunnel:

1.  **Start Tunnel:** `ssh -L 2222:localhost:22 user@host -N`
2.  **Connect Local:** `:e zero://user@127.0.0.1:2222/path/to/file`
