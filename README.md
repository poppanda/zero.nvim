# zero-nvim

**zero-nvim** is a remote editing plugin for Neovim. A local Rust daemon multiplexes SSH connections (SFTP, remote commands, LSP proxy), so browsing, editing, searching and LSP on a remote host feel local.

## Features

- **Persistent connections**: one authenticated SSH session per host is reused for all files and directory listings, with automatic reconnect.
- **Directory caching**: listings are cached in the daemon (30s TTL, invalidated on changes made through zero-nvim) and the project tree is pre-scanned in the background.
- **Safe writes**: files are written atomically (temp file + rename); a buffer whose remote file failed to load refuses `:w` so it can't truncate the file.
- **ZeroLink UI**: floating picker over `~/.ssh/config` hosts plus a remote directory browser.
- **Projects**: saved remote roots with per-project LSP configuration.
- **Remote LSP**: language servers run on the remote host behind a local TCP proxy, with auto-start, auto-restart and cross-file jumps.
- **Search**: ripgrep on the remote host (or locally) with a tree-style results UI, plus a small in-buffer find/replace.
- **Integrations**: oil.nvim adapter; gitsigns / neogit backends (require forks that expose a `backends` registry).

## Installation

### 1. Build the Daemon

```bash
make build                          # debug build (default build_type)
cd daemon && cargo build --release  # release build
```

### 2. Configure Neovim

Using `lazy.nvim`:

```lua
{
  "your-username/zero-nvim",
  build = "cd daemon && cargo build --release",
  opts = {
    daemon = { build_type = "release" },
  },
}
```

The plugin calls `setup()` with defaults automatically if you don't.

## Configuration

All options with their defaults:

```lua
require("zero-nvim").setup({
  daemon = {
    path = nil,           -- explicit path to the zero-nvim-daemon binary
    build_type = "debug", -- otherwise use <plugin>/daemon/target/<build_type>/zero-nvim-daemon
  },
  log = {
    level = vim.log.levels.INFO, -- minimum level for zero-nvim notifications
    prefix = "ZeroNvim: ",
  },
  explorer = "builtin",   -- "builtin" directory view, or "oil" to let oil.nvim handle zero:// buffers
  gitsigns = {
    refresh = {
      debounce_ms = 300,  -- debounce for event-triggered :Gitsigns refresh
      poll_ms = 0,        -- > 0 also polls every poll_ms while a zero:// buffer is visible
    },
  },
  neogit = {
    watcher = {
      debounce_ms = 200,  -- debounce for event-triggered neogit refresh
      poll_ms = 0,        -- > 0 also polls while a remote neogit watch is active
    },
  },
})
```

The `gitsigns` / `neogit` options only matter when a gitsigns / neogit fork exposing `gitsigns.backends` / `neogit.backends` is installed; with upstream versions zero-nvim skips them silently.

