# zero-nvim

**zero-nvim** (formerly `neovim-remote`) is a Neovim plugin designed to provide a "zero latency" remote editing experience. It achieves this by decoupling the UI from network I/O, using a local high-performance daemon to handle data synchronization and LSP proxying, while keeping the editor interface responsive.

## Project Status

**Current Milestone:** Milestone 1 (Pure Lua Read-Only VFS) - **COMPLETED**

-   [x] Milestone 1: Basic `remote://` protocol support (Read-Only) via `ssh` and `vim.system`.
-   [ ] Milestone 2: High-performance Daemon (Rust/C++) for connection multiplexing.
-   [ ] Milestone 3: Zero-latency editing and incremental synchronization.
-   [ ] Milestone 4: LSP Transparent Proxy and Path Translation.

## Directory Overview

-   **`lua/zero-nvim/`**: Contains the core Lua implementation of the plugin.
    -   `init.lua`: The main entry point. Handles `BufReadCmd` events for `remote://` URIs, executes SSH commands, and manages buffer content.
-   **`plugin/`**: Auto-load scripts.
    -   `zero-nvim.lua`: Automatically initializes the plugin when Neovim starts.
-   **`tests/`**: Test scripts.
    -   `test_zero_milestone1.lua`: A standalone Lua script to verify Milestone 1 functionality by mocking `vim.system`.
-   **`docs/`**: Documentation and design specs.
    -   `milestones.md`: Detailed roadmap and task breakdown.
    -   `functions.md`: Architecture design notes.
    -   `milestone1_zero_test.md`: Testing guide for the current milestone.

## Development & Usage

### Prerequisites

-   **Neovim 0.10+** (Required for `vim.system`).
-   **SSH Client**: Must be configured for non-interactive authentication (SSH keys/Agent) to the target host.

### Running in Development Mode

To avoid conflicts with installed plugins (especially if you have `remote-nvim` installed), **ALWAYS** use the `--clean` flag and manually append the runtime path:

```bash
nvim --clean --cmd "set rtp+=."
```

Once inside Neovim:

1.  Open a remote file: `:e remote://user@host:/path/to/file`
2.  Check logs: `:messages` (Debug info is prefixed with `ZeroNvim:`)

### Running Tests

Run the automated test suite from the project root:

```bash
nvim -l tests/test_zero_milestone1.lua
```

## Architecture Notes (Milestone 1)

-   **Protocol:** `remote://user@host:/path/to/file`
-   **Mechanism:** Intercepts `BufReadCmd`. Uses `ssh -o BatchMode=yes` to fetch file content via `cat`.
-   **Buffer State:** Buffers are currently set to `buftype=acwrite`, `nomodified`, and `readonly`.
-   **Error Handling:** Catches SSH errors (connectivity, permissions) and reports them via `vim.notify` and `:messages`.

## Key Commands

-   **Fetch File:** `ssh -o BatchMode=yes -o ConnectTimeout=5 user@host cat /path/to/file`
