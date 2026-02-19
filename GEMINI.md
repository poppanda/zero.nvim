# zero-nvim

**zero-nvim** (formerly `neovim-remote`) is a Neovim plugin designed to provide a "zero latency" remote editing experience. It achieves this by decoupling the UI from network I/O, using a local high-performance daemon to handle data synchronization and LSP proxying, while keeping the editor interface responsive.

## Project Status

**Current Milestone:** Milestone 3 (Project Tree & VFS Expansion) - **COMPLETED**

-   [x] Milestone 1: Basic `remote://` protocol support (Read-Only) via `ssh` and `vim.system`.
-   [x] Milestone 2: High-performance Daemon (Rust) for connection multiplexing via Msgpack-RPC.
-   [x] Milestone 3: Project Topology Perception and Directory Tree Cache.
-   [ ] Milestone 4: Global Search & Telescope Integration.
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

## Architecture Notes (Milestone 3)

-   **Stat-based Dispatch**: When a `remote://` URI is accessed, the plugin first performs a `stat` call to determine if it should render a directory listing or fetch file content.
-   **Daemon Cache**: The Rust daemon maintains a `HashMap<PathBuf, Vec<DirEntry>>` to cache directory structures. This eliminates SSH round-trips for previously visited directories.
-   **Background Topology Scan**: Opening a directory triggers an asynchronous `scan_project` call that executes a remote `find` command to pre-populate the cache.
-   **SFTP Integration**: Switched from shell `ls` to SFTP for robust directory reading and metadata extraction.
