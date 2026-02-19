### Milestone 1：纯 Lua 跑通“只读”虚拟文件系统 (VFS)

第一步，先不要碰任何后台守护进程，就用 Neovim 纯 Lua API 和系统的 `ssh` 命令，把远程文件拉到本地显示出来。

**核心任务：**

1. **定义伪协议：** 设定你的文件打开方式，例如 `nvim remote://user@host:/path/to/file`。
2. **拦截读取：** 使用 `BufReadCmd` 拦截对 `remote://` 前缀的加载。
3. **系统调用：** 在回调函数中，使用 `vim.system`（Neovim 0.10+）异步执行 `ssh user@host "cat /path/to/file"`。
4. **写入 Buffer：** 将 stdout 的内容按行分割，用 `vim.api.nvim_buf_set_lines` 塞进当前 Buffer，并设置 `nomodified`。

**达标标志：** 你能在本地 Neovim 秒开一个远程文件，哪怕它是只读的。

### Milestone 2：引入高性能后台守护进程 (Daemon)

纯 Lua 的 `vim.system` 每次读写都要拉起一个新的 SSH 进程，连接开销极大，完全无法实现“0延迟同步”。这时候就需要开发常驻后台的 Daemon 了。

**核心任务：**

1. **技术选型：** 编写这个 Daemon 需要处理高并发的异步网络 I/O、子进程管理以及与 Neovim 的进程间通信。使用 Rust 或 C++ 这类系统级语言来构建这个核心引擎是非常理想的选择，能够轻松榨干性能并实现极低的内存占用。
2. **Msgpack-RPC 通信：** Daemon 启动后，通过标准输入输出（stdio）或 Unix Socket 与本地 Neovim 建立连接。你需要找一个 Msgpack-RPC 的库（比如 Rust 的 `rmpv`）。
3. **连接复用（Multiplexing）：** Daemon 内部维护一个到远程服务器的长连接（比如使用 `libssh` 建立持续的 SSH 隧道）。
4. **重构读写逻辑：** 将 Milestone 1 中的 `vim.system('ssh ...')` 替换为向 Daemon 发送 RPC 请求：`vim.rpcnotify(daemon_id, 'fetch_file', { host, path })`。

**达标标志：** Lua 前端变得极度轻量，所有网络请求通过 Daemon 瞬间完成，文件读写不再有建立 SSH 连接的卡顿。

### Milestone 3：项目拓扑感知与目录树缓存 (Project Tree & VFS Expansion)

要管理项目，第一步是让 Neovim 知道远程项目长什么样。如果每次展开目录都阻塞等待 SSH 返回，体验会非常糟糕。

**核心任务：**

1. **扩展 VFS 协议：** 让你的 `remote://` 协议不仅能处理文件，还能处理目录（Directory）。
2. **远程拓扑扫描：** 当以目录为入口打开项目时，Daemon 应该在远端执行类似 `find` 或 `fd` 的指令，拉取整个项目的初始目录树元数据（文件名、大小、类型、修改时间）。
3. **本地内存映射（In-Memory FS）：** Daemon 需要在内存中维护一棵虚拟目录树。这样，当本地 Neovim 的文件浏览器（如 `neo-tree` 或 `nvim-tree`）请求读取目录内容时，Daemon 可以做到 **0 延迟的内存级响应**。
4. **远端事件监听（inotify/fsevents）：** 既然是项目，远端可能会有其他进程（比如 Git 切换分支、编译脚本生成文件）修改目录。你需要在远端注入一个极轻量的监听进程，一旦远端文件树发生变化，立刻通过长连接 Push 给本地 Daemon 更新缓存，并通知 Neovim 刷新文件树。

**达标标志：** 你可以在本地用 `nvim-tree` 丝滑地展开/折叠一个包含上万个文件的远程项目目录，且远端执行 `touch new_file` 时，本地文件树能瞬间自动出现该文件。

### Milestone 4：将重度计算卸载到远端 (Global Search & Telescope Integration)

项目管理中最高频的操作是**全局搜索（Grep）**和**文件查找（Find File）**。千万不要把所有文件拉到本地再搜索，这会撑爆网络带宽和内存。

**核心任务：**

1. **流式 RPC (Streaming RPC)：** 搜索结果可能成千上万，Daemon 和 Neovim 之间的通信必须支持流式传输，不能等所有结果集齐了再发，否则 UI 会卡死。
2. **远端执行与管道转发：** * 当在本地发起全局搜索时，Daemon 将请求转换为远端的 `rg` (ripgrep) 命令：`ssh user@host "rg --json 'pattern' /project/root"`。
* 远端的 `rg` 吐出每一行 JSON 结果，Daemon 实时解析、转换路径（将 `/project/root` 替换为 `remote://`），并通过 RPC 的 chunk 推送给本地 Neovim。


