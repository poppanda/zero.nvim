# Milestone 6 Testing Guide — Advanced LSP & Workspace

This document covers the three core features introduced in Milestone 6 and the
manual procedures for verifying each one.

## Overview of M6 Features

| Feature | Implementation | Status |
|---------|---------------|--------|
| Workspace root injection | `lsp.lua` `before_init` patch | ✅ |
| Diagnostics URI mapping | `lsp.rs` `pump_and_translate` (SSH→TCP) | ✅ |
| Cross-file jump (Go-to-Definition) | `init.lua` `locations_to_items` patch | ✅ |
| Find References cross-file | same `locations_to_items` patch | ✅ |
| LSP lifecycle stop command | `:ZeroLspStop` | ✅ |

---

## Prerequisites

Build the daemon with the latest changes:

```bash
make build
# or: cd daemon && cargo build
```

Ensure the remote server has a project-aware language server installed:

- **Python**: `basedpyright` or `pyright` (via `pip` or Mason)
- **C++**: `clangd`
- **Rust**: `rust-analyzer`

---

## 1. Workspace Root (Task 1)

### What was implemented

`lsp.lua` `before_init` now explicitly sets `params.rootUri`, `params.rootPath`,
and patches `params.workspaceFolders` to use `file://` URIs before the
`initialize` request is sent to the remote LSP. This ensures the language server
always sees the correct project root regardless of how Neovim derived its own
internal workspace folder URIs.

### Test Procedure

1. Register a remote project with a known root:
   ```vim
   :ZeroProject add myproject user@host /home/user/my_project
   ```

2. Open a nested file:
   ```vim
   :e zero://user@host:22/home/user/my_project/src/main.py
   ```

3. Start the LSP:
   ```vim
   :ZeroLspStart basedpyright --stdio
   ```

4. Capture the raw `initialize` request by checking the debug log:
   ```bash
   cat /tmp/daemon_ssh*
   ```
   Look for a JSON block with `"method":"initialize"`. Verify:
   - `"rootUri"` is `"file:///home/user/my_project"` (not `zero://...`)
   - `"rootPath"` is `"/home/user/my_project"`
   - All `workspaceFolders[].uri` values are `"file://..."` (not `zero://...`)

5. Alternatively, in Neovim run:
   ```vim
   :lua print(vim.inspect(vim.lsp.get_clients({bufnr=0})[1].config.root_dir))
   ```
   Expected output: `/home/user/my_project` (plain path, no `zero://` prefix).

### Expected Result

The LSP reports `root_dir` correctly and project-wide features (workspace
symbols, project diagnostics) work across the entire project tree, not just the
single file you opened.

---

## 2. Diagnostics URI Mapping (Task 2)

### What was implemented

`pump_and_translate` (Rust, `lsp.rs`) translates every JSON-RPC message in the
SSH→TCP direction by replacing `file://` with `zero://user@host:port`. This
applies to `textDocument/publishDiagnostics` notifications, including the
`relatedInformation[].location.uri` sub-fields. No additional code was required
because the simple string replacement covers all URI occurrences in the body.

### Test Procedure A — Inline diagnostics

1. Open a remote Python file:
   ```vim
   :e zero://user@host:22/home/user/my_project/src/main.py
   :ZeroLspStart basedpyright --stdio
   ```

2. Introduce a type error (without saving, just modify the buffer):
   ```python
   x: int = "hello"   # type error
   ```

3. Wait ~2 seconds. Verify:
   - Squiggly underline appears on the erroneous line
   - `:lua print(vim.diagnostic.get(0))` returns a non-empty table
   - The `source` field in the diagnostic table is `"basedpyright"` (or similar)

### Test Procedure B — Cross-file diagnostics

1. Open a file that imports from another file in the project:
   ```vim
   :e zero://user@host:22/home/user/my_project/src/consumer.py
   ```

2. In the remote project, break the import target (edit via `zero://`) so
   `producer.py` exports an incompatible type.

3. With the LSP still running, wait for `publishDiagnostics`. Verify:
   - The diagnostic in `consumer.py` appears correctly (squiggly line on import)
   - Run `:lua print(vim.diagnostic.get(0))` to confirm URI mapping

4. Check the raw LSP traffic log to confirm translation:
   ```bash
   grep '"method":"textDocument/publishDiagnostics"' /tmp/debug_ssh_raw.log
   ```
   The log should show `file:///home/user/...` (remote side) while Neovim sees
   `zero://user@host:22/...`.

