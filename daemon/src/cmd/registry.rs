// =============================================================================
// cmd/registry.rs — 流式命令的运行时注册表
// =============================================================================
// 持有所有正在跑的流式命令的句柄，供 cmd_cancel / cmd_stdin_* RPC 查询。
// session_id 由 Lua 端生成（uuid 或 vim.loop.now() 字符串），daemon 不解析它的语义。

use crate::cmd::cancel::CancelToken;
use std::collections::HashMap;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};

/// stdin 消息：Write(bytes) 或 Close（发 send_eof）。
/// worker 线程通过 mpsc::Receiver 拉取，在主 poll 循环里逐块写入 channel。
pub enum StdinMsg {
    Write(Vec<u8>),
    Close,
}

/// 单个正在跑的流式命令的句柄
pub struct CmdHandle {
    pub session_id: String,
    pub cancel: CancelToken,
    /// 远端 PID。worker 线程在抓到 ZERO_PID: 行时填上；cancel 时读它发 kill。
    pub remote_pid: Arc<Mutex<Option<u32>>>,
    /// stdin 增量写入通道。worker 启动时填上；外部 RPC 通过它推数据/关闭。
    /// 命令结束后 worker 把 sender drop 掉（rx end），后续 send 会得到 SendError 静默忽略。
    pub stdin_tx: Mutex<Option<mpsc::Sender<StdinMsg>>>,
}

impl CmdHandle {
    pub fn new(session_id: impl Into<String>) -> Self {
        Self {
            session_id: session_id.into(),
            cancel: CancelToken::new(),
            remote_pid: Arc::new(Mutex::new(None)),
            stdin_tx: Mutex::new(None),
        }
    }

    /// 推一段字节给 worker 写入 stdin。返回 false 表示通道已关闭/未就绪。
    pub fn send_stdin(&self, data: Vec<u8>) -> bool {
        let g = self.stdin_tx.lock().unwrap();
        if let Some(tx) = g.as_ref() {
            tx.send(StdinMsg::Write(data)).is_ok()
        } else {
            false
        }
    }

    /// 通知 worker 把 stdin 关掉（send_eof）。返回 false 表示通道已关闭/未就绪。
    pub fn close_stdin(&self) -> bool {
        let g = self.stdin_tx.lock().unwrap();
        if let Some(tx) = g.as_ref() {
            tx.send(StdinMsg::Close).is_ok()
        } else {
            false
        }
    }
}

/// 注册表 = session_id → 句柄
#[derive(Default)]
pub struct CmdRegistry {
    inner: HashMap<String, Arc<CmdHandle>>,
}

impl CmdRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn insert(&mut self, h: Arc<CmdHandle>) {
        self.inner.insert(h.session_id.clone(), h);
    }

    pub fn get(&self, sid: &str) -> Option<Arc<CmdHandle>> {
        self.inner.get(sid).cloned()
    }

    pub fn remove(&mut self, sid: &str) -> Option<Arc<CmdHandle>> {
        self.inner.remove(sid)
    }
}
