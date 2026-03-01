# ZeroNvim 连接与传输性能优化方案

本文档总结了 `zero-nvim` 在远程文件系统操作与数据传输中的性能瓶颈，并提出了针对性的深层优化方案与实现思路。我们的目标是将远程文件读取、LSP 跳转和文件浏览的延迟降至物理 Ping 值的理论极限。

## 当前架构痛点分析

在目前版本的架构中，虽然实现了复用长连接 (TCP & SSH 握手)，但依然存在以下限制：

1. **同步阻塞导致的 UI 冻结**
   Neovim 前端广泛使用 `vim.fn.rpcrequest` 发起同步 RPC 调用。当 LSP 触发诸如 `references` 或 `definition` 跳转时，可能涉及多个文件的预加载。如果是串行同步读取，延迟会随着文件数量呈线性放大（`O(N * RTT)`），导致界面出现可感知的明显冻结。

2. **SSH Channel 的高频创建与销毁**
   即便放弃了笨重的 SFTP，转而使用 `SSH Exec Channel`，每次操作依然需要向服务端申请新的 Channel，并在操作结束后回收。这一分配过程本身就包含了一次网络往返交互。

3. **缺乏大文件与流式数据管控**
   对于极大的文件或编译日志，直接拉取全部数据会打满 SSH 通道，并对后端内存与 Neovim Msgpack 序列化/反序列化机制造成极大压力，容易引发 OOM 崩溃或严重假死。

4. **缓存利用率低**
   在搜索和导航时，许多即将被预览的文件其实是可以预见的，但目前的机制完全基于触发式惰性加载（Lazy Load），没有进行前置预热（Pre-warm）。

---

## 进一步优化实现方案

以下方案按对最终用户体验提升的优先级从高到低排列。

### 1. 批量与异步预加载 (Batch & Async Loading)
**解决的问题：** LSP 跳转和项目范围内跨文件搜索时的串行高延迟阻塞。

*   **思路**：
    将涉及多个文件的 RPC 请求合并为单个 `fetch_paths` 批量接口；并从前端剥离阻塞逻辑，对非强一致性要求的文件预览采用异步加载机制（Coroutine / Callback）。
*   **代码改动方向**：
    *   **Rust (Daemon)**：新增 `handle_fetch_paths(paths: Vec<String>)`。遍历传入的路径并启动多线程并发执行读取（或在单线程异步中并发调度），将结果聚合成 `HashMap<String, FileData>` 形式返回。
    *   **Lua (Neovim)**：在 `init.lua` 修改 `locations_to_items` 的钩子逻辑。在收到 LSP 结果的多个 URI 后，收集所有未加载的内容，一次性发送给 Daemon，而非在 for 循环中分别 `handle_fetch`。

### 2. 驻留持久化 Shell 通道 (Persistent PTY Shell)
**解决的问题：** `exec` 开启子 Channel 时的隐性握手延迟。

*   **思路**：
    在 Daemon 建立基础连接通过身份认证后，立刻请求开启一个带 PTY 的持续性 Shell（如 `bash --noprofile --norc`）或者长周期的标准输入输出流（Raw Stdio Shell）。所有文件读取指令都通过 `stdin` 发送至该通道，利用特定的字符串标记边界（Boundary Markers / EOF Markers）来截断并解析 `stdout` 的返回结果。
*   **代码改动方向**：
    *   **Rust (Daemon)**：在 `state.rs` 中重构 `Session` 管理结构。增加一个封装好的 `PersistentShell` 结构体，内部持有 `sess.channel_session().pty(...)` 对象和读写锁。
    *   发送指令形如：`cat /path/to/file; echo "\n__ZERO_EOF_MARKER__"`。
    *   **环境需求**：需应对目标服务器环境中可能的干扰输出（如 Motd、全局 `.bashrc` 中的异常打印），因此必须使用受限的或特定的 Shell 模式运行。

### 3. 大文件保护与分页截断传输 (Lazy/Chunked Loading)
**解决的问题：** 读取 GB 级别日志和核心转储文件时导致的插件奔溃。

*   **思路**：
    每次读取文件前进行尺寸探查，拦截超过安全阈值（如 2MB）的文件。强制退化为头部截断读取（`head -c 2M`），并在 Neovim UI 中注入特殊提示层，允许用户按需展开后续分片。
*   **代码改动方向**：
    *   **Rust (Daemon)**：调整命令组装：
        `size=$(stat -c%s "$path"); if [ $size -gt 2097152 ]; then echo "TRUNCATED"; head -c 2097152 "$path"; else ... fi`
    *   **Lua (Neovim)**：若检测到 `TRUNCATED` 标识，不仅载入截断的行，还需动态绑定一个自动命令（Autocmd）在文件末尾提示：“[文件已截断，按下 `<CR>` 加载剩余内容]”。

### 4. 搜索时的后台缓存预热 (Background Cache Pre-warming)
**解决的问题：** 提高 Telescope 等工具中滚动预览列表时的响应帧率。

*   **思路**：
    当我们在全局搜索文件内容或文件名并获得命中的文件列表后，利用搜索返回等待用户操作的空闲时间，静默触发后端异步拉取前 10~20 个热门结果文件的内容进入内存。
*   **代码改动方向**：
    *   **Rust (Daemon)**：增加 `prewarm_cache` 接口，接收一批文件路径，并开启后台非阻塞线程去缓存这些文件到 `DaemonState.caches`。
    *   **Lua (Neovim)**：在 `search.lua` 中修改 `Telescope` 或自定义 Picker 的数据回调钩子。在列表呈现出来的第一帧，向守护进程发送 `rpcnotify`（异步非阻塞），让守护进程悄悄干活。

---

## 实施阶段建议

目前该项目基于 `zero-nvim` 与独立 Rust `daemon` 的双边通信机制已经跑通。要实现下一阶段的体验飞跃：

1. **短期优先**：实现第一项 **“批量与异步预加载”**，这几乎能立刻根治 LSP 跨文件跳转时的明显死锁痛点，且技术风险极低。
2. **中期探索**：实现第三项大文件保护逻辑，这是生产环境稳健运行的基础。
3. **长期打磨**：对第二项（持久化 Shell）进行灰度实验，由于涉及复杂的远程环境兼容性处理，可能需要较长的调优期。