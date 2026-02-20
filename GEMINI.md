# zero-nvim

**zero-nvim** (formerly `neovim-remote`) is a Neovim plugin designed to provide a "zero latency" remote editing experience. It achieves this by decoupling the UI from network I/O, using a local high-performance daemon to handle data synchronization and LSP proxying, while keeping the editor interface responsive.

## Project Status

**Current Milestone:** Milestone 4 (Global Search & Telescope Integration)

-   [x] Milestone 1: Basic `remote://` protocol support (Read-Only) via `ssh` and `vim.system`.
-   [x] Milestone 2: High-performance Daemon (Rust) for connection multiplexing via Msgpack-RPC.
-   [x] Milestone 3: Project Topology Perception and Directory Tree Cache.
-   [x] Feature: ZeroLink UI & `~/.ssh/config` Support (Parse local SSH configs for host selection).
-   [x] Feature: Full Remote File Operations (Write, Mkdir, Delete, Rename) via SFTP & Oil.nvim Adapter.
-   [x] Milestone 4: Global Search & Telescope Integration (Tree-Like Grouping, Local Fallback, UI Toggles).
-   [x] Feature: ZeroSearchMini (Buffer-local search & replace UI with floating windows).
-   [ ] Milestone 5: Project level LSP Proxy.
-   [ ] Milestone 6: 实现 0 延迟编辑与增量同步 (Incremental Sync).
-   [ ] Milestone 7: LSP Path Translation & Diagnostics.

## Directory Overview

-   **`lua/zero-nvim/`**: Contains the core Lua implementation of the plugin.
    -   `init.lua`: Main entry point. Handles `BufReadCmd`, UI rendering for directories, and RPC communication.
-   **`daemon/`**: Rust source code for the backend daemon.
    -   `src/main.rs`: Implements RPC methods (`connect`, `fetch_file`, `read_dir`, `stat`, `scan_project`) and in-memory caching.
-   **`plugin/`**: Auto-load scripts.
-   **`tests/`**: Test scripts.
    -   `test_zero_milestone3.lua`: Verifies directory handling and RPC flow.

## Development & Usage

### Building the Daemon
```bash
cd daemon
cargo build
```

### Usage
Open a remote directory:
```vim
:e remote://user@host[:port]:/path/to/dir/
```
- `<CR>`: Open file or enter directory.
- `R`: Refresh current directory cache.
- `..`: Go to parent directory.

## Architecture Notes

-   **ZeroLink & SSH Config**: Before connecting, the plugin delegates `~/.ssh/config` parsing to the Rust daemon. The UI presents a fast, floating telescope-like interface to pick predefined hosts.
-   **Stat-based Dispatch**: When a `remote://` URI is accessed, the plugin performs a fast `stat` call via the daemon to determine if it should render a directory or fetch file content.
-   **Daemon Cache & Invalidation**: The Rust daemon maintains a `HashMap<PathBuf, Vec<DirEntry>>` to cache directory structures, eliminating SSH round-trips. When files are created, renamed, or deleted through the plugin, the cache is automatically and targetedly invalidated to ensure the UI stays up-to-date.
-   **Background Topology Scan**: Opening a directory triggers an asynchronous `scan_project` call that executes a remote BFS scan via SFTP to pre-populate the directory cache up to 3 levels deep.
-   **Robust SFTP Core**: Switched all file system operations to use direct `libssh2` SFTP bindings instead of shell pipelines, offering secure, reliable reads/writes (even for large or binary files) with minimal latency.
-   **ZeroSearch Architecture**: The `:ZeroSearch` command intelligently detects the buffer context. For local buffers, it spawns a high-performance local `rg` job. For remote contexts (`remote://`), it delegates the ripgrep execution to the Rust daemon over SSH and streams Msgpack-RPC notifications back to Neovim. The UI parses these chunks to render a dynamic, **Tree-Like Foldable GUI** with rich `extmarks` highlighting, minimizing visual noise. It also supports instantaneous Regex and Case-Sensitive toggles via normal/insert mode shortcuts (`<C-w>` / `<C-c>`).
-   **ZeroSearchMini**: The `:ZeroSearchMini` command provides a buffer-local search and replace mechanism utilizing stacked floating windows positioned at the bottom-right corner. It uses real-time `vim.regex` matching, persistent query memory, and Vim-native `j/k/<CR>` normal mode navigation. Virtual text dynamically replaces empty prompts completely saving UI space. It supports instant toggle between search and replace lines (`<C-r>`), mapping directly to the underlying physical lines without visual wrap artifacts.
