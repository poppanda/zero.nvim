# Milestone 7: 零延迟编辑与增量同步 (Zero Latency & Sync) - 实现方案

## 一、 核心目标与痛点分析

在远程开发中，由于物理网络 RTT (往返时间) 的存在，全量文件保存往往会带来明显的界面卡顿（即便是在优化了 SSH Channel 之后）。Milestone 7 的目标是**彻底消除用户对网络延迟的感知**，实现：
1. **乐观 UI 更新 (Optimistic UI)**：保存动作瞬间完成，UI 不发生任何阻塞。
2. **增量/差异传输 (Delta Sync)**：只通过慢速 SSH 网络发送变动部分的 Diff，而不是每次都全量覆写文件，大幅降低带宽占用。
3. **冲突处理**：防止后台异步写入时发生数据覆盖。

## 二、 架构设计与核心机制

### 1. 前端：非阻塞异步保存 (Optimistic Save)
**现状**：Neovim 的 `BufWriteCmd` 中调用了 `vim.fn.rpcrequest` (同步阻塞 RPC)。
**重构方向**：
*   用户触发 `:w` 时，Neovim 立刻调用 `vim.rpcnotify`（非阻塞）将全量文件数据（通过本地极速 TCP）发送给 Rust Daemon。
*   Neovim 侧直接通过 `vim.bo.modified = false` 消除修改标记，给用户“秒存”的乐观反馈。
*   如果守护进程在后台保存失败（如网络中断），Daemon 会主动向 Neovim 发送一个 `notify` 事件。Neovim 接收到后，弹出错误提示，并重新将 buffer 置为 `modified = true`。

### 2. 后端：Diff 差异计算与轻量推送 (Incremental Diff Sync)
**现状**：每次保存都在 SSH 上执行一次极耗带宽的全量内容传输。
**重构方向**：
*   **内存快照**：Rust Daemon 在每次 `fetch_path` 或完成一次完整写入后，将该文件的完整内容缓存在内存状态中 (`DaemonState.file_caches`)。
*   **计算 Diff**：当 Daemon 收到 Neovim 发来的最新全量文本时，利用 Rust 高效的文本差异计算库（如 `similar` crate），将其与内存中的旧快照比对，生成一个标准的 Unified Diff。
*   **远程 Patch**：Daemon 在已有的持久化 SSH 连接上执行一条极短的命令，例如：
    `echo "<diff_string>" | patch -u /path/to/remote_file`
    这样一来，对于一个几万行的大文件，只需发送几十个字节的网络流量。
*   **智能降级**：如果判断出目标机器上没有 `patch` 命令，或是第一次建立远程文件，或是 Diff 失败，则无缝回退到使用原有的 Exec Channel 方案进行全量覆写。

### 3. 后端：基于 Mtime 的简易冲突检测
*   在拉取文件或写入时，记录文件在远端的 `mtime` (Last Modified Time) 和文件大小。
*   在执行后台 Patch/Write 之前，可以使用简短的脚本 `[ "$(stat -c %Y /path/to/file)" == "<cached_mtime>" ]` 做一次前置校验。
*   如果条件不符，说明远端文件已被其他人或进程修改，终止覆盖操作并通知 Neovim 弹出冲突解决提示。

## 三、 实施步骤拆解

### Step 1: 引入 Diff 引擎与状态维护
*   修改 `daemon/Cargo.toml`，引入 `similar` crate。
*   扩展 `DaemonState` 结构体，增加专门用于存储已打开文件最后同步状态的哈希表（包括文件内容 String 与记录的 mtime）。
*   修改 `handle_fetch_path`，在返回文件内容前，顺便将其存入缓存。

### Step 2: 后端混合写入引擎的实现
*   新增 `fs::handle_write_file_async`。
*   实现差异判定逻辑：
    1.  提取内存中的旧缓存。
    2.  若有缓存，生成 Diff。若 Diff 为空，直接返回成功。
    3.  拼接 shell 脚本：尝试使用 `patch` 工具应用增量修改；如果命令失败返回特定错误码，则再次调用全量覆盖流。
    4.  更新内存缓存。

### Step 3: 前端 Optimistic UI 与事件监听
*   在 `lua/zero-nvim/init.lua` 中修改 `BufWriteCmd` 钩子，移除阻塞的 `rpcrequest`，换成异步 `rpcnotify`。
*   在 Neovim 的入口注册一个用于接收 Daemon 回调的 RPC handler（如监听 `save_error` 和 `conflict_detected`），处理 UI 的状态回滚与弹窗告警。

## 四、 结论

通过上述方案，最慢的网络 I/O 将完全转移至 Rust Daemon 的后台线程中执行，且传输量将缩减 90% 以上。用户的编辑与保存体验将达到与本地几乎无异的境界，完美达成 Milestone 7 的要求。