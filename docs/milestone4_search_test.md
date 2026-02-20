# Milestone 4 Testing Guide (Global Search & Telescope Integration)

This document outlines the testing procedures for Milestone 4. It verifies the new asynchronous `:ZeroSearch` functionality, the custom Telescope Integration, the floating context UI, and remote buffer context detection.

## 1. Prerequisites

Ensure the daemon is built with the latest changes (`main.rs` threads & `search.rs` live grep support).

### Build the Daemon
From the project root:

```bash
cd daemon
cargo build --release
cd ..
```

## 2. Manual Testing Scenarios

Manual testing verifies the end-to-end integration between Neovim's UI, Telescope, and the Rust Daemon executing `ripgrep` remotely.

### Setup
Start Neovim with the plugin loaded:

```bash
nvim --clean --cmd "set rtp+=."
```

### Scenario A: Explicit Host & Path Selection (No Context)
*Tests the fallback interactive picking mechanism.*
1.  **Command:** Run `:ZeroSearch` from an empty, local buffer or the Start screen.
2.  **Verify UI:**
    -   A floating window (ZeroLink picker) should appear listing hosts from your `~/.ssh/config`.
3.  **Action:** Select a host `<CR>`, then browse to a project directory and press `<C-s>` to confirm.
4.  **Verify Telescope Search:**
    -   Telescope's `Live Grep (<host>)` prompt should appear.
    -   **Top-Right Corner UI:** A short, 1-line borderless floating window should appear saying `🔍 Search <host>:<path> for ''`.
    -   Type a string that you know exists in the remote codebase (e.g., `function`).
    -   The results list should populate asynchronously without freezing Neovim.
    -   The Top-Right UI should update to show `... for 'function'`.
5.  **Action:** Press `<Esc>`.
6.  **Verify Cleanup:** The Telescope window and the Top-Right floating UI must both close immediately.

### Scenario B: Auto-Context Detection
*Tests if ZeroSearch intelligently detects the remote environment you are already exploring.*
1.  **Action:** Open a remote directory via `:e remote://user@host:/path/to/project/`.
2.  **Command:** While inside this remote buffer, type `:ZeroSearch`.
3.  **Verify Context Extraction:**
    -   The SSH Host Picker **should NOT appear**.
    -   You should instantly jump into the Telescope `Live Grep` prompt.
    -   The Top-Right UI should correctly display the server and path of the buffer you were just in.
4.  **Repeat with File Buffer:** Open a specific remote file `<CR>`. Inside that file, run `:ZeroSearch`. It should also instantly jump to search, scoped to the parent directory of that file.

### Scenario C: Live Previewer Functionality
*Tests whether Telescope can preview remote files instantly.*
1.  **Action:** Launch `:ZeroSearch` and look for a valid keyword.
2.  **Verify UI:**
    -   As you highlight a result with `j/k` or `<Down>/<Up>`, the right-side Telescope preview window should display the remote file's content.
    -   The matching line should be visible and syntax-highlighted.
3.  **Note:** Since the previewer uses the already-connected SSH daemon (`fetch_file`), loading should be near-instantaneous (1 RTT) per preview.

### Scenario D: Result Navigation (Jumping to File)
*Tests translating a search result into a usable editor buffer.*
1.  **Action:** While viewing search results, select a match and press `<CR>`.
2.  **Verify UI:**
    -   Telescope and the Top-Right UI should immediately close.
    -   Neovim should open the remote file in the current window (`remote://user@host:/path/file:line`).
    -   The cursor should be placed exactly on the line and column of the search match.
    -   You should be able to press `:w` to save edits back over SFTP as verified in previous milestones.

## 3. Troubleshooting

- **"Cannot connect to daemon for search"**: Ensure the path to the daemon binary is correct and it was built properly.
- **Telescope Empty Results**: Verify that `rg` (ripgrep) is installed on the **remote server**, not just locally! The daemon uses standard `rg` in the shell environment.
- **Top-Right window stays open**: If the plugin crashes mid-search, the `WinLeave` hook might fail. Running `:lua require('zero-nvim.ui').close_search_status()` manually can clear it.
