# Milestone 5 Testing Guide (LSP Proxy Foundation)

This document outlines the testing procedures for Milestone 5: Project level LSP Proxy. This milestone adds support for proxying Language Server Protocol (LSP) connections from a local Neovim client to a remote language server via the `zero-nvim` Rust daemon.

## 1. Prerequisites

Before running any tests, ensure the daemon is built with the latest changes (including the TCP proxy and URI path translation logic).

### Build the Daemon
From the project root:

```bash
cd daemon
cargo build
cd ..
```

### Remote Server Preparation
Ensure your remote server has the target language server installed (e.g., `pyright`, `clangd`, `rust-analyzer`).

## 2. Manual Testing

Manual testing verifies the actual integration between Neovim's built-in LSP client, the Rust Daemon's TCP Proxy, and the remote language server process over SSH.

### Setup
Start Neovim, ensuring the plugin is loaded.

### Test Scenarios

#### Scenario A: Connecting strictly via the Proxy
1.  **Open a remote file:**
    ```vim
    :e remote://<user>@<host>:/path/to/project/main.py
    ```
2.  **Start the LSP proxy:**
    Run the new user command and provide the language server command as an argument. Make sure to specify stdio mode if the language server requires it.
    ```vim
    :ZeroLspStart pyright-langserver --stdio
    ```
3.  **Verify UI & Connection:**
    -   You should see a notification: `ZeroNvim: LSP Proxy started on port <random_port> for pyright-langserver`
    -   You should see a notification: `ZeroNvim: Attached LSP pyright-langserver to buffer`
    -   Run `:LspInfo` and verify that a client named `zero-pyright-langserver` is attached to the current buffer and its `cmd` indicates a TCP connection (`127.0.0.1:<random_port>`).

#### Scenario B: Feature Verification - Diagnostics
1.  While the LSP is attached to your remote file, deliberately introduce a syntax error or a type error in the code (e.g., misspelled variable name).
2.  **Verify:**
    -   Neovim should display inline diagnostic warnings/errors (squiggly lines, virtual text).
    -   This confirms that the daemon is correctly proxying the `textDocument/publishDiagnostics` notifications from the remote language server back to Neovim.

#### Scenario C: Feature Verification - Path Translation (Go-to-Definition)
1.  Move the cursor over a standard library function or a function defined elsewhere in the project.
2.  Press `<C-]>` (or your configured Go-to-Definition mapping).
3.  **Verify:**
    -   Neovim should successfully jump to the definition.
    -   Most importantly, verify the buffer name of the newly opened file using `:f` or `:echo expand('%')`. It **must** have the `remote://<user>@<host>:/path/...` prefix, NOT a local `file:///path/...` prefix.
    -   This guarantees that the daemon successfully intercepted the LSP message and translated the remote server's `file:///` URIs back into `remote://` URIs before Neovim processed them.

## 3. Troubleshooting

-   **"Daemon not connected"**: Ensure you have successfully opened a `remote://` file first before calling `:ZeroLspStart`.
-   **"Failed to start LSP proxy"**: Check if the language server command exists on the remote machine's `$PATH`.
-   **LSP Attaches but no features work**: Ensure the LSP is receiving the correct root directory. By default, `ZeroLspStart` sets the root to the directory of the current buffer. Some language servers might fail if a proper project root (like a `.git` folder) format isn't established.
