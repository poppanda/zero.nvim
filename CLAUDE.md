# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**zero-nvim** is a remote editing plugin for Neovim. A local Rust daemon multiplexes SSH connections (SFTP, remote commands, LSP proxy) while the Lua plugin provides the Neovim UI, buffer management and integrations (oil.nvim, gitsigns/neogit forks).

**URI scheme:** `zero://user@host:port/path` (port defaults to 22 on input; buffer names are always normalized to include it; IPv6 as `zero://user@[::1]:22/path`)

## Build & Test Commands

```bash
make build            # debug daemon (cd daemon && cargo build)
cd daemon && cargo build --release

make test             # test-rust + test-lua
make test-rust        # cd daemon && cargo test
make test-lua         # bash scripts/run_tests.sh (headless nvim, no network)
bash scripts/run_tests.sh tests/test_uri.lua   # single Lua test (NVIM=/path/to/nvim to override)

make smoke-neogit     # needs neogit fork (ZERO_NEOGIT_ROOT, default ../neogit) + plenary.nvim
make smoke-gitsigns   # needs a real host: ZERO_TEST_USER / ZERO_TEST_HOST / ZERO_TEST_PATH [/ ZERO_TEST_PORT]
```

The daemon binary lands at `daemon/target/{debug,release}/zero-nvim-daemon`. `daemon.lua` uses `daemon.path` if set, else resolves it relative to the plugin install root via `daemon.build_type` (never relative to cwd).

## Architecture

### Communication Flow

```
Neovim (Lua plugin) <--Msgpack-RPC (stdin/stdout)--> Rust Daemon <--SSH/SFTP (libssh2)--> Remote Server
Neovim LSP client   <--TCP (127.0.0.1)-->            Daemon proxy <--system ssh-->        remote LSP
```

### Rust Daemon (`daemon/src/`)

