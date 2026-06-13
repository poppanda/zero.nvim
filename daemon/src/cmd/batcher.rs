// =============================================================================
// cmd/batcher.rs — 三阈值聚合
// =============================================================================
// 把零碎的 stdout / stderr 字节聚合成 chunk 再推给 sink。
// 触发 flush 的条件（任一）：
//   - 时间窗 ≥ TIME_THRESHOLD（默认 80ms）
//   - 任一通道累计字节 ≥ BYTE_THRESHOLD（默认 16 KiB）
//   - stdout 累计行数 ≥ LINE_THRESHOLD（默认 200 行）
//   - 显式 flush_all (EOF / cancel)
//
// stdout / stderr 是分开两个缓冲，flush 时分别发出 CommandEvent::Stdout / Stderr。

use crate::cmd::CommandEvent;
use std::time::{Duration, Instant};

pub const TIME_THRESHOLD: Duration = Duration::from_millis(80);
pub const BYTE_THRESHOLD: usize = 16 * 1024;
pub const LINE_THRESHOLD: usize = 200;

pub struct Batcher {
    stdout_buf: Vec<u8>,
    stderr_buf: Vec<u8>,
    stdout_lines: usize,
    last_flush: Instant,
    time_threshold: Duration,
    byte_threshold: usize,
    line_threshold: usize,
}

impl Default for Batcher {
    fn default() -> Self {
        Self::new()
    }
}

impl Batcher {
    pub fn new() -> Self {
        Self {
            stdout_buf: Vec::with_capacity(BYTE_THRESHOLD),
            stderr_buf: Vec::with_capacity(4 * 1024),
            stdout_lines: 0,
            last_flush: Instant::now(),
            time_threshold: TIME_THRESHOLD,
            byte_threshold: BYTE_THRESHOLD,
            line_threshold: LINE_THRESHOLD,
        }
    }

    /// 主要给测试用——允许覆盖阈值
    #[cfg(test)]
    pub fn with_thresholds(time: Duration, bytes: usize, lines: usize) -> Self {
        Self {
            stdout_buf: Vec::new(),
            stderr_buf: Vec::new(),
            stdout_lines: 0,
            last_flush: Instant::now(),
            time_threshold: time,
            byte_threshold: bytes,
            line_threshold: lines,
        }
    }

    pub fn feed_stdout(&mut self, data: &[u8]) {
        if data.is_empty() {
            return;
        }
        self.stdout_lines += data.iter().filter(|&&b| b == b'\n').count();
        self.stdout_buf.extend_from_slice(data);
    }

    pub fn feed_stderr(&mut self, data: &[u8]) {
        if data.is_empty() {
            return;
        }
        self.stderr_buf.extend_from_slice(data);
    }

    /// 检查并按阈值 flush；返回应当下发的事件序列（可能为空）
    pub fn flush_if_due(&mut self) -> Vec<CommandEvent> {
        let now = Instant::now();
        let time_due = now.duration_since(self.last_flush) >= self.time_threshold;
        let bytes_due = self.stdout_buf.len() >= self.byte_threshold
            || self.stderr_buf.len() >= self.byte_threshold;
        let lines_due = self.stdout_lines >= self.line_threshold;

        if time_due || bytes_due || lines_due {
            self.flush_all_with_now(now)
        } else {
            Vec::new()
        }
    }

    /// 强制 flush 所有缓冲（用于 EOF / cancel）
    pub fn flush_all(&mut self) -> Vec<CommandEvent> {
        self.flush_all_with_now(Instant::now())
    }

    fn flush_all_with_now(&mut self, now: Instant) -> Vec<CommandEvent> {
        let mut out = Vec::with_capacity(2);
        if !self.stdout_buf.is_empty() {
            let buf = std::mem::take(&mut self.stdout_buf);
            out.push(CommandEvent::Stdout(buf));
            self.stdout_lines = 0;
        }
        if !self.stderr_buf.is_empty() {
            let buf = std::mem::take(&mut self.stderr_buf);
            out.push(CommandEvent::Stderr(buf));
        }
        self.last_flush = now;
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flush_on_byte_threshold() {
        let mut b = Batcher::with_thresholds(Duration::from_secs(60), 10, 1000);
        b.feed_stdout(b"123456789");
        assert!(b.flush_if_due().is_empty());
        b.feed_stdout(b"x"); // hits 10
        let evs = b.flush_if_due();
        assert_eq!(evs.len(), 1);
        match &evs[0] {
            CommandEvent::Stdout(v) => assert_eq!(v.len(), 10),
            _ => panic!(),
        }
    }

    #[test]
    fn flush_on_line_threshold() {
        let mut b = Batcher::with_thresholds(Duration::from_secs(60), 10_000, 3);
        b.feed_stdout(b"a\n");
        b.feed_stdout(b"b\n");
        assert!(b.flush_if_due().is_empty());
        b.feed_stdout(b"c\n"); // 3 lines
        let evs = b.flush_if_due();
        assert_eq!(evs.len(), 1);
    }

    #[test]
    fn flush_separates_streams() {
        let mut b = Batcher::with_thresholds(Duration::from_secs(0), 10_000, 1000);
        b.feed_stdout(b"out");
        b.feed_stderr(b"err");
        std::thread::sleep(Duration::from_millis(5));
        let evs = b.flush_if_due();
        assert_eq!(evs.len(), 2);
        let kinds: Vec<_> = evs.iter().map(|e| e.kind()).collect();
        assert!(kinds.contains(&"stdout"));
        assert!(kinds.contains(&"stderr"));
    }

    #[test]
    fn flush_all_empty() {
        let mut b = Batcher::new();
        assert!(b.flush_all().is_empty());
    }
}
