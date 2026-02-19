# zero-nvim

**zero-nvim** is a high-performance remote editing plugin for Neovim. It uses a local Rust daemon to multiplex SSH connections, providing a near-zero latency experience.

## Features

-   **Persistent Connections**: SSH connections are reused across different files and directory listings.
-   **In-Memory Caching**: Directory structures are cached in the daemon for instant navigation, with automatic cache invalidation on file changes.
-   **ZeroLink UI**: Native floating window UI to parse `~/.ssh/config` and quickly pick remote hosts.
-   **Full File Operations**: Support for reading, writing, creating, deleting, and renaming remote files via SFTP.
-   **Oil.nvim Integration**: Native adapter for `oil.nvim` with full modification support and transparent protocol redirection.

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
    ["oil-zero://"] = "zero",
  },
})

-- 2. (Optional) Enable transparent redirection in ZeroNvim
require("zero-nvim").setup({
  explorer = "oil", 
})
```

**Usage:**
- If `explorer = "oil"` is enabled: `:e remote://user@host/path/to/dir/` will automatically open in Oil.
- Manual access: `:edit oil-zero://user@host[:port]/path/to/dir/`


## Basic Usage

### ZeroLink (SSH Config Picker)

Easily connect to hosts defined in your `~/.ssh/config` using a floating UI:

```vim
:ZeroLink
```

- **No args**: Opens a Telescope-like picker for SSH hosts. Select a host and browse directories.
- **Specific target**: `:ZeroLink my_host /path/to/dir` opens it directly.

### Manual Remote Protocol

Open any remote file or directory using the `remote://` protocol:

```vim
:e remote://user@host[:port]:/path/to/file_or_dir
```

- **Built-in Directory View**:
    - `<CR>`: Open file or enter directory.
    - `..`: Go to parent directory.
    - `R`: Refresh cache.
- **Editing Files**: Simply use `:w` to save changes directly to the remote server.

## Troubleshooting

If you encounter `Handshake failed` or `Failed getting banner` (common behind proxies), use an SSH tunnel:

1.  **Start Tunnel:** `ssh -L 2222:localhost:22 user@host -N`
2.  **Connect Local:** `:e remote://user@127.0.0.1:2222:/path/to/file`
