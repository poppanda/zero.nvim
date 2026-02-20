# Milestone 4: Global Search & Tree-View UI - Code Review Guide

This guide is designed to walk you through the codebase changes introduced in Milestone 4, following the logical flow of the newly implemented search architecture.

## 1. Rust Daemon changes (Backend logic)

Our search requires offloading `rg` (ripgrep) workload to the remote daemon to achieve true zero-latency.

*   `daemon/src/main.rs`
    *   **Focus**: Look at the RPC method registration block for `global_search`.
    *   **Key Changes**: Notice how we extract the new boolean flags `case_sensitive` and `whole_word`, unpacking them from the MsgPack parameters before passing them to the handler.
*   `daemon/src/search.rs`
    *   **Focus**: `handle_global_search` and `run_search` functions.
    *   **Key Changes**: Pay attention to how the `run_search` function dynamically constructs the raw shell command for `rg`. See how it appends `--case-sensitive`, `--ignore-case`, and `--word-regexp` based on the UI toggles. The results are chunked and streamed back via Msgpack-RPC.

## 2. Lua UI & Event Binding (Frontend Interface)

The Search subsystem operates through complex floating window manipulations. 

*   `lua/zero-nvim/ui.lua`
    *   **Focus**: The massive `M.open_search_ui` function.
    *   **Key Changes**: 
        *   **Footer generation**: Notice how the `update_input_footer` function is bound to the flag state map (`toggle_state.case_sensitive` / `whole_word`) to draw checkbox-like indicators `[x]Aa`.
        *   **Keymaps**: Browse the end of `open_search_ui` to find the normal and insert mode buffer-specific (`buffer = input_buf`, `buffer = results_buf` etc.) mappings. Note the usage of `<C-w>` and `<C-c>` for boolean flags toggling, and `h`/`l`/`<Left>`/`<Right>` bound to `callbacks.on_toggle_fold` inside the `results_buf`.
        *   **Icon Map**: Note the `M.icon_map` export at the bottom, delivering extension emojis down to the tree render logic.

## 3. Lua Search Core Engine (Data & Rendering)

This file ties the remote RPC streaming, the local job fallback, and the complex Tree-View UI logic together.

*   `lua/zero-nvim/search.lua`
    *   **Focus 1: Execution & Fallback Core** (`M.live_grep`, `M.execute_search`, `M.open_ui`)
        *   Check `M.live_grep` first: See how it parses `vim.api.nvim_buf_get_name(0)` to figure out if we are acting on a local path or an `oil-zero://` / `remote://` network path.
        *   Follow into `M.execute_search`: Observe how we selectively call `vim.fn.jobstart({"rg", ...})` for local paths, and `zero.global_search()` for remote paths via RPC, unifying their output consumption paths.
    *   **Focus 2: Tree-View State Management** (`M.on_chunk`)
        *   See how the streaming text strings from `rg` (`file:lnum:col:text`) are parsed. Observe that we no longer construct a flat array but build a hierarchical `session.files` dictionary mapping to individual `matches`.
    *   **Focus 3: Extmarks Tree Rendering** (`M.render_tree`)
        *   This is the heavy lifter. Analyze the nested loop iterating over `session.files` and drawing `is_expanded` child matches.
        *   Understand the `extmarks` generation structure: how `Directory`, `String`, `Comment`, `LineNr`, and `IncSearch` are mapped to exact byte-offsets on the Neovim buffer grid to achieve high-performance UI styling without syntax files.
    *   **Focus 4: Cursor & Fold Navigation** (`M.set_selection`, `M.update_preview`, `M.toggle_fold`)
        *   Look at `M.toggle_fold` mutating the `file_obj.expanded` boolean and re-triggering `render_tree`.
        *   Look at `M.set_selection` calculating boundaries and enforcing transparent skips over `spacer` nodes.
        *   Finally, look at `M.update_preview` which extracts `content` cleanly either locally (`io.open`) or remotely (`zero.get_file_content`).

## Summary

The entire flow represents a powerful decoupling pattern:
1. `ui.lua` renders blank layout geometry, binds input constraints, and fires callback events.
2. `search.lua` computes states (`session.nodes`), executes parallel async searches (Job vs RPC), and projects data visually using absolute offset `extmarks`.
3. `search.rs` does the brute-force processing strictly in the background with binary streaming mechanisms.