- **main.rs** — Entry point; `debug_log!` macro gated by `ZERO_NVIM_DEBUG`.
- **rpc.rs** — Reads Msgpack-RPC requests (`[0, id, method, params]`) and notifications (`[2, method, params]`) from stdin; method dispatch table; `Args` positional-param helpers. All output (responses + notifications) goes through one mpsc channel to a single stdout writer thread. Fast methods (`cmd_cancel`, `cmd_stdin_*`, `cmd_stream` registration, ssh-config lookups) run inline; everything else gets its own thread.
- **state.rs** — `DaemonState` behind `Arc<Mutex<_>>` (held only for table lookups, never across network IO; `lock_ok()` tolerates poison). Keyed by `user@host:port`: shared sessions, exec pool, per-connection `DirCache`, remembered passwords, per-target connect locks, running stream commands; plus parsed `~/.ssh/config`.
- **session.rs** — Two pools: one shared `ConnSession` per target (reused SFTP channel; `with_conn` serializes access and reconnects + retries once when `is_session_dead`), and an exec pool of idle sessions that streaming commands take exclusively (pre-warmed after connect). Also `exec` (non-blocking interleaved stdin/stdout/stderr pump), `exec_shared`, `shell_quote`, error classification.
- **connect.rs** — Auth chain: agent → ssh-config IdentityFile → default keys → password. 10s TCP connect timeout, TCP keepalive. `open_dedicated_session` for the exec pool.
- **fs.rs** — `fetch_path` / `fetch_paths` / `fetch_file` read via one exec round-trip (10 MiB cap; non-UTF-8 content sent as Binary, never lossy). `write_file` is atomic. `scan_project` pre-fills the dir cache (depth 3, one `with_sftp` per directory so it never hogs the connection). Other ops via SFTP.
- **cmd/** — Generic remote commands. `mod.rs`: RPC entry points (`cmd_sync` on the shared session — short probes only; legacy `exec_remote`). `spec.rs`: `RemoteCommand` spec (argv, env, cwd, stdin, timeout_ms, pty) → shell command with optional PID wrapper. `stream.rs`: `cmd_stream` worker on an exclusive exec-pool session; stdin via `cmd_stdin_write` / `cmd_stdin_close`; cancel escalates channel close → 3s → `kill -TERM` (process group) → 2s → `kill -KILL`. `batcher.rs`: batches output (80ms / 16 KiB / 200 lines) without splitting UTF-8 sequences.
- **lsp.rs** — LSP proxy: binds an ephemeral local TCP port, spawns system `ssh` (ControlMaster socket under `$XDG_RUNTIME_DIR/zero-nvim` or `~/.cache/zero-nvim/ssh`) running the server with the remote mason bin dir on `PATH`. Rewrites URIs only at the start of JSON string values (`"zero://user@host:port/` ↔ `"file:///`). `lsp_probe` is a BatchMode preflight.
- **ssh_config.rs** — `list_ssh_hosts` / `resolve_ssh_target` via the ssh2-config crate.

### Lua Plugin (`lua/zero-nvim/`)

Core:
- **init.lua** — `setup(opts)` (idempotent: augroup recreated, global patches installed once), `:Zero*` user commands, LSP autocmds (FileType autostart, BufWinEnter attach, VimResume/FocusGained revive). `plugin/zero-nvim.lua` calls `setup()` only if the user hasn't.
- **config.lua** — Defaults + merged options; modules read `config.get()`.
- **log.lua** — Single notify path (prefix + level filter from `config.log`).
- **util.lua** — Small helpers (timers, `set_lines`, editor size).
- **uri.lua** — All `zero://` parse / format / normalize / join helpers. Always go through it.
- **daemon.lua** — Binary lookup, `jobstart` with `rpc = true`, stderr → WARN notifications, exit listeners (aborts in-flight streams, clears per-connection state).
- **remote.lua** — `request` / `request_interactive` for `method(user, host, port, ...)` RPCs: starts the daemon, connects (password prompt only when interactive), 10s negative connect cache, reconnect + retry on NOT_CONNECTED; `host_cache`, `remote_home`, `list_dir` (fires a background `scan_project` notification).
- **buffer_io.lua** — Remote bytes ↔ buffer lines with Vim read/write semantics ('fileformat', 'eol'/'fixeol', BOM, binary/NUL); load-failed marking.
- **buffers.lua** — `zero://` buffer lifecycle: BufReadCmd / BufWriteCmd / FileWriteCmd / FileAppendCmd, buffer-name canonicalization (aliases redirected), builtin directory view, prefetch stash, filetype detection, `vim.fn.readfile` patch for `zero://`, oil window-option compat.
- **link.lua** — `:ZeroLink` flow (host picker → directory browser → `:edit`); `open_remote` prewarms project LSPs when opening a directory.
- **ssh_config.lua** — Host list / target resolution via daemon RPC, minimal local parser fallback.

Features:
- **lsp/** — `init.lua`: start / autostart / prewarm / attach / stop of `zero-<key>` clients through the daemon proxy (preflight via `lsp_probe`; key/agent auth required; pythonPath injection for pyright-family). `restart.lua`: auto-restart, backoff, dormant clients, `:ZeroLspRestart`. `client_select.lua`: pure client naming / reuse / attach selection (longest covering root; same-host fallback for dependency files). `locations.lua`: definition-jump preload (below). `presets.lua` + `add_wizard.lua`: `:ZeroLspAdd`.
- **project/** — `store.lua` (JSON at `stdpath("data")/zero-nvim/projects.json`, mtime cache), `manager.lua` (CRUD, `upsert_lsp`, longest-prefix `match_project`), `ui.lua` (`:ZeroProject` picker, JSON editor, health check).
- **cmd/** — Lua remote-command API: `init.lua` (`sync`, `stream`, `cancel`, `write_stdin`, `close_stdin`, `with_remote_path`), `exec.lua` (stream session registry, `_dispatch` notification entry, auto-cancel when owner buf/win closes, `abort_all`), `parsers/` (parser protocol + `rg.lua` for `rg --json`).
- **search/** — `:ZeroSearch`: `init.lua` controller (remote rg via `cmd.stream`, local rg via `jobstart`), `view.lua` (path / query / results tree / preview floats), `type_picker.lua` (`<C-t>` file-type filter).
- **search_mini/** — `:ZeroSearchMini` literal in-buffer find / replace (`init.lua` state, `view.lua` floats).
- **gitsigns/** — Backend for a gitsigns fork exposing `gitsigns.backends`; `refresh.lua` triggers `:Gitsigns refresh` on events / optional polling. Silently skipped with upstream gitsigns.
- **neogit/** — Backend for a neogit fork exposing `neogit.backends` (paths / spawn / watch); `watcher.lua` replaces `.git/` fs watching with events + optional polling.
- **ui/** — `float.lua` (shared float / input / JSON editor), `host_picker.lua`, `browser.lua`, `icons.lua`.

### Oil.nvim Adapter (`lua/oil/adapters/zero.lua`)

Discovered by oil.nvim via `require("oil.adapters.zero")` (oil modules are required lazily). Implements `list`, `read_file`, `write_file`, `create_entry`, `delete_entry`, `rename_entry` and actions. Reads / writes reuse `buffers.fetch`, `buffers.apply_fetched` and `buffers.write_buffer`, so the load-failure guard, `:w!`, eol/fileformat handling and the prefetch stash behave as on the builtin path.

## Key Design Decisions

- **`explorer = "oil"`**: zero-nvim does not register BufReadCmd / BufWriteCmd (both plugins handling `zero://*` loop forever); oil owns them. FileWriteCmd / FileAppendCmd and the shared BufWinEnter / FileType autocmds are still registered; an extra BufWinEnter resets oil's pinned window options on file buffers and a `FileType=oil` handler restores the real filetype.
- **LSP uses system `ssh`** instead of libssh2 channels: libssh2 isn't thread-safe for bidirectional I/O on one session. Consequence: remote LSP needs key/agent auth (preflight refuses password-auth hosts).
- **Concurrent dispatch**: each slow RPC runs on its own thread; per-connection work is still serialized by the `ConnSession` mutex. Streaming commands take exclusive exec-pool sessions, so long rg/git runs never block SFTP. `cmd_sync` holds the shared session for its whole duration — short commands only.
- **RPC notifications are handled**: Lua `rpcnotify`s `scan_project`, `cmd_cancel`, `cmd_stdin_write`, `cmd_stdin_close`; no response is sent, errors go to stderr.
- **Directory cache**: per connection, entries expire after 30s (`DIR_CACHE_TTL`) so external changes eventually show. `write_file` / `remove_file` invalidate the parent listing; `mkdir`, `remove_dir`, `rename` invalidate the whole subtree plus the parent.
- **Atomic writes**: `write_file` writes a temp file in the same directory and renames it over the target (falls back to in-place write for symlinks, non-regular files, unwritable dirs).
- **Failed loads are write-protected**: if a fetch fails the buffer stays empty, non-modifiable and `b:zero_load_failed`; `:w` refuses (it would truncate the remote file), `:w!` forces it, `:e` retries. A missing remote file opens as `[New]`. A failed write keeps 'modified' set so `:wq` doesn't quit.
- **Writes are synchronous**: `:wq` / `:x` need 'modified' cleared when BufWriteCmd returns (else E37).
- **`readonly` not set on remote file buffers**: it triggers W10 when bufload / BufRead / fold operations (`normal! zv`) touch the buffer later.
- **`buflisted` set on BufWinEnter**, not after fetch, and skipped in `autocmd`-type windows: buffers preloaded via `bufload` (LSP locations, quickfix) stay unlisted until actually shown. Listing fires `BufAdd`, which barbar / bufferline use to add tabs.
- **No BufNew preload**: content is loaded only by BufReadCmd (or oil's `read_file`); the LSP jump path preloads in `lsp/locations.lua`. BufNew only disables swapfiles (and `SwapExists` → edit anyway).
- **Canonical buffer names**: `zero://u@h/p` and `zero://u@h:22/p` share one buffer; non-canonical aliases are redirected and wiped. Directory buffer names end with `/`.
- **Daemon stderr shows as WARN**, so routine daemon logs print only with `ZERO_NVIM_DEBUG`.
- **vendored-openssl** in Cargo.toml avoids macOS system library issues.

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

**Fix (`lsp/locations.lua`, installed from `M.setup()`):** Patch `vim.lsp.util.locations_to_items`. Because `on_response` accesses it via table field lookup (`util.locations_to_items`), the patch is visible even when keybindings captured `vim.lsp.buf.definition` by reference before `M.setup()` ran. The patch normalizes `zero://` URIs in place, fetches missing files with one `fetch_paths` per host into the prefetch stash, then `bufload`s them (BufReadCmd / oil `read_file` consume the stash) before `nvim_win_set_buf` + `nvim_win_set_cursor` run. Single-location jumps re-snap the cursor (oil's async read can reset it). `vim.lsp.buf_request_all` is also wrapped for definition / declaration / typeDefinition / implementation / references so third-party reference / preview plugins find loaded buffers.

**Why other approaches failed:**
- `BufEnter` autocmd: blocked by textlock (fires during `nvim_win_set_buf`)
- `start_client` `handlers` table: not invoked by `vim.lsp.buf.definition` in Neovim 0.11
- Patching `show_document` / `jump_to_location`: not called in Neovim 0.11 definition flow
- `BufAdd` autocmd: `vim.fn.bufadd()` creates **unlisted** buffers; `BufAdd` only fires for listed buffers. (An earlier `BufNew` preload has been removed; preloading lives only in `lsp/locations.lua`.)

## RPC Methods (daemon, `rpc.rs` dispatch)

Most take `[user, host, port, ...]`.

- SSH config: `list_ssh_hosts`, `resolve_ssh_target`
- Connection: `connect`
- Files: `fetch_path`, `fetch_paths`, `fetch_file`, `write_file`, `read_dir`, `stat`, `scan_project`, `mkdir`, `remove_file`, `remove_dir`, `rename`
- Commands: `exec_remote`, `cmd_sync`, `cmd_stream` (`[session_id, user, host, port, spec]`), `cmd_cancel`, `cmd_stdin_write`, `cmd_stdin_close` (these three take `session_id` first)
- LSP: `lsp_probe`, `lsp_start`

Daemon → Lua: stream events are `nvim_exec_lua` notifications calling `require('zero-nvim.cmd.exec')._dispatch(session_id, kind, payload)`, kind ∈ `stdout` / `stderr` / `exit` / `aborted`.

## Debug

- `ZERO_NVIM_DEBUG=1 nvim ...` — the daemon (inherits the env) prints routine `debug_log!` messages to stderr, and `daemon.lua` tees daemon stderr to `/tmp/zero-daemon.log`. The daemon treats empty / `0` as off; the Lua tee turns on for any set value.
- Daemon stderr always appears as Neovim WARN notifications (`Daemon: ...`); remote LSP ssh stderr is prefixed `[SSH-ERR]`.
- Plugin messages honour `log.level` (set `vim.log.levels.DEBUG` to see `log.debug` output).
