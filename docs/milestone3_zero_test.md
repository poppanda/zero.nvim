# Milestone 3 Testing Guide (Project Tree & VFS Expansion)

This document outlines the testing procedures for Milestone 3: Project Topology Perception and Directory Tree Cache. This milestone adds support for navigating remote directories and improves performance through daemon-side caching.

## 1. Prerequisites

Before running any tests, ensure the daemon is built with the latest changes (including SFTP and caching support).

### Build the Daemon
From the project root:

```bash
cd daemon
cargo build
cd ..
```

## 2. Automated Testing

We have provided a Lua test script `tests/test_zero_milestone3.lua` that mocks the RPC responses to verify the directory rendering and navigation logic.

### Running the Test
Execute the following command from the project root:

```bash
nvim -l tests/test_zero_milestone3.lua
```

### What it Tests
- **Stat-based Dispatch:** Verifies that the plugin calls `stat` to determine if a URI is a file or a directory.
- **Directory Rendering:** Checks if the directory listing is correctly formatted in the buffer (with icons and trailing slashes for folders).
- **Topology Scanning:** Verifies that `scan_project` is triggered asynchronously when a new directory is opened.
- **Navigation Logic:** Simulates the internal mapping between buffer lines and remote paths.

### Expected Output
```text
Running Milestone 3 Test (Directory Support)...
ZeroNvim: Scanning project topology...
ZeroNvim: Reading directory /home/user/project...
Pass: Stat, ReadDir and ScanProject called.
Pass: Buffer contains directory entries.
All Milestone 3 tests passed!
```

## 3. Manual Testing

Manual testing verifies the actual integration between Neovim, the Rust Daemon, and the remote SFTP server.

### Setup
Start Neovim in clean mode:

```bash
nvim --clean --cmd "set rtp+=."
```

### Test Scenarios

#### Scenario A: Opening a Remote Directory
1.  **Command:**
    ```vim
    :e remote://<user>@<host>:/path/to/some/dir/
    ```
2.  **Verify UI:**
    -   The buffer should show a list of files and directories.
    -   Directories should have a folder icon () and a trailing `/`.
    -   Files should have a file icon ().
3.  **Verify Logs (`:messages`):**
    -   `Stat-based dispatch...`
    -   `Scanning project topology...` (background scan)
    -   `Reading directory ... via Daemon...`

#### Scenario B: Navigation (Drill Down & Up)
1.  Move the cursor to a directory line and press `<CR>`.
    -   **Verify:** The buffer should update to show the contents of the sub-directory.
2.  Move the cursor to the ` ../` line and press `<CR>`.
    -   **Verify:** The buffer should return to the parent directory.
3.  Move the cursor to a file and press `<CR>`.
    -   **Verify:** The actual file content should be fetched and displayed.

#### Scenario C: Performance Caching
1.  Enter a directory, then go back up, then enter it again.
2.  **Observation:** The second time you enter the directory, it should be **instant**.
3.  **Verify Logs:** You should see `Reading directory ...` but the response comes from the daemon's internal `HashMap` instead of making a new SFTP request.

#### Scenario D: Manual Refresh
1.  While in a directory buffer, press `R`.
2.  **Verify:** The plugin should force a `scan_project` call and re-read the directory from the server, bypassing the cache. This is useful if files were added to the server externally.

## 4. Troubleshooting

-   **"Stat failed"**: Ensure the remote path exists and you have permissions to access it.
-   **Missing Icons**: The icons use Nerd Font characters. If they appear as squares, ensure your terminal is using a Nerd Font.
-   **Navigation Fails**: Check if the URI generated in `:messages` is correct. The parsing logic expects standard `user@host:port:/path` format.
