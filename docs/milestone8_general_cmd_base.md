# zero.nvim 通用远程命令基座 — 实施方案

## Context

**为什么做**：当前 zero.nvim 的远程命令执行是"面向搜索专化"的——`exec_remote` 只抓 stdout、search 自己写流式逻辑、libssh2 Session 在搜索期间被 Mutex 全程占用、UI 关闭不能取消远端进程。要继续给 git（hunk-level diff、status、stage）和 docker 做远程化，再这样堆下去会彻底变形。

**目标**：把"远程命令"抽象为五段流水线（命令执行 → 数据采集 → 数据传输 → 下游解析 → 下游可视化），让搜索 / git / docker 共享同一基座；搜索作为首个迁移用例，git 只读功能（status + signs）作为 Phase 2 验证基座的足够通用性。

**用户决策（已锁定）**：
1. 方案详细到 **Phase 2**（基座 + 搜索迁移 + git 只读 + mini-gitsigns）；P3+ 仅给方向
2. neogit 路线：**fork 一份 neogit**，保留其 UI 组件，把 `lib/git/cli.lua` + `process.lua` 替换为走 zero daemon 的后端（这是 P3+ 工作，本方案仅留接口）
3. rg P1 切 `--json` 模式

**关键诊断（已通过读源码验证）**：
- `daemon/src/search.rs:41` 的 `with_conn` 持锁跨整个 `run_search`，`L131-144` 用阻塞 `BufReader` 同步读 stdout，`L152-153` 等 stdout EOF 后才读 stderr——既独占 Session 阻塞 SFTP 又有 stderr 反压死锁风险
- `daemon/src/fs.rs:532-556` `exec_remote` 不抓 exit_code / stderr / stdin，不能承担 git 写命令
- 流式 RPC 用 `nvim_exec_lua` 调 hardcoded 函数名 (`require('zero-nvim.search').on_chunk`)，无 session 注册、无 cancel、无 backpressure

---

## 五段流水线总览

```
[Rust daemon]                                  [Lua plugin]
─────────────                                  ───────────
1. 命令执行     → 2. 数据采集    → 3. 数据传输 →  4. 解析    → 5. 可视化
RemoteCommand     batcher           RPC           parsers      widgets
exec_sync         (80ms/16K/200L)   notifications (rg/git/...) (list/tree/preview/signs)
exec_stream       stderr 分离       cancel/ack
+ PidKill cancel  二进制安全
```

---

## Phase 0 — 通用基座（2-3 天）

### 目标
建立 Rust 端 cmd 层 + Lua 端 cmd 层 + Parser 接口 + Widgets 骨架。**完全不动现有 search、exec_remote、UI**，新老并行。

### Rust 改动

新建目录 `daemon/src/cmd/`：
```
cmd/
  mod.rs           pub use ...; CommandEvent enum
  spec.rs          RemoteCommand struct + builder
  exec_sync.rs     run_sync()       —— 走 with_conn，便宜
  exec_stream.rs   run_streaming()  —— 专属 Session + non-blocking select
  batcher.rs       三阈值聚合 (80ms / 16 KiB / 200 行)
  cancel.rs        CancelToken + PidKill 升级（5s grace）
  registry.rs      running_commands: HashMap<Uuid, CmdHandle>
  dispatch.rs      cmd_sync / cmd_stream / cmd_cancel / cmd_progress_ack
```

**关键接口**（伪码）：
```rust
// cmd/spec.rs
pub struct RemoteCommand {
    pub argv: Vec<String>,           // 远端 sh -c 'exec "$@"' -- argv，避免 shell 注入
    pub env: Vec<(String, String)>,
    pub cwd: Option<String>,
    pub stdin: Option<Vec<u8>>,
    pub timeout_ms: Option<u64>,
    pub pty: bool,                   // docker/交互命令用
}

// cmd/mod.rs
pub enum CommandEvent {
    Stdout(Vec<u8>),
    Stderr(Vec<u8>),
    Exit { code: i32, signal: Option<i32>, duration_ms: u64 },
    Aborted { reason: String },      // cancel / timeout / connection lost
}

// cmd/exec_stream.rs
pub fn run_streaming(
    target: ConnTarget,
    cmd: RemoteCommand,
    sink: impl Fn(CommandEvent) + Send + 'static,
    cancel: CancelToken,
) -> JoinHandle<Result<(), anyhow::Error>>;
```

