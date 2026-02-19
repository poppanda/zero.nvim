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

### Milestone 3：实现 0 延迟编辑与增量同步

现在文件能拉下来了，我们要处理“写”的问题。

**核心任务：**

1. **本地高亮：** 当 Buffer 加载完成后，根据文件后缀名，直接调用 `vim.treesitter.start()` 启用本地 Tree-sitter。这就完成了 0 延迟的语法高亮。
2. **监听修改：** 使用 `vim.api.nvim_buf_attach` 监听 Buffer 的变化。它的 `on_lines` 回调会告诉你“哪几行被删除了，新增了什么内容”。
3. **发送 Diff：** 不要全量保存！将这些行级的 Diff 变动通过 RPC 实时 Push 给 Daemon。
4. **远程 Patch：** Daemon 通过 SSH 隧道，在远程服务器上执行类似 `sed` 或自定义的脚本，将 Diff 实时应用到远程文件中。

**达标标志：** 本地敲击键盘丝滑无比（带有高亮），且远程文件的内容在你打字的同时被静默修改。

### Milestone 4：攻克最终 Boss —— LSP 路径劫持与代理

这是最难、也最有技术含量的一步。让本地的补全引擎（如 `nvim-cmp`）和 UI 完美渲染远程的诊断信息。

**核心任务：**

1. **启动代理：** 在 Lua 中调用 `vim.lsp.start()`，但 `cmd` 指向你的 Daemon，比如 `cmd = { 'my-daemon', 'lsp-proxy', '--server', 'user@host', '--lsp', 'clangd' }`。
2. **远程拉起：** Daemon 收到指令后，通过 SSH 在远程机器上拉起真正的 `clangd`。
3. **报文重写（核心）：** Daemon 拦截 Neovim 发给 `clangd` 的所有 JSON-RPC 消息。
* **拦截 Outbound：** 扫描 JSON，把 `uri: "remote://user@host/project/main.cpp"` 替换为 `uri: "file:///project/main.cpp"`，然后再通过 SSH 发给远程 `clangd`。
* **拦截 Inbound：** 远程 `clangd` 返回诊断错误（比如第 10 行缺分号），Daemon 拦截响应，把 `file:///project/main.cpp` 还原为 `remote://...`，再丢给本地 Neovim。



**达标标志：** 光标悬停时出现文档，输入 `->` 瞬间弹出补全列表，且代码写错时本地立即出现波浪线警告。