3. **Telescope / Fzf-lua 适配：** 在本地编写一个 Telescope 自定义 Picker。它的数据源（Finder）不再是本地进程，而是监听 Daemon 推送过来的流式数据。

**达标标志：** 按下快捷键，在本地 Telescope 的弹窗中输入关键字，远端大型项目的匹配结果能以极高的帧率如瀑布般刷出，选中结果敲击回车，瞬间打开该文件的 `remote://` 虚拟 Buffer。

### Milestone 5：项目级 LSP 代理与工作区同步 (Workspace LSP & 0-Delay Sync)

这是最终的 Boss 战。单文件的 LSP 比较容易骗，但项目级的 LSP（如 C++ 的 `clangd` 或 Rust 的 `rust-analyzer`）需要读取整个项目的依赖、配置文件（如 `compile_commands.json` 或 `Cargo.toml`）甚至进行全量索引。

**核心任务：**

1. **工作区根目录欺骗 (Workspace Root)：** 在拉起本地 LSP Client 时，通过 LSP 代理（你的 Daemon）将 `initialize` 请求中的 `rootUri` 动态转换为远端的工作区绝对路径。
2. **读写分离的极致优化：**
* **读（高亮/分析）：** 依然完全依赖远端的 LSP 进程。本地只负责渲染 `textDocument/publishDiagnostics` 发来的波浪线。
* **写（增量同步）：** 这是难点。你不仅要把本地修改的 Diff 发给远端保存，**还要同时将这个 Diff 封装成 `textDocument/didChange` 消息发给远端的 LSP 进程**，否则 LSP 脑子里的代码状态和实际文件状态就脱节了。


3. **交叉跳转处理：** 当你执行 `Go To Definition` (跳转到定义) 时，LSP 可能会返回一个远端系统库的路径（例如 `/usr/include/stdio.h`）。Daemon 必须识别出这个路径不在你的项目根目录内，并动态为其创建一个新的只读 `remote://` 挂载点，拉取过来供本地查看。

**达标标志：** 能够在本地拥有项目级的代码补全、重构（Rename 跨文件修改）、查找所有引用（Find References），且所有这些操作都感觉像是在本地 SSD 上处理一样流畅。

### Milestone 6：实现 0 延迟编辑与增量同步

现在文件能拉下来了，我们要处理“写”的问题。

**核心任务：**

1. **本地高亮：** 当 Buffer 加载完成后，根据文件后缀名，直接调用 `vim.treesitter.start()` 启用本地 Tree-sitter。这就完成了 0 延迟的语法高亮。
2. **监听修改：** 使用 `vim.api.nvim_buf_attach` 监听 Buffer 的变化。它的 `on_lines` 回调会告诉你“哪几行被删除了，新增了什么内容”。
3. **发送 Diff：** 不要全量保存！将这些行级的 Diff 变动通过 RPC 实时 Push 给 Daemon。
4. **远程 Patch：** Daemon 通过 SSH 隧道，在远程服务器上执行类似 `sed` 或自定义的脚本，将 Diff 实时应用到远程文件中。

**达标标志：** 本地敲击键盘丝滑无比（带有高亮），且远程文件的内容在你打字的同时被静默修改。

### Milestone 7：攻克最终 Boss —— LSP 路径劫持与代理

这是最难、也最有技术含量的一步。让本地的补全引擎（如 `nvim-cmp`）和 UI 完美渲染远程的诊断信息。

**核心任务：**

1. **启动代理：** 在 Lua 中调用 `vim.lsp.start()`，但 `cmd` 指向你的 Daemon，比如 `cmd = { 'my-daemon', 'lsp-proxy', '--server', 'user@host', '--lsp', 'clangd' }`。
2. **远程拉起：** Daemon 收到指令后，通过 SSH 在远程机器上拉起真正的 `clangd`。
3. **报文重写（核心）：** Daemon 拦截 Neovim 发给 `clangd` 的所有 JSON-RPC 消息。
* **拦截 Outbound：** 扫描 JSON，把 `uri: "remote://user@host/project/main.cpp"` 替换为 `uri: "file:///project/main.cpp"`，然后再通过 SSH 发给远程 `clangd`。
* **拦截 Inbound：** 远程 `clangd` 返回诊断错误（比如第 10 行缺分号），Daemon 拦截响应，把 `file:///project/main.cpp` 还原为 `remote://...`，再丢给本地 Neovim。



**达标标志：** 光标悬停时出现文档，输入 `->` 瞬间弹出补全列表，且代码写错时本地立即出现波浪线警告。