**并发模型修正（关键）**：
- 流式命令**不复用**全局 `sessions[key]`，而是 `connect.rs` 新增 `pub fn open_dedicated_session(...)`，每条流式命令拥有独占 Session，长命令不阻塞 SFTP / read_dir
- 每个流式 Session 内部仍**单线程 + non-blocking poll**（libssh2 不支持多线程同 Session）：
  ```
  loop {
      if cancel.is_cancelled() { send_signal_via_pidkill(); break; }
      session.set_blocking(false);
      let n_out = channel.read(&mut buf_out)?;        // EAGAIN 不报错
      let n_err = channel.stderr().read(&mut buf_err)?;
      batcher.feed_stdout(&buf_out[..n_out]);
      batcher.feed_stderr(&buf_err[..n_err]);
      batcher.flush_if_due(&sink);
      if channel.eof() { break; }
      if n_out == 0 && n_err == 0 { thread::park_timeout(Duration::from_millis(5)); }
  }
  let exit = channel.exit_status()?;
  sink(CommandEvent::Exit { code: exit, ... });
  ```

**Cancel 三层升级**：
- exec 时把命令包成 `sh -c 'echo $$; exec "$@"' -- argv`，第一行抓出 remote PID 存到 `CmdHandle.remote_pid`
- `cmd_cancel` 触发：先 `channel.close()`；3 秒 grace 后开新 channel 跑 `kill -TERM <pid>`；再 2 秒 `kill -KILL`
- PTY 命令：直接写 `0x03 (Ctrl-C)` 到 stdin 触发 SIGINT

**Backpressure（反馈式压力位，不用 ack）**：
- `CmdHandle` 维护 `pending_chunks: AtomicU32`
- 推一个 chunk → +1；Lua 通过 `cmd_progress_ack(sid, n)` notification → -n
- `> 32` 时 batcher 的时间窗从 80ms 拉到 250ms，并在事件流中插入一个 `Progress { throttling: true }` 让 UI 显示"缓冲中..."
- **绝不丢数据**

**Dispatch 注册**（`main.rs` 加方法）：
- `cmd_sync(target, spec) → {stdout: bytes, stderr: bytes, code, duration_ms}` —— 同步全量
- `cmd_stream(sid, target, spec) → ()` —— 立即返回，事件流走 notification
- `cmd_cancel(sid)` —— notification
- `cmd_progress_ack(sid, n)` —— notification

**RPC 通知格式统一**（替代现在 hardcoded `require('zero-nvim.search')`）：
```
[2, "nvim_exec_lua",
 ["require('zero-nvim.cmd.exec')._dispatch(...)",
  [sid, kind, payload]]]
```
其中 `kind` ∈ `"chunk" | "exit" | "aborted" | "progress"`，`payload` 按 kind 不同。

### Lua 改动

新建 `lua/zero-nvim/cmd/`：
```
cmd/
  init.lua           sync / sync_full / stream 三档入口
  exec.lua           session 注册 + autocmd 自动 cancel + 事件分发
  parsers/
    init.lua         Parser 协议
```

**三档 API**（统一在 `cmd/init.lua`）：
```lua
-- 档位 1：极快路径，给 git rev-parse / docker info 这种小命令用
M.sync(target, "git rev-parse HEAD", { timeout_ms = 5000 })
  -> { stdout, stderr, code, duration_ms }, err

-- 档位 2：同步但需要 stdin/env/cwd（git commit -F - 用）
M.sync_full(target, { argv = {...}, cwd = ..., stdin = ..., env = ... })
  -> { stdout, stderr, code, duration_ms }, err

-- 档位 3：流式（搜索 / git diff / docker logs）
M.stream(target, {
    argv = {...},
    parser = require("zero-nvim.cmd.parsers.rg").new(),
    owner_buf = buf,        -- 关闭即自动 cancel
    owner_win = win,
}, {
    on_event = function(ev) ... end,
    on_exit = function(code, signal, reason) ... end,
})  -> session_id

M.cancel(sid)
```

