# zero-nvim

**zero-nvim** (formerly `neovim-remote`) is a Neovim plugin designed to provide a "zero latency" remote editing experience. It achieves this by decoupling the UI from network I/O, using a local high-performance daemon to handle data synchronization and LSP proxying, while keeping the editor interface responsive.

## Project Status

**Current Milestone:** Milestone 2 (High-Performance Daemon) - **COMPLETED**

-   [x] Milestone 1: Basic `remote://` protocol support (Read-Only) via `ssh` and `vim.system`.
-   [x] Milestone 2: High-performance Daemon (Rust) for connection multiplexing via Msgpack-RPC.
-   [ ] Milestone 3: Zero-latency editing and incremental synchronization.
-   [ ] Milestone 4: LSP Transparent Proxy and Path Translation.

## Directory Overview

-   **`lua/zero-nvim/`**: Contains the core Lua implementation of the plugin.
    -   `init.lua`: The main entry point. Handles `BufReadCmd` events, manages the Daemon process (`vim.fn.jobstart`), and communicates via `vim.rpcrequest`.
-   **`daemon/`**: Rust source code for the backend daemon.
    -   `src/main.rs`: Implements the Msgpack-RPC server and persistent SSH connection logic using `ssh2` and `tokio`.
-   **`plugin/`**: Auto-load scripts.
    -   `zero-nvim.lua`: Automatically initializes the plugin when Neovim starts.
-   **`tests/`**: Test scripts.
    -   `test_zero_milestone2.lua`: Verifies the Lua-Daemon interaction logic by mocking RPC calls.
-   **`docs/`**: Documentation and design specs.

## Development & Usage

### Prerequisites

-   **Neovim 0.10+** (Required for `vim.system` and modern Lua API).
-   **Rust Toolchain**: Required to build the daemon (`cargo`).
-   **SSH Client**: Configured for key-based or password-based authentication.

### Building the Daemon

Before using the plugin, you must build the daemon:

```bash
cd daemon
cargo build
```

### Running in Development Mode

To avoid conflicts with installed plugins, **ALWAYS** use the `--clean` flag and manually append the runtime path:

```bash
nvim --clean --cmd "set rtp+=."
```

Once inside Neovim:

1.  Open a remote file: `:e remote://user@host:/path/to/file`
2.  The plugin will automatically start the daemon and establish an SSH connection.
3.  If authentication fails, you will be prompted for a password.

### Running Tests

Run the automated test suite from the project root:

```bash
nvim -l tests/test_zero_milestone2.lua
```

## Architecture Notes (Milestone 2)

-   **Protocol:** `remote://user@host:/path/to/file`
-   **Backend:** Rust Daemon (`zero-nvim-daemon`) running as a child process of Neovim.
-   **Communication:** Standard Msgpack-RPC over Stdio.
    -   Requests: `connect(user, host, password)`, `fetch_file(user, host, path)`.
-   **Connection Multiplexing:**
    -   The daemon maintains persistent SSH sessions (`ssh2::Session`) in memory.
    -   Subsequent file requests reuse the existing authenticated session, eliminating handshake latency.
-   **Authentication:**
    -   Supports SSH Agent and Password authentication.
    -   If the daemon reports auth failure, the Lua frontend prompts the user and retries with the password.

## Key Commands (Internal)

-   **Daemon Start:** `vim.fn.jobstart({'path/to/daemon'}, { rpc = true })`
-   **Connect:** `vim.rpcrequest(chan, 'connect', user, host, password)`
-   **Fetch:** `vim.rpcrequest(chan, 'fetch_file', user, host, path)`
