// =============================================================================
// cmd — 通用远程命令执行基座
// =============================================================================
// 五段流水线：命令执行 → 数据采集 → 数据传输 → 下游解析 → 下游可视化
// 此 crate 是前两段（执行 + 采集）和第三段（传输）的发送端。
//
// 三档 API：
//   - exec_sync:   走 with_conn，复用已有会话；用于探针式短命令
//   - exec_stream: 专属 Session + non-blocking poll；用于流式长命令
//   - cancel:      通过 close + PidKill 升级关掉远端进程
//
// 模块组织：
//   spec.rs       - RemoteCommand / ConnTarget 数据结构
//   exec_sync.rs  - 同步执行
//   exec_stream.rs- 流式执行
//   batcher.rs    - 三阈值聚合
//   cancel.rs     - CancelToken + PidKill 升级
//   registry.rs   - running_commands HashMap 管理
//   dispatch.rs   - RPC handler 入口

pub mod batcher;
pub mod cancel;
pub mod dispatch;
pub mod exec_stream;
pub mod exec_sync;
pub mod registry;
pub mod spec;

pub use registry::CmdRegistry;

/// 命令产生的事件。统一类型给 sync / stream 共用：
///   - sync 路径会把同一次执行的多次 Stdout/Stderr 合并后再返回；
///   - stream 路径直接将事件发送给 sink（最终翻译为 RPC notification）。
#[derive(Debug, Clone)]
pub enum CommandEvent {
    /// 一段 stdout 字节（不保证按行）
    Stdout(Vec<u8>),
    /// 一段 stderr 字节
    Stderr(Vec<u8>),
    /// 命令正常结束
    Exit {
        code: i32,
        signal: Option<String>,
        duration_ms: u64,
    },
    /// 异常终止（cancel / timeout / 连接丢失）
    Aborted { reason: String },
}

impl CommandEvent {
    /// 事件 kind 名（用于 RPC 序列化）
    pub fn kind(&self) -> &'static str {
        match self {
            CommandEvent::Stdout(_) => "stdout",
            CommandEvent::Stderr(_) => "stderr",
            CommandEvent::Exit { .. } => "exit",
            CommandEvent::Aborted { .. } => "aborted",
        }
    }
}