**session 注册 + 自动 cancel**（`cmd/exec.lua`）：
- `M._sessions[sid] = { parser, handlers, cancelled, owner_buf, owner_win }`
- 注册 `BufWipeout` / `WinClosed` autocmd，关闭即 `M.cancel(sid)`
- daemon 的事件回调统一进 `M._dispatch(sid, kind, payload)`
- exit 事件到达后调 `parser:finalize()` flush 残留再 `on_exit`，最后从 `_sessions` 删除

**Parser 协议**（`parsers/init.lua`）：
```lua
---@class Parser
---@field feed     fun(self, bytes: string): Event[]   -- 增量 chunk
---@field feed_err fun(self, bytes: string): Event[]   -- stderr 单独入口
---@field finalize fun(self): Event[]                  -- EOF 时 flush 残留
---@field reset    fun(self)
```
**纪律**：parser 永远不调 vim.api、不持有 buffer 引用。纯字节流 → 事件，是后续 UI 复用的前提。

### Widgets 骨架（Phase 0 只起架子，P1/P2 填）

新建 `lua/zero-nvim/ui/widgets/`：
```
widgets/
  list.lua         list + 标准 keymap (j/k/<CR>/q/?) + 选中回调
  tree.lua         可折叠树（P1 从 search.lua 提取）
  preview.lua      side preview pane
  diff_signs.lua   sign + virt_text 渲染 hunks（P2 用）
  statusline.lua   流式命令状态条 (running / N items / throttled)
```
P0 仅建文件 + 占位 API；具体实现跟随后续 Phase 增量补全。

### Phase 0 验收
1. `:lua print(vim.inspect(require'zero-nvim.cmd'.sync(target, {"uname","-a"})))` 拿到完整 stdout/stderr/code
2. `:lua require'zero-nvim.cmd'.stream(target, {argv={"sh","-c","for i in $(seq 1 1000); do echo $i; sleep 0.01; done"}, parser=passthrough_parser}, {on_event=print, on_exit=print})` 看到约 80ms 节奏的 chunk
3. 流式跑 5s 内 cancel：远端 `pgrep -f "seq 1 1000"` 在 5s 内消失
4. **关键回归**：流式命令运行期间，另起一个 `:ZeroBrowse` 不被阻塞（验证专属 Session 解耦）

### Phase 0 不做的事
- 不动 search.rs / search.lua / exec_remote
- 不实现 widgets 具体 UI（只起目录）
- 不写任何 git/docker parser

---

## Phase 1 — search 迁移（2 天）

### 目标
把 `global_search` 从 `search.rs` 整体迁移到新基座 + rg JSON 模式 + tree widget 提取。**跑完即删 search.rs**。

### Rust 改动
1. **删除** `daemon/src/search.rs` 整文件
2. **删除** `main.rs` 的 `global_search` dispatch 分支
3. 新增 rg 参数构造：移到 Lua 端（rg argv 在 Lua 拼接，daemon 只负责通用 exec）
4. **唯一例外**：rg 的 `PATH` 注入逻辑保留——把 `PATH=...:$PATH` 作为 env 字段塞进 `RemoteCommand.env`

### Lua 改动

**新增 `lua/zero-nvim/cmd/parsers/rg.lua`**：
```lua
local M = {}
function M.new()
    return setmetatable({ buf = "" }, { __index = M })
end

function M:feed(bytes)
    self.buf = self.buf .. bytes
    local out = {}
    while true do
        local nl = self.buf:find("\n", 1, true)
        if not nl then break end
        local line = self.buf:sub(1, nl - 1)
        self.buf = self.buf:sub(nl + 1)
        if #line > 0 then
            local ok, obj = pcall(vim.json.decode, line)
            if ok and obj.type then
                if obj.type == "begin" then
                    table.insert(out, { kind = "file_begin", file = obj.data.path.text })
                elseif obj.type == "match" then
                    table.insert(out, {
                        kind = "match",
                        file = obj.data.path.text,
                        lnum = obj.data.line_number,
                        text = obj.data.lines.text,
                        submatches = obj.data.submatches,  -- {{start,end,match}, ...}
                    })
                elseif obj.type == "end" then
                    table.insert(out, { kind = "file_end", file = obj.data.path.text,
                                        stats = obj.data.stats })
                end
            end
        end
    end
    return out
end

function M:feed_err(bytes)
    return { { kind = "stderr", text = bytes } }
end

function M:finalize()
    if #self.buf > 0 then
        local r = self:feed("\n")
        self.buf = ""
        return r
    end
    return {}
end
```

