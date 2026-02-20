# LSP 代理调查状态 (LSP Proxy Investigation Status)

本文档总结了 `zero-nvim` 中远程语言服务器协议 (LSP) 代理集成的当前状态、进展以及遗留问题。

## 1. 代理架构概述 (Overview of the Proxy Architecture)

为了实现针对远程文件的零延迟本地编辑，并提供完整的 LSP 功能（悬停、诊断、跳转到定义等），`zero-nvim` 实现了一个本地 TCP-to-SSH 代理：

1. **Neovim (本地)**: 将标准的 LSP 客户端连接到本地的 TCP 套接字 (socket)。
2. **Rust 守护进程 (Daemon) (本地)**: 监听该 TCP 套接字。在后台线程中，它在 TCP 套接字和 `ssh` 子进程之间双向传输 (pump) 数据。
3. **载荷转换 (Payload Translation)**: 在传输数据时，守护进程会解析 LSP JSON-RPC 消息，并重写 `Content-Length` 请求头以及 JSON 载荷内的 URI：
   - Neovim → LSP: 将 `remote://user@host:port: /path` 转换为 `file:///path`。
   - LSP → Neovim: 将 `file:///path` 转换为 `remote://user@host:port:/path`。
4. **远程服务器**: 运行实际的语言服务器 (例如 `basedpyright-langserver --stdio`)。

## 2. 涉及的文件 (Files Involved)

*   **`daemon/src/lsp.rs`**: TCP-to-SSH 代理的 Rust 核心实现。它负责衍生 `ssh` 子进程、管理双向传输线程，以及执行 `pump_and_translate` 函数，该函数解析类似 HTTP 的请求头并重写 JSON 载荷。
*   **`lua/zero-nvim/lsp.lua`**: 评估 Neovim 缓冲区的 URI（`remote://` 或 `oil-zero://`），触发对守护进程的 `lsp_start` RPC 调用，并使用 `vim.lsp.start_client` 附加 Neovim 的 LSP 客户端。
*   **`lua/zero-nvim/init.lua`**: 注册 `:ZeroLspStart` 命令。它还处理连接状态 (`ensure_connection`)、异步扫描远程 `~/.local/share/nvim/mason/bin` 目录，并缓存这些二进制文件，以便为 `:ZeroLspStart` 命令提供丰富的自动补全功能。

## 3. 已解决的问题 (Recently Resolved Issues)

*   **并发损坏 (libssh2)**: 最初，使用 `libssh2` crate 通道进行 stdin/stdout 的操作导致了在两个线程并发访问时发生数据竞争。这通过使用 `std::process::Command` 衍生系统的 `ssh` 进程来修复，从而提供了线程安全的操作系统级管道。
*   **PATH & 二进制解析**: 非交互式 SSH shell 不会加载 `~/.profile` 或 `~/.zshrc`，这导致通过 Mason 安装的工具出现“找不到命令 (command not found)” 错误。通过在 SSH 命令前缀中注入 `PATH=$HOME/.local/share/nvim/mason/bin:$PATH` 解决了这个问题。
*   **客户端去重 Hack (Client Deduplication Hack)**: Neovim 的高层级 API `vim.lsp.start` 会根据名称对客户端进行去重。如果客户端崩溃，再次调用它只会返回死掉客户端的 ID，*而不会*重新建立到守护进程端口的 TCP 连接。通过采用底层 API `vim.lsp.start_client` 修复了此问题，该 API 强制每次都建立新连接。
*   **缺失 `--stdio` 标志**: 像 `basedpyright-langserver` 这样的语言服务器必须使用 `--stdio` 标志调用，以便通过标准流进行通信。
*   **URI 格式错误**: Neovim 端的 `vim.uri_from_fname` 曾会将 `remote://` 处理成错误的 `file://remote://...` 从而引发 `ENOENT` 错误。现已在 `lsp.lua` 中修复，解析出绝对路径。

## 4. 2026-02-21 最终修复总结 (Final Fix Summary)

### 症状 (Symptoms)
1.  **LSP 进程崩溃 (Exit Code 1)**: `basedpyright` 启动后完成握手，但在发送 `hover` 或 `semanticTokens` 请求后立即崩溃，导致 Daemon 报告 `SSH process exited with status: 256` 和 `Broken pipe`。
2.  **LSP 请求超时 (Timeout)**: 在修复崩溃后，LSP 进程存活但对 `hover` 等文件请求没有任何响应，导致 Neovim 端超时。

### 根因分析 (Root Cause Analysis)

1.  **崩溃原因**: `processId` 校验失败。
    -   Neovim 默认在 `initialize` 请求中发送本地进程 ID (`processId: <local_pid>`)。
    -   `basedpyright` (以及许多其他 LSP) 会检查父进程是否存活。由于它运行在远程服务器上，本地 PID 在远程通常不存在（或对应无关进程）。
    -   当 `basedpyright` 无法验证父进程时，它选择立即自杀以释放资源。
    -   **修复**: 在 `vim.lsp.start_client` 的 `before_init` 钩子中强制设置 `params.processId = vim.NIL` (即 JSON `null`)，告知服务器不要检查父进程。

2.  **超时原因**: Python 环境未配置。
    -   `basedpyright` 需要知道 Python 解释器的路径才能解析标准库和 import。
    -   在远程环境中（特别是 Mason 安装的环境），默认可能无法正确推断系统 Python 路径，或者需要显式指定。
    -   当缺少 `pythonPath` 时，`basedpyright` 的分析线程似乎陷入了死锁或无限等待，导致无法响应 `hover` 请求（尽管它能响应不需要分析的 `shutdown` 请求）。
    -   **修复**: 在启动 LSP 时显式传入 `settings = { python = { pythonPath = "/usr/bin/python3" } }`（或对应的远程 Python 路径）。

3.  **URI 翻译完善**:
    -   Daemon 实现了鲁棒的 URI 翻译，支持 `file://remote://` 等畸形前缀的剥离。
    -   验证确认 `lua-language-server` 和 `basedpyright` 都能正确处理翻译后的 URI。

### 实施的变更 (Implemented Changes)

1.  **`lua/zero-nvim/lsp.lua`**:
    -   `start_lsp` 函数现在接受 `settings` 参数，允许传递服务器特定的配置（如 `pythonPath`）。
    -   添加了 `before_init` 钩子，强制设置 `params.processId = vim.NIL`。
    -   增强了 `capabilities` 处理，禁用了 `workspace.didChangeWatchedFiles.dynamicRegistration`，防止服务器发送不必要的 `client/registerCapability` 请求（虽然 Neovim 能处理，但远程文件监控通常不支持或开销大）。

2.  **`daemon/src/lsp.rs`**:
    -   保持了现有的多重 URI 前缀剥离逻辑，确保发送给服务器的 URI 始终是干净的 `file:///path`。

### 验证 (Verification)
-   **`lua-language-server`**: 成功在远程 `test.lua` 上运行，`hover` 响应正确。
-   **`basedpyright`**: 在配置了正确的 `pythonPath` 后，成功在远程 `api-test.py` 上运行，`hover` 响应正确，`semanticTokens` 正常工作，且不再崩溃。

### 下一步 (Next Steps)
-   在 `zero-nvim` 的用户配置中提供一种机制，允许用户为不同的 LSP 服务器指定特定的 `settings`（例如远程 Python 路径）。
-   考虑自动探测远程 Python 路径（例如通过 `ssh ... which python3`）。