### Expected Result

All inline diagnostics are displayed on the correct buffer lines. Project-wide
errors from the LSP (e.g., type mismatches across files) show squiggly lines on
the correct `zero://` buffer.

---

## 3. Cross-file Jump — Go-to-Definition (Task 3)

### What was implemented

`init.lua` patches `vim.lsp.util.locations_to_items` at setup time. Before
handing locations back to Neovim's jump machinery, the patch:

1. Calls `vim.fn.bufadd(uri)` for any `zero://` URI not yet in a buffer
2. Calls `M.handle_fetch` on that buffer if it is empty (pre-loads content)
3. Calls `vim.lsp.buf_attach_client` to attach the active LSP client to the
   newly created buffer (so the jumped-to file gets full LSP features)

### Test Procedure A — Same-project definition jump

1. Open a C++ or Rust file that calls a function defined in another file:
   ```vim
   :e zero://user@host:22/home/user/my_project/src/main.cpp
   :ZeroLspStart clangd
   ```

2. Place the cursor on a function call (e.g., `foo()` defined in `util.cpp`).

3. Press `gd` (or your configured Go-to-Definition key).

4. Verify:
   - Neovim opens a new buffer with name `zero://user@host:22/.../util.cpp`
   - The cursor lands on the function definition line
   - Run `:echo expand('%')` — it must show `zero://...`, not `file:///...`
   - Run `:LspInfo` in the new buffer — the LSP client should be attached

### Test Procedure B — Standard-library / external header jump

1. In a C++ file, place cursor on a `std::` type (e.g., `std::vector`).

2. Press `gd`. The LSP may jump to a system header.

3. Verify:
   - If the target is a local project file, it opens as `zero://...` ✓
   - If the target is a system header (e.g., `/usr/include/...`), the URI
     should still be `zero://user@host:22/usr/include/...` after translation

### Test Procedure C — Find References

1. Place the cursor on a function name.

2. Run `:lua vim.lsp.buf.references()` (or your keymap).

3. The quickfix list / Telescope picker opens with all reference locations.

4. Verify:
   - Jump to a reference in another file works as in Procedure A
   - The buffer opens as `zero://...`

### Expected Result

All cross-file jumps open the target file as a `zero://` buffer with content
pre-loaded, cursor at the correct position, and the LSP client auto-attached.

---

## 4. Rename Refactoring (workspace/applyEdit)

This is an additional workspace-level feature enabled by M6's URI translation.

### Test Procedure

1. Open a Python file with a function named `foo`:
   ```vim
   :e zero://user@host:22/home/user/my_project/src/main.py
   :ZeroLspStart basedpyright --stdio
   ```

2. Place cursor on the function name `foo`.

3. Run `:lua vim.lsp.buf.rename()` and type a new name (e.g., `bar`).

4. Verify:
   - All files in the project that reference `foo` are updated in their buffers
   - Run `:wa` to write all modified buffers
   - On the remote server, verify the rename was saved:
     ```bash
     grep -r "def bar" /home/user/my_project/
     ```

---

## 5. LSP Lifecycle — :ZeroLspStop

### Test Procedure

1. Start an LSP as above, then verify it is running:
   ```vim
   :LspInfo
   ```

2. Stop it by name:
   ```vim
   :ZeroLspStop basedpyright
   ```
   (Tab-completion is available for attached client names.)

3. Or stop all zero-* clients on the current buffer:
   ```vim
   :ZeroLspStop
   ```

4. Verify:
   - The notification `ZeroNvim: stopped LSP zero-basedpyright` appears
   - `:LspInfo` no longer shows the client
   - The daemon's SSH subprocess exits (visible in daemon stderr output)

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `rootUri` is `zero://...` in initialize log | `before_init` not running (old Neovim?) | Ensure Neovim ≥ 0.10; check `vim.lsp.start_client` supports `before_init` |
| Diagnostics show on wrong line | LSP using 0-indexed lines | Set `offset_encoding` in `start_lsp` |
| `gd` opens `file:///path` instead of `zero://...` | `pump_and_translate` not translating | Confirm daemon was rebuilt (`make build`); check `/tmp/daemon_ssh*` logs |
| Jump lands on empty buffer | `handle_fetch` failed silently | Check daemon connection: `:ZeroLspStop` + reconnect, look at WARN notifications |
| `:ZeroLspStop` says "no matching client" | LSP name mismatch | Try exact name from `:LspInfo` (prefix `zero-` is stripped automatically) |