**改写 `lua/zero-nvim/search.lua`**：
- 删 `M.on_chunk` / `M.on_error` / `M.on_end` 三个 hardcoded 入口（daemon 不再调）
- 改用 `cmd.stream` + rg parser，把事件转为现有 `session.files` / `session.file_map` 数据结构
- rg argv 在 Lua 拼接：`{"rg", "--json", "--line-number", "--column", ...flags, query, path}`

**提取 `widgets/tree.lua`**：
- 从 `lua/zero-nvim/ui/search.lua` 的 `render_tree`（150+ 行）抽出通用部分
- 接口：`tree.create(buf, opts)` → handle，`handle:set_data(nodes)` 增量更新，`handle:toggle(line)` 折叠/展开
- 节点结构 `{ id, label, expanded?, children?, render = fn(node) → {text, hl_groups} }`
- **关闭信号**：tree handle 内部不管 cancel；search.lua 把 buf/win 传给 `cmd.stream(spec.owner_buf=...)`，关窗自动 cancel

### Phase 1 验收
1. 全功能搜索（普通 / case / whole-word / file_types）输出与旧版**视觉一致**（rg JSON 提供更精确的 submatch 范围，高亮反而更准）
2. 搜索运行中关闭浮窗：5 秒内 daemon 远端 `pgrep -f rg` 消失
3. 大结果（10k matches）下插入模式打字延迟 < 100ms（旧版可能 > 300ms）
4. **回归**：搜索运行期间打开 `:ZeroBrowse` 不卡顿
5. **回归**：搜索期间 SSH idle 触发 keepalive，不影响结果完整性
6. grep 仓库：0 处 `require('zero-nvim.search').on_chunk` / `on_error` / `on_end` 调用

### Phase 1 风险
- `widgets/tree.lua` 抽得不够通用，git status 复用时要二次重构 → 可接受，P2 时按需调整
- rg JSON 输出格式 rg 版本敏感（`--json` 是 stable API，但 13.x 之前的版本需要确认）→ daemon 启动时 `rg --version` 探测，< 13.0 fallback 到老 text 模式 + 老 parser（后备 parser 简单写）

---

## Phase 2 — git 只读 + mini-gitsigns（4-5 天）

### 目标
- `:ZeroGitStatus` 命令打开远程 repo 的 git status UI（树形按目录折叠）
- 打开任何 `zero://` buffer 自动显示 git diff signs（`+` / `~` / `-`）
- hunk 跳转命令 `]h` / `[h`
- **不做** stage/commit（写命令留 P3+）

### Rust 改动
**无新 RPC**——全部基于 cmd_sync / cmd_sync_full。
唯一可能新增：在 `cmd::spec` 加一个 helper `RemoteCommand::git(repo_root, args)`，自动注入 `git -C <repo>` 参数和 `GIT_OPTIONAL_LOCKS=0` env。

### Lua 改动

**新增 `lua/zero-nvim/cmd/parsers/git_status.lua`**：
- 用 `git status --porcelain=v2 -z` 输出（`\0` 分隔，避免文件名空格/特殊字符歧义）
- parser 状态机：split by `\0`，每段按首字符分类（`1`/`2`/`u`/`?`），生成 `{kind="entry", path, x_status, y_status, orig_path?}` 事件

**新增 `lua/zero-nvim/cmd/parsers/git_diff.lua`**：
- `git diff -U0 --no-color HEAD -- <file>` 输出
- 状态机三段：headers (`diff --git`, `---`, `+++`) → hunk header (`@@ -a,b +c,d @@`) → hunk lines (` `/`-`/`+`)
- 事件：`{kind="hunk", file, old_start, old_count, new_start, new_count, lines=[{type, text}]}`
- **不在 parser 渲染**，只产数据

**新增 `lua/zero-nvim/git/status.lua`**：
- 命令 `:ZeroGitStatus`：解析当前 buffer 的 `zero://` URI 找 repo root（用 `cmd.sync` 跑 `git rev-parse --show-toplevel`），打开浮窗
- 调 `cmd.stream` 跑 `git status --porcelain=v2 -z`，用 `widgets/tree.lua` 按目录分组渲染
- 标记符号：M (modified) / A (added) / D (deleted) / R (renamed) / U (untracked) / ? (unknown)，借鉴 lazygit 风格
- 选中文件按 `<CR>` → 在右侧 preview 窗口显示 `git diff` 输出（只读 buffer）
- 文件按 `o` → 用 `:edit zero://...` 打开真实文件

