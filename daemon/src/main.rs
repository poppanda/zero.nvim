// =============================================================================
// zero-nvim daemon — 入口
// =============================================================================
// 通过 stdin/stdout Msgpack-RPC 与 Neovim 通信。模块：
//   - rpc:        消息收发、参数解析、方法分发表
//   - state:      全局状态（连接目标、目录缓存）
//   - session:    SSH 会话池（共享 SFTP 会话 + 流式命令会话池）与远程 exec
//   - connect:    SSH 建连与认证
//   - fs:         远程文件系统操作（读/写/目录/扫描）
//   - cmd:        通用远程命令（同步 / 流式 / 取消）
//   - lsp:        LSP 代理（系统 ssh 子进程）
//   - ssh_config: ~/.ssh/config 查询

// 路由日志：stderr 在 Neovim 侧会显示成 WARN 通知，所以常规信息只在设置了
// ZERO_NVIM_DEBUG 环境变量时输出；真正的错误仍直接 eprintln!。
macro_rules! debug_log {
    ($($arg:tt)*) => {
        if $crate::debug_enabled() {
            eprintln!($($arg)*);
        }
    };
}

mod cmd;
mod connect;
mod fs;
mod lsp;
mod rpc;
mod session;
mod ssh_config;
mod state;

use std::sync::{Arc, Mutex, OnceLock};

/// 是否输出调试日志（ZERO_NVIM_DEBUG 非空且不为 "0"）
pub(crate) fn debug_enabled() -> bool {
    static FLAG: OnceLock<bool> = OnceLock::new();
    *FLAG.get_or_init(|| {
        std::env::var("ZERO_NVIM_DEBUG")
            .map(|v| !v.is_empty() && v != "0")
            .unwrap_or(false)
    })
}

fn main() {
    rpc::serve(Arc::new(Mutex::new(state::DaemonState::new())));
}
