# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

**zero-nvim** is a remote editing plugin for Neovim. A local Rust daemon multiplexes SSH connections (SFTP, LSP proxy, ripgrep search) while the Lua plugin provides the Neovim UI and buffer management.

**URI scheme:** `zero://user@host:port/path` (port defaults to 22 if omitted)

## Build Commands

```bash
# Build the Rust daemon (debug)
make build
# Equivalent: cd daemon && cargo build

# Build release
cd daemon && cargo build --release

# Clean temp files
make clean
```

The daemon binary lands at `daemon/target/{debug,release}/zero-nvim-daemon`. The plugin auto-detects it based on the `build_type` config option.

## Architecture

### Communication Flow

```
Neovim (Lua plugin) <--Msgpack-RPC (stdin/stdout)--> Rust Daemon <--SSH/SFTP--> Remote Server
```

### Rust Daemon (`daemon/src/`)

Single-process RPC server. `main.rs` reads Msgpack-RPC from stdin, dispatches to handler modules, writes responses through a single output channel thread (prevents stdout races).

- **state.rs** — Global state: SSH sessions keyed by `user@host:port`, per-connection directory caches
- **connect.rs** — SSH auth chain: agent → config IdentityFile → default keys → password
- **fs.rs** — SFTP operations with directory caching (invalidated on write)
- **lsp.rs** — LSP proxy: binds ephemeral TCP port locally, spawns `ssh` subprocess to remote LSP, three threads handle bidirectional I/O with URI translation (`file://zero://user@host:port/path` ↔ `file:///path`). Uses system `ssh` (not libssh2) for thread-safe pipes.
- **cmd/** — Generic remote command base (replaces former `search.rs`). Three RPCs: `cmd_sync` (one-shot), `cmd_stream` (streaming with batched stdout/stderr notifications + cancel), `cmd_cancel`. Each streaming command owns a dedicated SSH session (via `connect::open_dedicated_session`) so it doesn't block the SFTP pool. Cancel escalates close → SIGTERM (via remote PID) → SIGKILL.
- **ssh_config.rs** — Parses `~/.ssh/config` via ssh2-config crate

### Lua Plugin (`lua/zero-nvim/`)

- **init.lua** — Plugin entry point. Daemon lifecycle (`jobstart` with RPC), connection management, `BufReadCmd`/`BufWriteCmd` autocmds for `zero://*`, user commands (`:ZeroLink`, `:ZeroProject`, `:ZeroSearch`, `:ZeroLspStart`, `:ZeroSearchMini`)
- **lsp.lua** — LSP proxy client. Detects project context via longest-prefix-match on project roots, merges global + project LSP settings, creates Neovim LSP client connected to daemon's TCP proxy
- **search.lua** — Search results tree UI with file-grouped expand/collapse
- **ssh_config.lua** — SSH config parsing with daemon RPC, falls back to local parser
- **project/manager.lua** — Project CRUD with longest-prefix-match for config lookup
- **project/store.lua** — JSON persistence at `stdpath("data")/zero-nvim/projects.json` with mtime caching
- **project/ui.lua** — Project picker dashboard, config editor, health checks
- **ui/** — Floating window components (host picker, directory browser, search UI, icons)

### Oil.nvim Adapter (`lua/oil/adapters/zero.lua`)

Standalone adapter discovered by oil.nvim via `require("oil.adapters.zero")`. Implements oil's adapter interface (`list`, `read_file`, `write_file`, `create_entry`, `delete_entry`, `rename_entry`). When `explorer = "oil"` is set, zero-nvim's `BufReadCmd`/`BufWriteCmd` handlers return early to avoid conflicting with oil's own handlers for the same `zero://*` pattern.

## Key Design Decisions

- **`explorer = "oil"` guard**: When oil is the explorer, `init.lua` BufReadCmd/BufWriteCmd skip processing to prevent infinite refresh loops (both oil and zero-nvim register handlers for `zero://*`)
- **LSP uses system `ssh`** instead of libssh2 channels because libssh2 lacks thread safety for bidirectional I/O on the same session
- **Directory cache** is per-connection and invalidated only on file write to the parent directory
- **vendored-openssl** in Cargo.toml avoids macOS system library issues
- **`readonly` not set on remote buffers**: `handle_fetch` intentionally does NOT set `readonly=true` after writing content. Although remote files are logically read-only (edits are handled via `BufWriteCmd`), setting `readonly=true` triggers W10 warnings when Neovim's internal buffer-loading machinery (bufload, BufRead events, fold operations `normal! zv`) later touches the buffer.
- **`buflisted=true` after fetch**: `handle_fetch` sets `buflisted=true` after content is written. `vim.fn.bufadd()` creates unlisted buffers by default; setting `buflisted=true` fires the `BufAdd` event which buffer-manager plugins (barbar, bufferline, etc.) use to register new buffer tabs.

## LSP Definition Jump — Neovim 0.11 Code Path

In Neovim 0.11, `vim.lsp.buf.definition()` does NOT call `show_document` or `jump_to_location`. The actual path is:

```
vim.lsp.buf.definition
  → get_locations → client:request("textDocument/definition", ...)
  → on_response (vim.schedule callback, no textlock)
  → util.locations_to_items(locations, offset_encoding)   ← interception point
  → vim.uri_to_bufnr(uri) → vim.fn.bufadd(fname)          ← creates UNLISTED buffer
  → nvim_win_set_buf → nvim_win_set_cursor                 ← crashes if buf is empty
```

**Fix (`init.lua` `M.setup()`):** Patch `vim.lsp.util.locations_to_items` at setup time. Because `on_response` accesses it via table field lookup (`util.locations_to_items`), the patch is visible even when keybindings captured `vim.lsp.buf.definition` by reference before `M.setup()` ran. The patch calls `M.handle_fetch` on any empty `zero://` buffer found in the locations list, pre-loading it before `nvim_win_set_buf` + `nvim_win_set_cursor` execute.

**Why other approaches failed:**
- `BufEnter` autocmd: blocked by textlock (fires during `nvim_win_set_buf`)
- `start_client` `handlers` table: not invoked by `vim.lsp.buf.definition` in Neovim 0.11
- Patching `show_document` / `jump_to_location`: not called in Neovim 0.11 definition flow
- `BufAdd` autocmd: `vim.fn.bufadd()` creates **unlisted** buffers; `BufAdd` only fires for listed buffers → use `BufNew` instead

## RPC Methods (daemon)

`connect`, `stat`, `fetch_file`, `fetch_path`, `fetch_paths`, `write_file`, `read_dir`, `scan_project`, `mkdir`, `remove_file`, `remove_dir`, `rename`, `exec_remote`, `cmd_sync`, `cmd_stream`, `cmd_cancel`, `lsp_start`, `list_ssh_hosts`, `resolve_ssh_target`

## Debug

- LSP raw traffic logs: `/tmp/daemon_ssh*`, `/tmp/debug_ssh_raw.log`
- LSP init dump: `/tmp/zero_lsp_init_dump.json`
- Daemon stderr output shows in Neovim notifications (WARN level)
