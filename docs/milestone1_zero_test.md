# Milestone 1 Testing Guide (ZeroNvim)

This document outlines the testing procedures for Milestone 1: Pure Lua Read-Only VFS (ZeroNvim).

## 1. Automated Testing

We have provided a self-contained Lua test script that mocks the system SSH call to verify logic without needing a real remote server.

### Running the Test
Execute the following command from the project root:

```bash
nvim -l tests/test_zero_milestone1.lua
```

### What it Tests
- **URI Parsing:** Verifies that `remote://user@host:/path` is correctly parsed.
- **Command Construction:** Checks if `ssh -o BatchMode=yes -o ConnectTimeout=5 user@host cat /path` is generated correctly.
- **Buffer Handling:** 
  - Ensures buffer is set to `buftype=acwrite`.
  - Verifies content is loaded into the buffer.
  - Verifies buffer is set to `readonly` and `nomodified`.
- **Async Handling:** Simulates asynchronous `vim.system` execution.

### Expected Output
```text
Running Milestone 1 Test...
ZeroNvim: Setup initialized
Triggering BufReadCmd for remote://testuser@192.168.1.10:/tmp/remote_file.txt
ZeroNvim: BufReadCmd triggered for remote://testuser@192.168.1.10:/tmp/remote_file.txt
Fetching /tmp/remote_file.txt from 192.168.1.10...
ZeroNvim: Executing SSH command: ssh -o BatchMode=yes -o ConnectTimeout=5 testuser@192.168.1.10 cat /tmp/remote_file.txt
PASS: SSH command constructed correctly.
File loaded: /tmp/remote_file.txt
PASS: Buffer content updated correctly.
PASS: Buffer is readonly.
All tests passed!
```

## 2. Manual Testing (Clean Mode Required)

**Important:** Because there is an existing plugin named `remote-nvim`, you MUST run Neovim in clean mode to develop this plugin locally.

### Start Neovim
In the project root:

```bash
nvim --clean --cmd "set rtp+=."
```

### Test Steps
1. **Verify Setup:**
   - Check `:messages` for `ZeroNvim: Setup initialized`.

2. **Open Remote File:**
   ```vim
   :e remote://<your-user>@<your-host>:/path/to/remote/file.txt
   ```
   *Example:* `:e remote://root@localhost:/etc/hosts`

3. **Verify Loading:**
   - You should see "Fetching..." and "File loaded..." messages.
   - The file content should appear in the buffer.
   - `:messages` will show the exact SSH command executed.

4. **Verify Filetype:**
   - If you opened a `.lua` file, run `:set filetype?` to check if detection worked.

## Known Limitations (Milestone 1)
- **Read Only:** Saving (`:w`) is not yet implemented.
- **SSH Latency:** Depends on pure SSH connection speed.
