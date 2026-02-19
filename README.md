# zero-nvim

**zero-nvim** is a high-performance remote editing plugin for Neovim. It uses a local Rust daemon to multiplex SSH connections, providing a near-zero latency experience.

## Features

-   **Persistent Connections**: SSH connections are reused across different files and directory listings.
-   **In-Memory Caching**: Directory structures are cached in the daemon for instant navigation.
-   **Custom Port Support**: Connect to non-standard SSH ports or through local tunnels.
-   **Oil.nvim Integration**: Native adapter for the modern `oil.nvim` file explorer with transparent protocol redirection.

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

Open any remote file or directory using the `remote://` protocol:

```vim
:e remote://user@host[:port]:/path/to/file_or_dir
```

- **In Built-in Directory View:**
    - `<CR>`: Open file or enter directory (reuses buffer for directories).
    - `..`: Go to parent directory.
    - `R`: Refresh cache.

## Troubleshooting

If you encounter `Handshake failed` or `Failed getting banner` (common behind proxies), use an SSH tunnel:

1.  **Start Tunnel:** `ssh -L 2222:localhost:22 user@host -N`
2.  **Connect Local:** `:e remote://user@127.0.0.1:2222:/path/to/file`