**新增 `lua/zero-nvim/git/signs.lua`** (mini-gitsigns)：
- 注册 autocmd `BufReadPost` + filter `zero://` URI
- 通过 `cmd.sync` 跑 `git rev-parse --show-toplevel` 获取 repo root，缓存到 `b:zero_git_repo`
- 用 `cmd.sync_full` 跑 `git diff -U0 --no-color HEAD -- <relpath>` 拿 hunks
- 用 `widgets/diff_signs.lua` 渲染 sign：
  - `sign_define("ZeroGitAdd", { text = "+", texthl = "GitSignsAdd" })` 等
  - `nvim_buf_set_extmark` 加 sign + 可选 virt_text
- **触发时机**：BufReadPost / BufWritePost / 显式 `:ZeroGitRefresh`；用 300ms debounce 避免连续触发
- **跳转**：`]h` / `[h` 按 hunk 跳；用 buffer-local keymap

**新增 `lua/zero-nvim/ui/widgets/diff_signs.lua`**（实现 P0 占位的 widget）：
- `M.attach(bufnr, repo_root, relpath)` 启动 sign 渲染
- `M.detach(bufnr)` 清掉所有 sign 和 autocmd
- `M.refresh(bufnr)` 重新跑 diff 并渲染

### Repo Root 检测策略
打开 buffer 时不能为每个 buffer 都跑一遍 `git rev-parse`。两层缓存：
1. **per-host**: `git_root_cache[host][dir] = root | false`（false 表示已确认非 git 目录）
2. **lookup**: 从 buffer 的远端路径开始，逐级向上查缓存；命中 `false` 直接判定非 git；未命中跑 `git rev-parse`，把结果写到从 root 到当前所有上级目录

### Phase 2 验收
1. `:ZeroGitStatus` 在 ~50 文件 dirty 远程 repo < 500ms 出 UI（含 SSH RTT 假设 50ms）
2. 打开任意远程 buffer，1s 内 (debounce + RTT) sign 出现
3. 编辑文件 → `:w` → sign 在 1s 内更新
4. 在大 repo（10k+ 文件）非 git 目录下打开文件，**不**触发 git 探测（cache 命中 false）
5. cancel 一次正在跑的 `git diff HEAD~100` 大 diff：远端 git 进程 5s 内消失
6. 同时打开 10 个远程 buffer，sign 渲染串行化但不卡 UI（每次 diff 都走 `cmd.sync_full`，daemon 端 SFTP 池保护互不阻塞）

### Phase 2 不做的事
- 不做 stage/unstage/commit（写命令）
- 不做 git log / blame / branch（P3+）
- 不做 hunk preview popup（virt_text 之外的 floating window）

---

## Phase 3+ 方向（仅留接口，不细化）

### P3：git 写命令 + neogit fork
- `cmd.sync_full` 在 `git commit -F -`（stdin 传 commit msg）、`git apply --cached -`（stage hunk）等场景验证
- **fork neogit**（用户决策）：复制 NeogitOrg/neogit 仓库为 `lua/zero-nvim/vendor/neogit/`，把 `lib/git/cli.lua` + `process.lua` 替换为基于我们的 `cmd.sync_full` 的实现；保留它的 status/log/commit/rebase/branch UI 组件
- fork 维护风险：上游升级要手动 cherry-pick；建议把改动收敛在 1-2 个文件以降低 rebase 成本

### P4：docker
- `parsers/docker_ps.lua`（`docker ps --format '{{json .}}'` 一行一 JSON）
- `parsers/docker_logs.lua`（带 PTY 的流式日志）
- `docker/logs.lua` UI：list of containers + 选中 `<CR>` 流式 logs 到 split

### P5：清理
- 删 `exec_remote` RPC（确认无引用）
- 删迁移期可能存在的 shim
- 文档：`docs/cmd.md` 描述三档 API + parser 协议

---

## 关键文件清单（Phase 0-2 涉及）

### Rust 端
**新建**：
- `daemon/src/cmd/{mod,spec,exec_sync,exec_stream,batcher,cancel,registry,dispatch}.rs`

