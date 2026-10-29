// =============================================================================
// cmd/stream.rs — 流式命令执行
// =============================================================================
// 长跑命令（搜索 / git diff / docker logs）走这里。
//
// 关键设计：
//   * 每条流式命令从 exec 池**取走**一个 Session 独占（见 session.rs），结束后归还。
//   * 单个 worker 线程内部：blocking exec → 切到 non-blocking 后 poll。libssh2 不是
//     线程安全的，所以 stdout / stderr / stdin 都在同一线程里交错读写。
//   * stderr（pty 模式下是 stdout）头一行解析 "ZERO_PID:<n>"（由 spec.rs 的 PID
//     包装打出），cancel 升级时用。
//   * cancel 三档升级：close channel（远端 SIGPIPE）→ 3s grace → kill -TERM → 2s →
//     kill -KILL。TERM/KILL 打整个进程组，在后台线程经共享会话发出，不延迟 Aborted 事件。
//
// 通知格式（daemon → Lua）：
//   [2, "nvim_exec_lua", ["require('zero-nvim.cmd.exec')._dispatch(...)", [session_id, kind, payload]]]
// payload 按 kind：
//   "stdout" / "stderr" → String（lossy UTF-8，见 cmd::lossy）
//   "exit"              → [code, signal_or_nil, duration_ms]
//   "aborted"           → String(reason)

use super::batcher::Batcher;
use super::lossy;
use super::spec::RemoteCommand;
use crate::connect::open_dedicated_session;
use crate::rpc::Outbox;
use crate::session::{
    exec_pool_clear, exec_pool_put, exec_pool_take, exec_shared, is_session_dead, is_would_block,
    DEFAULT_TIMEOUT_MS, EAGAIN,
};
use crate::state::{LockExt, SharedState, Target};
use anyhow::Context;
use rmpv::Value;
use ssh2::{Channel, Session};
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::{Duration, Instant};

/// cancel 后等远端自然退出（SIGPIPE）的宽限期
const CANCEL_GRACE: Duration = Duration::from_secs(3);
/// TERM 之后到 KILL 的间隔
const TERM_TO_KILL: Duration = Duration::from_secs(2);

/// 命令产生的事件
#[derive(Debug)]
pub enum CommandEvent {
    /// 一段 stdout 字节（不保证按行）
    Stdout(Vec<u8>),
    Stderr(Vec<u8>),
    /// 命令正常结束
    Exit {
        code: i32,
        signal: Option<String>,
        duration_ms: u64,
    },
    /// 异常终止（cancel / 连接丢失等）
    Aborted(String),
}

impl CommandEvent {
    pub fn kind(&self) -> &'static str {
        match self {
            CommandEvent::Stdout(_) => "stdout",
            CommandEvent::Stderr(_) => "stderr",
            CommandEvent::Exit { .. } => "exit",
            CommandEvent::Aborted(_) => "aborted",
        }
    }

    fn into_notification(self, sid: &str) -> Value {
        let kind = self.kind();
        let payload = match self {
            CommandEvent::Stdout(b) | CommandEvent::Stderr(b) => lossy(&b),
            CommandEvent::Exit {
                code,
                signal,
                duration_ms,
            } => Value::Array(vec![
                Value::from(code),
                signal.map_or(Value::Nil, Value::from),
                Value::from(duration_ms),
            ]),
            CommandEvent::Aborted(reason) => Value::from(reason),
        };
        Value::Array(vec![
            Value::from(2),
            Value::from("nvim_exec_lua"),
            Value::Array(vec![
                Value::from("require('zero-nvim.cmd.exec')._dispatch(...)"),
                Value::Array(vec![Value::from(sid), Value::from(kind), payload]),
            ]),
        ])
    }
}

/// 增量 stdin 消息（cmd_stdin_write / cmd_stdin_close）
pub enum StdinMsg {
    Write(Vec<u8>),
    Close,
}

/// 正在跑的流式命令的句柄，存在 state.commands 里供 cancel / stdin RPC 查询。
/// worker 结束后 stdin 的接收端被 drop，之后的 send 失败（静默忽略）。
pub struct CmdHandle {
    cancelled: AtomicBool,
    stdin_tx: mpsc::Sender<StdinMsg>,
}

