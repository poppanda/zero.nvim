// =============================================================================
// cmd/cancel.rs — Cancel token + 三档升级
// =============================================================================
// 取消语义：
//   1. 标记 token：worker 线程下一次 poll 前看到 → channel.close() + 退出循环
//   2. close 后 5s grace（在 exec_stream 退出前的 select 循环里）
//   3. 仍未结束 → 在另一条 channel 上 kill -TERM <remote_pid>；2s 后 KILL
// 远端 PID 通过命令包装的 stderr 头一行 "ZERO_PID:<n>" 提取。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

#[derive(Clone, Default)]
pub struct CancelToken {
    flag: Arc<AtomicBool>,
}

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.flag.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.flag.load(Ordering::Acquire)
    }
}

/// 解析 stderr 头一行 "ZERO_PID:<n>\n"，返回 (pid_opt, 剩余字节数从 stderr_buf 起的偏移)
///
/// 调用方应在 stream 循环刚开始捕获到 stderr 数据时调用一次。
pub fn try_extract_pid(stderr_buf: &[u8]) -> Option<(u32, usize)> {
    let prefix = b"ZERO_PID:";
    if !stderr_buf.starts_with(prefix) {
        return None;
    }
    let nl = stderr_buf.iter().position(|&b| b == b'\n')?;
    let pid_str = std::str::from_utf8(&stderr_buf[prefix.len()..nl]).ok()?;
    let pid: u32 = pid_str.trim().parse().ok()?;
    Some((pid, nl + 1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_default_not_cancelled() {
        let t = CancelToken::new();
        assert!(!t.is_cancelled());
    }

    #[test]
    fn token_cancel() {
        let t = CancelToken::new();
        let t2 = t.clone();
        t2.cancel();
        assert!(t.is_cancelled());
    }

    #[test]
    fn extract_pid_basic() {
        let buf = b"ZERO_PID:12345\nrest of stderr...";
        let (pid, off) = try_extract_pid(buf).unwrap();
        assert_eq!(pid, 12345);
        assert_eq!(off, 15);
    }

    #[test]
    fn extract_pid_missing() {
        assert!(try_extract_pid(b"some other stderr").is_none());
        assert!(try_extract_pid(b"ZERO_PID:notanumber\n").is_none());
        assert!(try_extract_pid(b"ZERO_PID:42").is_none()); // no newline yet
    }
}