**修改**：
- `daemon/src/main.rs` —— dispatch 表加 cmd_sync / cmd_stream / cmd_cancel / cmd_progress_ack；P1 删 global_search 分支
- `daemon/src/state.rs` —— `DaemonState` 加 `running_commands: HashMap<Uuid, CmdHandle>`
- `daemon/src/connect.rs` —— 新增 `pub fn open_dedicated_session(target) -> Session`
- `daemon/src/fs.rs` —— P5 删 `handle_exec_remote`（P0-P2 不动）

**删除**（P1）：
- `daemon/src/search.rs`

### Lua 端
**新建**：
- `lua/zero-nvim/cmd/{init,exec}.lua`
- `lua/zero-nvim/cmd/parsers/{init,rg,git_status,git_diff}.lua`
- `lua/zero-nvim/ui/widgets/{list,tree,preview,diff_signs,statusline}.lua`
- `lua/zero-nvim/git/{status,signs}.lua`

**修改**：
- `lua/zero-nvim/search.lua` —— P1 改写为 cmd.stream + rg parser + widgets.tree
- `lua/zero-nvim/init.lua` —— 注册新命令 `:ZeroGitStatus` / `:ZeroGitRefresh`，加 BufReadPost autocmd 触发 signs

### 复用现有
- `lua/zero-nvim/ui/utils.lua:6-48` `create_float()` —— widgets 全部基于此
- `lua/zero-nvim/ui/icons.lua` —— git status UI 复用文件图标
- `lua/zero-nvim/uri.lua` —— 解析 zero:// URI 拿 host/path
- `lua/zero-nvim/project/manager.lua:67-105` `match_project()` —— 不直接用，但 P3 写命令时可能要拿到 project 配置

---

## 验证策略（端到端）

### Phase 0
```bash
# Rust 端
cd daemon && cargo build && cargo test cmd::

# Lua 端在 Neovim 内
:lua =require'zero-nvim.cmd'.sync({user="...",host="...",port=22}, {"uname","-a"})
:lua require'zero-nvim.cmd'.stream(target, {
  argv={"sh","-c","seq 1 1000 | while read i; do echo $i; sleep 0.01; done"},
  parser=passthrough,
}, { on_event=function(e) print(vim.inspect(e)) end, on_exit=print })
# 中途 :q 关掉触发的 buffer，远端 ssh user@host 'pgrep -f "seq 1 1000"' 应空
```

### Phase 1
- 旧搜索全部用例回归（普通 / case / word / type / glob / 大结果集）
- 关闭浮窗 cancel 验证（同 P0 方法）
- 性能对比：搜索 10k 结果时录一段插入模式打字，对比延迟

### Phase 2
- 在远程仓库做 `echo x >> a.lua && rm b.lua && touch new.txt && git add new.txt`，`:ZeroGitStatus` 应正确分类 M/D/A
- 打开 a.lua，sign 列应在 1s 内出现 `~` 标记
- `]h` 跳到 hunk，`[h` 跳回
- `:ZeroGitRefresh` 后 sign 立即更新
- 在 100 行规模的 diff 中验证 hunk 边界正确性（与本地 `git diff` 输出对照）

---

## 风险与回滚

| 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|
| libssh2 non-blocking + select 在 macOS/Linux 行为差异 | 中 | P0 卡死 | P0 先做 macOS，再补 Linux 测试；如非 blocking 模式有问题 fallback 到 blocking + 双线程（接受单 Session 锁定的代价） |
| rg --json 在远端 rg < 13.0 版本不兼容 | 低 | P1 部分用户报错 | daemon 启动时探测版本，旧版 fallback 到 text parser |
| `widgets/tree.lua` 抽象不够通用 | 中 | P2 git status 重写 tree | 接受重构；不要在 P1 过度设计 |
| neogit fork 后上游同步成本超预期 | 中 | P3 拖延 | 改动尽量收敛到 cli.lua + process.lua 两个文件，降低 rebase 表面积 |
| Backpressure 反馈机制太复杂 | 低 | P0 实现拖延 | P0 先不做 backpressure，仅做 batcher；上线后观察是否真的需要再补 |

**回滚**：每个 Phase 都是新代码 + 老代码并存（除 P1 删 search.rs），git 上每 Phase 一个分支；任意 Phase 失败可独立回滚不影响已交付的 Phase。