LSP servers are configured per project (see [Remote LSP](#remote-lsp)), not in `setup()`.

## Integrations

### Oil.nvim

```lua
-- 1. Register the zero adapter with oil
require("oil").setup({
  adapters = {
    ["zero://"] = "zero",
  },
})

-- 2. Let oil own zero:// buffers
require("zero-nvim").setup({
  explorer = "oil",
})
```

With `explorer = "oil"`, `:e zero://user@host/path/to/dir/` opens in oil, and file reads/writes go through the adapter (same save semantics as the builtin path).

## Usage

### Manual Remote Protocol

```vim
:e zero://user@host[:port]/path/to/file_or_dir
```

- **Builtin directory view** (`explorer = "builtin"`): `<CR>` opens a file or enters a directory (`<CR>` on `../` goes up), `R` refreshes.
- **Saving**: `:w` writes to the remote host. If the remote file could not be loaded, the buffer stays empty and read-only and `:w` is refused; `:e` retries the load, `:w!` overwrites the remote file anyway. Opening a path that doesn't exist yet gives a `[New]` buffer. Ranges (`:'<,'>w zero://...`) and appends (`:w >> zero://...`) work too.

### ZeroLink (SSH Config Picker)

```vim
:ZeroLink [ssh_target] [path]
```

- **No args**: floating picker of `~/.ssh/config` hosts, then a directory browser.
- **`ssh_target`** (host alias or `user@host[:port]`): opens the directory browser directly.
- **`ssh_target path`**: opens the path directly (relative paths and `~` are resolved against the remote `$HOME`).

Directory browser keys: `<CR>` enter directory / open file, `<C-s>` confirm the current directory, `-` go up, `.` toggle hidden files, `q` / `<Esc>` cancel.

### Project Management (ZeroProject)

```vim
:ZeroProject [add | check <name>]
```

- **`:ZeroProject`**: project picker.
  - `<CR>`: open project
  - `<C-a>`: add the current remote buffer's directory as a project
  - `<C-e>`: edit project configuration (JSON)
  - `<C-d>`: delete project
  - `<C-l>`: add an LSP server (same wizard as `:ZeroLspAdd`)
  - `<C-h>`: connectivity / environment health check
- **`:ZeroProject add`**: add the current remote buffer's directory as a project.
- **`:ZeroProject check <name>`**: run the health check for a project.

Projects are stored in `stdpath("data")/zero-nvim/projects.json`. The project with the longest root matching a buffer's path applies.

### Remote LSP

Each project's `lsp` table maps a server name to its config (`lsp.<name>`):

```json
{
  "host": "dev-server",
  "user": "me",
  "port": 22,
  "root": "/var/www/backend/",
  "lsp": {
    "basedpyright": {
      "filetypes": ["python"],
      "cmd": ["/var/www/backend/.venv/bin/basedpyright-langserver", "--stdio"],
      "settings": {
        "python": { "analysis": { "typeCheckingMode": "off" } }
      }
    }
  }
}
```

- **`filetypes`**: the server auto-starts (or attaches) when a remote buffer of a matching filetype under the project root is opened. Opening a project directory through `:ZeroProject` or `:ZeroLink` pre-warms all configured servers.
- **`cmd`**: defaults to `{ "<name>", "--stdio" }`. The remote mason bin directory (`~/.local/share/nvim/mason/bin`) is on `PATH`.
- **`settings`**: passed to the server as LSP settings. For pyright / basedpyright, `python.pythonPath` is filled from the remote `which python3` if not set.

The project root is sent as `rootUri`, so cross-file definitions and references work. Jump targets (including dependency files outside the root, which attach to a running server of the same name on that host) are loaded automatically.

Remote LSP runs through the system `ssh` binary in BatchMode, so the host must authenticate with keys or an agent; password-authenticated connections are rejected by the preflight check.

Commands:

- **`:ZeroLspAdd [server]`**: interactive wizard that adds a server to the current buffer's project (mason bins and built-in presets offered, JSON preview before saving) and pre-warms it.
- **`:ZeroLspStart <server> [args...]`**: start a server manually for the current remote buffer (e.g. `:ZeroLspStart basedpyright-langserver --stdio`). If the name matches a project entry (by key or by the first element of its `cmd`), that entry's `cmd` and `settings` are used. Tab-completion lists the remote mason bins.
- **`:ZeroLspStop [server]`**: without an argument, stop the zero LSP clients attached to the current buffer; with a name, stop every client of that server. Stopped clients are not restarted.
- **`:ZeroLspRestart`**: crashed clients are restarted automatically, then retried with backoff (up to 30 minutes) while the host is unreachable; this command retries all such dormant clients immediately. Regaining focus or resuming Neovim does the same.

### Search Project (ZeroSearch)

```vim
:ZeroSearch
```

- **Context detection**: in a `zero://` buffer, ripgrep runs on the remote host (streamed by the daemon, starting from the buffer's directory); otherwise a local `rg` runs from the current working directory. The search path is editable in the top window.
- **Tree results**: matches grouped by file with icons, line numbers and highlighted matches, plus a live preview window.
- **Keys**:
  - `j` / `k`: move between windows / results; `J` / `K` jump between path, query and results
  - `h` / `l`: collapse / expand the file under the cursor
  - `<C-c>`: toggle case-sensitive matching
  - `<C-w>`: toggle whole-word matching
  - `<C-t>`: pick file types to filter by
  - `<CR>`: jump to the match
  - `q` / `<Esc>`: close

### Buffer Search (ZeroSearchMini)

```vim
:ZeroSearchMini
```

Literal find / replace in the current buffer, in a small floating window at the bottom right.

- Remembers the last query per buffer.
- `j` / `k` move between the input lines and the match list; `<CR>` in the query line jumps to the next match; `<CR>` in the list jumps to that match and closes.
- `<C-r>`: show / hide the replace line; `<CR>` on the replace line (or `r` in the list) replaces the current match and advances.
- `<C-c>` / `<C-w>`: toggle case-sensitive / whole-word matching.

## Troubleshooting

- **`Handshake failed` / `Failed getting banner`** (common behind proxies): use an SSH tunnel:
  1. `ssh -L 2222:localhost:22 user@host -N`
  2. `:e zero://user@127.0.0.1:2222/path/to/file`
- **Daemon messages**: daemon stderr is shown as WARN notifications. Start Neovim with `ZERO_NVIM_DEBUG=1` for verbose daemon logging; the output is also appended to `/tmp/zero-daemon.log`.

## Development

```bash
make test        # cargo test + headless Lua tests (scripts/run_tests.sh)
make test-lua    # Lua tests only
```
