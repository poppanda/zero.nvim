# Milestone 2 Testing Guide (ZeroNvim Daemon)

This document outlines the testing procedures for Milestone 2: High-Performance Daemon Integration. This milestone introduces a Rust-based background process to handle persistent SSH connections and Msgpack-RPC communication.

## 1. Prerequisites

Before running any tests, you **MUST** build the daemon binary. The Lua plugin expects the binary to exist at `daemon/target/debug/zero-nvim-daemon`.

### Build the Daemon
From the project root:

```bash
cd daemon
cargo build
cd ..
```

Verify the binary exists:
```bash
ls -l daemon/target/debug/zero-nvim-daemon
```

## 2. Automated Testing

We have provided a Lua test script that mocks the `vim.fn.jobstart` and `vim.fn.rpcrequest` functions. This allows us to verify the Lua-side logic (state management, authentication flow, and buffer updates) without needing a running daemon or a real remote server.

### Running the Test
Execute the following command from the project root:

```bash
nvim -l tests/test_zero_milestone2.lua
```

### What it Tests
- **Daemon Lifecycle:** Verifies that `vim.fn.jobstart` is called to launch the daemon.
- **Connection Flow:**
  - Simulates an initial `connect` request failing (e.g., due to missing password).
  - Verifies that `vim.ui.input` is triggered to prompt for a password.
  - Verifies that `connect` is retried with the provided password.
- **File Fetching:**
  - Verifies that `fetch_file` is called after a successful connection.
  - Checks if the returned content is correctly loaded into the buffer.

### Expected Output
```text
Running Milestone 2 Test (Daemon Integration)...

--- Test Case 1: Connect with retry/password ---
Mock: jobstart called
Mock: rpcrequest called: connect
Mock: vim.ui.input prompted: SSH Password for user@localhost: 
Pass: Password prompt appeared.
Mock: rpcrequest called: connect
Mock: rpcrequest called: fetch_file
Pass: RPC calls flow correct (Connect(fail) -> Connect(success) -> Fetch).

Test Finished.
```

## 3. Manual Testing

Manual testing ensures the actual Rust daemon works correctly with your local system's SSH configuration.

### Setup
Ensure the daemon is built (see Prerequisites). Start Neovim in clean mode, appending the current directory to the runtime path:

```bash
nvim --clean --cmd "set rtp+=."
```

### Test Scenarios

#### Scenario A: Basic File Open (SSH Agent / Key Auth)
If you have SSH key access to a remote host (e.g., `localhost` or a server):

1.  **Open File:**
    ```vim
    :e remote://<user>@<host>:/path/to/file
    ```
    *Example:* `:e remote://myuser@192.168.1.50:/home/myuser/.bashrc`

2.  **Verify Daemon Startup:**
    -   In Neovim, run `:messages`. You should see:
        -   `Starting ZeroNvim Daemon...`
        -   `Connecting to <user>@<host>...`
        -   `Connected to <user>@<host>`
        -   `Fetching /path/to/file via Daemon...`
    -   Outside Neovim, check process list: `pgrep -fl zero-nvim-daemon`.

3.  **Verify Content:** The buffer should display the file content.

#### Scenario B: Password Authentication
If you need to test password fallback (e.g., connecting to a host without your public key):

1.  **Open File:**
    ```vim
    :e remote://<user>@<host>:/path/to/file
    ```
2.  **Input Password:**
    -   Neovim should prompt: `SSH Password for <user>@<host>: `
    -   Enter the correct password.
3.  **Verify Success:**
    -   Messages should show `Connected...` after the prompt.
    -   File content loads.

#### Scenario C: Connection Multiplexing (Performance)
1.  Open one file from a remote host (as in Scenario A).
2.  Open a **second** file from the **same** host.
3.  **Observation:**
    -   The second file should open instantly.
    -   Check `:messages`. You should **NOT** see `Starting ZeroNvim Daemon...` or `Connecting to...` again (unless the previous connection failed).
    -   You should only see `Fetching ... via Daemon...`.

## 4. Troubleshooting

-   **"ZeroNvim Daemon binary not found"**:
    -   Run `cargo build` in the `daemon/` directory.
-   **"RPC Call failed" / "Daemon exited with code..."**:
    -   Check if the daemon crashed.
    -   Try running the daemon manually to see panic messages:
        ```bash
        ./daemon/target/debug/zero-nvim-daemon
        ```
        (Note: It expects Msgpack input on stdin, so it might just hang or exit, but it verifies the binary runs).
-   **Authentication Failures**:
    -   Ensure your SSH keys are added to your agent (`ssh-add -l`).
    -   Verify you can `ssh user@host` from a normal terminal.
