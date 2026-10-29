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
//
// 下游（dispatch.rs sink）把每个 chunk 解码成 UTF-8 字符串发给 Lua，所以阈值
// flush 时不能把一个多字节字符切成两半：末尾不完整的 UTF-8 序列留在缓冲里，
// 跟下一批一起发。只有 flush_all（EOF / cancel）才把残留原样冲出去。

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
        self.flush_with(Instant::now(), false)
    }

    fn flush_all_with_now(&mut self, now: Instant) -> Vec<CommandEvent> {
        self.flush_with(now, true)
    }

    fn flush_with(&mut self, now: Instant, keep_partial_utf8: bool) -> Vec<CommandEvent> {
        let mut out = Vec::with_capacity(2);
        if let Some(buf) = take_chunk(&mut self.stdout_buf, keep_partial_utf8) {
            out.push(CommandEvent::Stdout(buf));
            self.stdout_lines = 0;
        }
        if let Some(buf) = take_chunk(&mut self.stderr_buf, keep_partial_utf8) {
            out.push(CommandEvent::Stderr(buf));
        }
        self.last_flush = now;
        out
    }
}

/// 取出 buf 中可发送的部分；keep_partial_utf8 时把末尾不完整的 UTF-8 序列留在 buf 里
fn take_chunk(buf: &mut Vec<u8>, keep_partial_utf8: bool) -> Option<Vec<u8>> {
    if buf.is_empty() {
        return None;
    }
    let tail = if keep_partial_utf8 {
        incomplete_utf8_tail(buf)
    } else {
        0
    };
    if tail == buf.len() {
        return None;
    }
    let rest = buf.split_off(buf.len() - tail);
    Some(std::mem::replace(buf, rest))
}

/// 返回 buf 末尾"尚未完整"的 UTF-8 多字节序列的字节数（0..=3）。
/// 只检查最后 3 个字节：若找到一个前导字节且其声明的长度超出剩余字节，则这些
/// 字节需要等下一批数据补齐。非法字节（不可能补齐的）返回 0，交给 lossy 解码。
pub fn incomplete_utf8_tail(buf: &[u8]) -> usize {
    let len = buf.len();
    for i in 1..=len.min(3) {
        let b = buf[len - i];
        if b & 0b1100_0000 == 0b1000_0000 {
            continue; // continuation byte，继续往前找前导字节
        }
        let need = match b {
            0xC2..=0xDF => 2,
            0xE0..=0xEF => 3,
            0xF0..=0xF4 => 4,
            _ => return 0, // ASCII 或非法前导字节
        };
        return if need > i { i } else { 0 };
    }
    0
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
    fn incomplete_tail_detection() {
        assert_eq!(incomplete_utf8_tail(b"abc"), 0);
        assert_eq!(incomplete_utf8_tail("中".as_bytes()), 0);
        let zh = "中".as_bytes(); // E4 B8 AD
        assert_eq!(incomplete_utf8_tail(&zh[..1]), 1);
        assert_eq!(incomplete_utf8_tail(&zh[..2]), 2);
        let emoji = "😀".as_bytes(); // 4 bytes
        assert_eq!(incomplete_utf8_tail(&emoji[..3]), 3);
        assert_eq!(incomplete_utf8_tail(b"a\xff"), 0);
        assert_eq!(incomplete_utf8_tail(b""), 0);
    }

    #[test]
    fn threshold_flush_carries_partial_char() {
        let mut b = Batcher::with_thresholds(Duration::from_secs(60), 4, 1000);
        let s = "ab中文".as_bytes(); // 2 + 3 + 3 bytes
        b.feed_stdout(&s[..4]); // "ab" + first byte of 中
        let evs = b.flush_if_due();
        match &evs[..] {
            [CommandEvent::Stdout(v)] => assert_eq!(v, b"ab"),
            other => panic!("{:?}", other),
        }
        b.feed_stdout(&s[4..]);
        let evs = b.flush_if_due();
        match &evs[..] {
            [CommandEvent::Stdout(v)] => assert_eq!(std::str::from_utf8(v).unwrap(), "中文"),
            other => panic!("{:?}", other),
        }
    }

    #[test]
    fn flush_all_emits_partial_tail() {
        let mut b = Batcher::new();
        b.feed_stdout(&"中".as_bytes()[..2]);
        let evs = b.flush_all();
        match &evs[..] {
            [CommandEvent::Stdout(v)] => assert_eq!(v.len(), 2),
            other => panic!("{:?}", other),
        }
    }

    #[test]
    fn flush_all_empty() {
        let mut b = Batcher::new();
        assert!(b.flush_all().is_empty());
    }
}