impl CmdHandle {
    pub fn new() -> (Arc<Self>, mpsc::Receiver<StdinMsg>) {
        let (stdin_tx, stdin_rx) = mpsc::channel();
        let handle = Self {
            cancelled: AtomicBool::new(false),
            stdin_tx,
        };
        (Arc::new(handle), stdin_rx)
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }

    fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    /// 返回 false 表示 worker 已结束
    pub fn send_stdin(&self, data: Vec<u8>) -> bool {
        self.stdin_tx.send(StdinMsg::Write(data)).is_ok()
    }

    pub fn close_stdin(&self) -> bool {
        self.stdin_tx.send(StdinMsg::Close).is_ok()
    }
}

struct Worker {
    sid: String,
    t: Target,
    cmd: RemoteCommand,
    handle: Arc<CmdHandle>,
    stdin_rx: mpsc::Receiver<StdinMsg>,
    state: SharedState,
    tx: Outbox,
}

/// 起 worker 线程执行命令；SSH 握手也在 worker 里做，不阻塞 RPC 主循环。
pub fn spawn(
    sid: String,
    t: Target,
    cmd: RemoteCommand,
    handle: Arc<CmdHandle>,
    stdin_rx: mpsc::Receiver<StdinMsg>,
    state: SharedState,
    tx: Outbox,
) {
    let w = Worker {
        sid,
        t,
        cmd,
        handle,
        stdin_rx,
        state,
        tx,
    };
    thread::spawn(move || {
        let start = Instant::now();
        let result = w.run();
        let cancelled = w.handle.is_cancelled();
        w.emit(match result {
            Ok((code, _)) if cancelled => {
                CommandEvent::Aborted(format!("cancelled (exit={})", code))
            }
            Ok((code, signal)) => CommandEvent::Exit {
                code,
                signal,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Err(e) if cancelled => CommandEvent::Aborted(format!("cancelled: {}", e)),
            Err(e) => CommandEvent::Aborted(format!("{:#}", e)),
        });
        // 从注册表移除自己（同 sid 已被新命令占用时不动）
        let mut st = w.state.lock_ok();
        if st
            .commands
            .get(&w.sid)
            .is_some_and(|h| Arc::ptr_eq(h, &w.handle))
        {
            st.commands.remove(&w.sid);
        }
    });
}

enum OpenError {
    /// exec 请求发出前失败：远端没有执行任何东西，可重试
    BeforeExec(anyhow::Error),
    /// exec 之后失败：不可重试
    AfterExec(anyhow::Error),
}

impl Worker {
    fn emit(&self, ev: CommandEvent) {
        let _ = self.tx.send(ev.into_notification(&self.sid));
    }

    fn check_cancelled(&self) -> anyhow::Result<()> {
        if self.handle.is_cancelled() {
            return Err(anyhow::anyhow!("cancelled before start"));
        }
        Ok(())
    }

    /// 借会话 → 开 channel 并 exec → 泵数据 → 归还会话。返回 (exit_code, signal)。
    fn run(&self) -> anyhow::Result<(i32, Option<String>)> {
        // 排队 / 握手期间就被取消：根本不启动远端进程
        self.check_cancelled()?;
        let (mut session, mut pooled) =
            exec_pool_take(&self.state, &self.t).context("Failed to borrow exec session")?;
        if self.handle.is_cancelled() {
            exec_pool_put(&self.state, &self.t, session);
            return Err(anyhow::anyhow!("cancelled before start"));
        }

        // 池里的旧会话可能已经静默断开（NAT 超时等）：channel 打开失败时远端什么
        // 都没执行，可以安全地换一个新会话重试一次。
        let mut channel = loop {
            match self.open_channel(&session) {
                Ok(ch) => break ch,
                Err(OpenError::BeforeExec(e)) if pooled => {
                    debug_log!(
                        "Daemon: 复用的 exec session 不可用 ({:#})，重新握手 {}",
                        e,
                        self.t
                    );
                    exec_pool_clear(&self.state, &self.t);
                    session = open_dedicated_session(&self.t, &self.state)
                        .context("Failed to open exec session")?;
                    pooled = false;
                    self.check_cancelled()?;
                }
                Err(OpenError::BeforeExec(e) | OpenError::AfterExec(e)) => return Err(e),
            }
        };

        let result = self.pump(&session, &mut channel);
        drop(channel);
        match &result {
            // 正常结束且未取消：会话状态干净，放回池里给下一条命令复用
            Ok(_) if !self.handle.is_cancelled() => exec_pool_put(&self.state, &self.t, session),
            Ok(_) => {}
            // 会话已死：顺便清掉池里同 target 的其他会话（大概率跟着 TCP 一起断了）
            Err(e) if is_session_dead(e) => exec_pool_clear(&self.state, &self.t),
            Err(_) => {}
        }
        result
    }

    fn open_channel(&self, session: &Session) -> Result<Channel, OpenError> {
        // channel_session / exec / write_all 阶段需要 blocking
        session.set_blocking(true);
        session.set_timeout(DEFAULT_TIMEOUT_MS);

        let mut channel = session
            .channel_session()
            .context("Failed to open channel")
            .map_err(OpenError::BeforeExec)?;
        if self.cmd.pty {
            channel
                .request_pty("xterm-256color", None, None)
                .context("Failed to request pty")
                .map_err(OpenError::BeforeExec)?;
        }
        // 永远走 PID 包装，stderr 头一行用于 cancel
        channel
            .exec(&self.cmd.to_shell_command(true))
            .context("Failed to exec")
            .map_err(OpenError::AfterExec)?;

        // spec.stdin 是一次性快路径（如 `git commit -F -`），写完立刻 send_eof；
        // 增量 stdin 走 stdin_rx。两者不应混用：混用时 eof 后的增量写会被丢弃。
        if let Some(data) = &self.cmd.stdin {
            channel
                .write_all(data)
                .context("Failed to write stdin")
                .map_err(OpenError::AfterExec)?;
            channel.send_eof().ok();
        }
        Ok(channel)
    }

    /// non-blocking poll 循环：增量 stdin / 读 stdout+stderr / 按阈值 flush / cancel 升级。
    fn pump(
        &self,
        session: &Session,
        channel: &mut Channel,
    ) -> anyhow::Result<(i32, Option<String>)> {
        // 切到 non-blocking。timeout 同时归零，让 read 立刻返回 WouldBlock 而不是 Timeout。
        session.set_blocking(false);
        session.set_timeout(0);

        let mut batcher = Batcher::new();
        let mut pid = PidSniffer::default();
        let mut stdin = StdinQueue {
            eof_sent: self.cmd.stdin.is_some(),
            ..Default::default()
        };
        let mut buf_out = [0u8; 8192];
        let mut buf_err = [0u8; 4096];

        // cancel 后的宽限截止时间；None = 未取消
        let mut grace_deadline: Option<Instant> = None;
        // 是否需要 TERM/KILL 升级（宽限期内没看到 EOF，或 close 后读出错）
        let mut escalate = false;

        loop {
            // 第一档：close channel，让远端 SIGPIPE
            if self.handle.is_cancelled() && grace_deadline.is_none() {
                close_channel(session, channel);
                grace_deadline = Some(Instant::now() + CANCEL_GRACE);
            }
            if grace_deadline.is_some_and(|d| Instant::now() >= d) {
                escalate = true;
                break;
            }
            let cancelling = grace_deadline.is_some();

            let mut idle = true;
            if !cancelling {
                stdin.drain(&self.stdin_rx);
                idle &= !stdin.flush(channel)?;
            }

            // cancel 之后 channel 已 close，读错误很常见：不能直接返回（会跳过 TERM/KILL
            // 升级），而是停止读取并进入升级。
            match channel.read(&mut buf_out) {
                Ok(0) => {}
                Ok(n) => {
                    idle = false;
                    // pty 把 stderr 并进 stdout：PID 行会出现在 stdout 开头
                    let data = &buf_out[..n];
                    batcher.feed_stdout(if self.cmd.pty { pid.feed(data) } else { data });
                }
                Err(e) if is_would_block(&e) => {}
                Err(_) if cancelling => {
                    escalate = true;
                    break;
                }
                Err(e) => return Err(anyhow::anyhow!("read stdout: {}", e)),
            }
            match channel.stderr().read(&mut buf_err) {
                Ok(0) => {}
                Ok(n) => {
                    idle = false;
                    batcher.feed_stderr(pid.feed(&buf_err[..n]));
                }
                Err(e) if is_would_block(&e) => {}
                Err(_) if cancelling => {
                    escalate = true;
                    break;
                }
                Err(e) => return Err(anyhow::anyhow!("read stderr: {}", e)),
            }

            for ev in batcher.flush_if_due() {
                self.emit(ev);
            }
            if channel.eof() {
                break;
            }
            // 没数据时短歇，避免空转
            if idle {
                thread::park_timeout(Duration::from_millis(5));
            }
        }

        for ev in batcher.flush_all() {
            self.emit(ev);
        }

        if escalate {
            if let Some(pid) = pid.pid {
                self.spawn_kill(pid);
            }
            return Ok((-1, None));
        }

        // 退出码：切回 blocking 再 wait_close —— non-blocking 下 wait_close 可能
        // EAGAIN 提前返回，此时 exit_status() 读到的是默认值 0，会把失败误报成成功。
        session.set_blocking(true);
        session.set_timeout(5000);
        channel
            .wait_close()
            .map_err(|e| anyhow::anyhow!("wait_close: {}", e))?;
        let code = channel
            .exit_status()
            .map_err(|e| anyhow::anyhow!("exit_status: {}", e))?;
        let signal = channel.exit_signal().ok().and_then(|s| s.exit_signal);
        Ok((code, signal))
    }

    /// 宽限期内远端没退出（或 channel 已不可读）：后台线程 TERM → KILL 进程组。
    /// 走共享会话另开 channel（会占 SFTP mutex 几十毫秒，kill 命令短，可接受）。
    fn spawn_kill(&self, pid: u32) {
        let (state, t) = (self.state.clone(), self.t.clone());
        thread::spawn(move || {
            for (i, signal) in ["TERM", "KILL"].into_iter().enumerate() {
                if i > 0 {
                    thread::sleep(TERM_TO_KILL);
                }
                debug_log!("Daemon: cmd {} 发 kill -{} {}", t, signal, pid);
                let cmd = build_kill_command(pid, signal);
                if let Err(e) = exec_shared(&state, &t, &cmd, None, None) {
                    eprintln!("Daemon: kill -{} {} 失败: {:#}", signal, pid, e);
                }
            }
        });
    }
}

/// 增量 stdin：pending 保存"还没写完的 chunk"，每轮 poll 写一段，写不完留到下轮，
/// 不阻塞 stdout/stderr 的读取。
#[derive(Default)]
struct StdinQueue {
    pending: VecDeque<(Vec<u8>, usize)>,
    close_requested: bool,
    eof_sent: bool,
}

impl StdinQueue {
    fn drain(&mut self, rx: &mpsc::Receiver<StdinMsg>) {
        while let Ok(msg) = rx.try_recv() {
            match msg {
                // eof 已发：丢弃增量数据，但不报错（caller 行为问题不应炸 daemon）
                StdinMsg::Write(data) if !self.eof_sent => self.pending.push_back((data, 0)),
                StdinMsg::Write(_) => {}
                StdinMsg::Close => self.close_requested = true,
            }
        }
    }

    /// 尝试写一段 / 发 eof（non-blocking）。返回是否有进展。
    fn flush(&mut self, channel: &mut Channel) -> anyhow::Result<bool> {
        let mut progressed = false;
        if let Some((data, off)) = self.pending.front_mut() {
            match channel.write(&data[*off..]) {
                Ok(n) if n > 0 => {
                    *off += n;
                    if *off >= data.len() {
                        self.pending.pop_front();
                    }
                    progressed = true;
                }
                Ok(_) => {}
                Err(e) if is_would_block(&e) => {}
                Err(e) => return Err(anyhow::anyhow!("write stdin: {}", e)),
            }
        }
        // send_eof 在 non-blocking 模式下偶发 EAGAIN：下轮再试
        if self.close_requested && self.pending.is_empty() && !self.eof_sent {
            match channel.send_eof() {
                Err(e) if e.code() == EAGAIN => {}
                _ => self.eof_sent = true,
            }
        }
        Ok(progressed)
    }
}

/// 截取 stderr 开头的 "ZERO_PID:<n>\n" 行
#[derive(Default)]
struct PidSniffer {
    buf: Vec<u8>,
    done: bool,
    pid: Option<u32>,
}

impl PidSniffer {
    /// 喂入一段 stderr，返回应当作为普通 stderr 转发的字节
    fn feed<'a>(&'a mut self, bytes: &'a [u8]) -> &'a [u8] {
        if self.done {
            return bytes;
        }
        self.buf.extend_from_slice(bytes);
        if let Some((pid, off)) = parse_pid_line(&self.buf) {
            self.done = true;
            self.pid = Some(pid);
            return &self.buf[off..];
        }
        if self.buf.len() > 64 {
            // 没收到 PID 行就有 >64 byte 杂物 —— 不再等，原样冲出去
            self.done = true;
            return &self.buf;
        }
        &[]
    }
}

/// 解析 "ZERO_PID:<n>\n"，返回 (pid, PID 行之后的偏移)
fn parse_pid_line(buf: &[u8]) -> Option<(u32, usize)> {
    let rest = buf.strip_prefix(b"ZERO_PID:")?;
    let nl = rest.iter().position(|&b| b == b'\n')?;
    let pid = std::str::from_utf8(&rest[..nl]).ok()?.trim().parse().ok()?;
    Some((pid, b"ZERO_PID:".len() + nl + 1))
}

/// close channel：临时切回 blocking（带短超时），避免 non-blocking 下 EAGAIN 导致
/// close 实际没发出去。
fn close_channel(session: &Session, channel: &mut Channel) {
    session.set_blocking(true);
    session.set_timeout(2000);
    let _ = channel.close();
    session.set_blocking(false);
    session.set_timeout(0);
}

/// 构造 kill 命令：先杀整个进程组（sshd 为每个 exec channel setsid，组内即该命令
/// 的进程树，如 git → pager / hooks），再兜底杀 PID 本身。
/// 若 PGID 与执行 kill 的 shell 自己的组相同（理论上不会）则跳过组杀，避免误伤。
fn build_kill_command(pid: u32, signal: &str) -> String {
    format!(
        "pg=$(ps -o pgid= -p {pid} 2>/dev/null | tr -d ' '); \
         me=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' '); \
         if [ -n \"$pg\" ] && [ \"$pg\" -gt 1 ] && [ \"$pg\" != \"$me\" ]; then kill -{sig} -- -\"$pg\" 2>/dev/null; fi; \
         kill -{sig} {pid} 2>/dev/null || true",
        pid = pid,
        sig = signal
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kill_command_targets_group_and_pid() {
        let c = build_kill_command(4242, "TERM");
        assert!(c.contains("ps -o pgid= -p 4242"));
        assert!(c.contains("kill -TERM -- -\"$pg\""));
        assert!(c.ends_with("kill -TERM 4242 2>/dev/null || true"));
    }

    #[test]
    fn parse_pid_line_basic() {
        assert_eq!(
            parse_pid_line(b"ZERO_PID:12345\nrest of stderr..."),
            Some((12345, 15))
        );
        assert!(parse_pid_line(b"some other stderr").is_none());
        assert!(parse_pid_line(b"ZERO_PID:notanumber\n").is_none());
        assert!(parse_pid_line(b"ZERO_PID:42").is_none()); // no newline yet
                                                           // pty 模式下行尾是 \r\n
        assert_eq!(parse_pid_line(b"ZERO_PID:9\r\nx"), Some((9, 12)));
    }

    #[test]
    fn pid_sniffer_strips_pid_line_across_chunks() {
        let mut s = PidSniffer::default();
        assert_eq!(s.feed(b"ZERO_P"), b"");
        assert_eq!(s.feed(b"ID:7\nerr"), b"err");
        assert_eq!(s.pid, Some(7));
        assert_eq!(s.feed(b"more"), b"more");
    }

    #[test]
    fn pid_sniffer_gives_up_on_garbage() {
        let mut s = PidSniffer::default();
        let junk = [b'x'; 70];
        assert_eq!(s.feed(&junk), &junk[..]);
        assert_eq!(s.pid, None);
    }

    #[test]
    fn cancel_and_stdin_after_worker_exit() {
        let (h, rx) = CmdHandle::new();
        assert!(h.send_stdin(b"x".to_vec()));
        drop(rx);
        assert!(!h.close_stdin());
        h.cancel();
        assert!(h.is_cancelled());
    }

    #[test]
    fn notification_shape() {
        let v = CommandEvent::Exit {
            code: 1,
            signal: None,
            duration_ms: 5,
        }
        .into_notification("sid");
        let expected = Value::Array(vec![
            Value::from(2),
            Value::from("nvim_exec_lua"),
            Value::Array(vec![
                Value::from("require('zero-nvim.cmd.exec')._dispatch(...)"),
                Value::Array(vec![
                    Value::from("sid"),
                    Value::from("exit"),
                    Value::Array(vec![Value::from(1), Value::Nil, Value::from(5)]),
                ]),
            ]),
        ]);
        assert_eq!(v, expected);
    }
}
