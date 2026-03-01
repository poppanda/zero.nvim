### Milestone 1：纯 Lua 跑通“只读”虚拟文件系统 (VFS) [COMPLETED]

第一步，先不要碰任何后台守护进程，就用 Neovim 纯 Lua API 和系统的 `ssh` 命令，把远程文件拉到本地显示出来。

**核心任务：**

1. **定义伪协议：** 设定你的文件打开方式，例如 `nvim remote://user@host:/path/to/file`。
2. **拦截读取：** 使用 `BufReadCmd` 拦截对 `remote://` 前缀的加载。
3. **系统调用：** 在回调函数中，使用 `vim.system`（Neovim 0.10+）异步执行 `ssh user@host "cat /path/to/file"`。
4. **写入 Buffer：** 将 stdout 的内容按行分割，用 `vim.api.nvim_buf_set_lines` 塞进当前 Buffer，并设置 `nomodified`。

**达标标志：** 你能在本地 Neovim 秒开一个远程文件，哪怕它是只读的。

### Milestone 2：引入高性能后台守护进程 (Daemon) [COMPLETED]

纯 Lua 的 `vim.system` 每次读写都要拉起一个新的 SSH 进程，连接开销极大，完全无法实现“0延迟同步”。这时候就需要开发常驻后台的 Daemon 了。

**核心任务：**

1. **技术选型：** 编写这个 Daemon 需要处理高并发的异步网络 I/O、子进程管理以及与 Neovim 的进程间通信。使用 Rust 或 C++ 这类系统级语言来构建这个核心引擎是非常理想的选择，能够轻松榨干性能并实现极低的内存占用。
2. **Msgpack-RPC 通信：** Daemon 启动后，通过标准输入输出（stdio）或 Unix Socket 与本地 Neovim 建立连接。你需要找一个 Msgpack-RPC 的库（比如 Rust 的 `rmpv`）。
3. **连接复用（Multiplexing）：** Daemon 内部维护一个到远程服务器的长连接（比如使用 `libssh` 建立持续的 SSH 隧道）。
4. **重构读写逻辑：** 将 Milestone 1 中的 `vim.system('ssh ...')` 替换为向 Daemon 发送 RPC 请求：`vim.rpcnotify(daemon_id, 'fetch_file', { host, path })`。

**达标标志：** Lua 前端变得极度轻量，所有网络请求通过 Daemon 瞬间完成，文件读写不再有建立 SSH 连接的卡顿。

### Milestone 3：项目拓扑感知与目录树缓存 (Project Tree & VFS Expansion) [COMPLETED]

要管理项目，第一步是让 Neovim 知道远程项目长什么样。如果每次展开目录都阻塞等待 SSH 返回，体验会非常糟糕。

**核心任务：**

1. **扩展 VFS 协议：** 让你的 `remote://` 协议不仅能处理文件，还能处理目录（Directory）。
2. **远程拓扑扫描：** 当以目录为入口打开项目时，Daemon 应该在远端执行类似 `find` 或 `fd` 的指令，拉取整个项目的初始目录树元数据（文件名、大小、类型、修改时间）。
3. **本地内存映射（In-Memory FS）：** Daemon 需要在内存中维护一棵虚拟目录树。这样，当本地 Neovim 的文件浏览器（如 `neo-tree` 或 `nvim-tree`）请求读取目录内容时，Daemon 可以做到 **0 延迟的内存级响应**。
4. **远端事件监听（inotify/fsevents）：** 既然是项目，远端可能会有其他进程（比如 Git 切换分支、编译脚本生成文件）修改目录。你需要在远端注入一个极轻量的监听进程，一旦远端文件树发生变化，立刻通过长连接 Push 给本地 Daemon 更新缓存，并通知 Neovim 刷新文件树。

**达标标志：** 你可以在本地用 `nvim-tree` 丝滑地展开/折叠一个包含上万个文件的远程项目目录，且远端执行 `touch new_file` 时，本地文件树能瞬间自动出现该文件。

### Milestone 4：项目管理与文件操作 (Project Management)

完善对远程项目的增删改查能力，并引入全项目搜索，真正实现“管理”远程项目。

**核心任务：**

1. **全局搜索 (Global Search)：**
   - **流式 RPC：** 实现 `grep` / `rg` 的流式结果返回，避免一次性传输大量数据卡死 UI。
   - **Telescope/Fzf 集成：** 将远端搜索结果实时接入本地 Telescope Picker，点击跳转 `remote://` 文件。

2. **文件/目录操作 (File Operations)：**
   - 实现远程 `mkdir`, `touch`, `rm`, `mv`, `cp` 等操作。
   - 对接文件管理器插件（如 `oil.nvim`, `neo-tree`）的写操作 API。

3. **Session 持久化：**
   - 记住上次打开的远程项目状态，下次启动自动连接。

**达标标志：** 可以像操作本地项目一样，随意创建文件、重构目录，并能通过 Telescope 秒搜远程代码。

### Milestone 5：LSP 代理基础 (LSP Proxy Foundation) [COMPLETED]

搭建 Neovim 与远程 Language Server 之间的通信桥梁，实现单文件级别的智能功能。

**核心任务：**

1. **Daemon 进程管理：**
   - Daemon 能够在远程服务器上启动、监控、终止 LSP 进程（如 `clangd`, `pyright`）。

2. **Stdio 转发 (Stdio Forwarding)：**
   - 建立双向管道，将 Neovim 发出的 LSP 请求（JSON-RPC）透传给远程 LSP。
   - 将远程 LSP 的响应透传回 Neovim。

3. **基础路径转换：**
   - 处理最简单的 `textDocument/didOpen` 和 `textDocument/didChange`。
   - 将本地 `remote://...` 转换为远程 `file://...` 发送给 LSP。

**达标标志：** 打开一个远程 Python 文件，能够通过远程 `pyright` 获得基本的语法检查和 Hover 文档。

### Milestone 6：LSP 进阶与工作区支持 (Advanced LSP & Workspace) [COMPLETED]

解决复杂的路径映射和工作区级功能，让 LSP 真正可用。

**核心任务：**

1. **工作区根目录欺骗 (Workspace Root)：**
   - 拦截 `initialize` 请求，修改 `rootUri` 为远程真实路径，让 LSP 正确识别项目根目录。

2. **诊断信息映射 (Diagnostics)：**
   - 拦截 `textDocument/publishDiagnostics`，将远程返回的 `file://` 路径还原为本地 `remote://` URI，确保波浪线画在正确的位置。

3. **跨文件跳转 (Go-to-Definition)：**
   - 当 LSP 返回定义位置时，如果目标文件未在本地缓存，自动触发 fetch 操作并在新 Buffer 打开。

**达标标志：** 在 C++/Rust 项目中，能够准确进行跨文件跳转，查找引用，且项目级报错准确无误。

### Milestone 7：零延迟编辑与增量同步 (Zero Latency & Sync)

极致优化编辑体验，消除网络延迟带来的顿挫感。

**核心任务：**

1. **乐观 UI 更新 (Optimistic UI)：**
   - 本地修改立即生效，后台异步发送 Diff。

2. **增量同步 (Incremental Sync)：**
   - 仅发送文件变动部分（Diff/Delta），而非全量覆盖，大幅降低带宽占用。

3. **冲突处理：**
   - 简单的版本控制或最后写入优先策略，防止并发修改丢失数据。

**达标标志：** 即使在弱网环境下，打字编辑也如本地般丝滑，完全感觉不到并在远程编辑。
