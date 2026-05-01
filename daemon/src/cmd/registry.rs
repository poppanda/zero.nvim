// =============================================================================
// cmd/registry.rs — 流式命令的运行时注册表
// =============================================================================
// 持有所有正在跑的流式命令的句柄，供 cmd_cancel RPC 查询。
// session_id 由 Lua 端生成（uuid 或 vim.loop.now() 字符串），daemon 不解析它的语义。

use crate::cmd::cancel::CancelToken;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// 单个正在跑的流式命令的句柄
pub struct CmdHandle {
    pub session_id: String,
    pub cancel: CancelToken,
    /// 远端 PID。worker 线程在抓到 ZERO_PID: 行时填上；cancel 时读它发 kill。
    pub remote_pid: Arc<Mutex<Option<u32>>>,
}

impl CmdHandle {
    pub fn new(session_id: impl Into<String>) -> Self {
        Self {
            session_id: session_id.into(),
            cancel: CancelToken::new(),
            remote_pid: Arc::new(Mutex::new(None)),
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

    #[allow(dead_code)]
    pub fn len(&self) -> usize {
        self.inner.len()
    }
}
