// =============================================================================
// cmd/exec_stream.rs — 流式命令执行
// =============================================================================
// 长跑命令（搜索 / git diff / docker logs）走这里。
//
// 关键设计：
//   * 每条流式命令从 exec 会话池**取走**一个 Session 独占（不复用 with_conn 的
//     池子），避免长命令霸占 sftp / read_dir 共用的 Session Mutex；同 target 的
//     多条流互不阻塞，结束后会话归还池中复用。
//   * 单个工作线程内部：blocking exec → 切到 non-blocking 后 poll。libssh2 不是
//     线程安全的，所以即便 stdout/stderr 看似两路 IO，也只用单线程交错读，避免
//     竞态。
//   * stderr 头一行解析 "ZERO_PID:<n>"，存到 CmdHandle.remote_pid。cancel 时用
//     这个 PID 在 with_conn 的另一条 channel 上 kill。
//   * cancel 三档升级：close channel → 3s grace → kill -TERM → 2s → kill -KILL
//     （TERM/KILL 打整个进程组，在后台线程进行，不延迟 Aborted 事件）。

use crate::cmd::batcher::Batcher;
use crate::cmd::cancel::{try_extract_pid, CancelToken};
use crate::cmd::registry::{CmdHandle, StdinMsg};
use crate::cmd::spec::{ConnTarget, RemoteCommand};
use crate::cmd::CommandEvent;
use crate::connect::{borrow_exec_session, drop_exec_session, open_dedicated_session, return_exec_session};
use crate::state::{is_session_dead, DaemonState, LockExt};
use anyhow::Context;
use ssh2::{Channel, Session};
use std::collections::VecDeque;
use std::io::{ErrorKind, Read, Write};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// cancel 后等远端自然退出（SIGPIPE）的宽限期
const CANCEL_GRACE: Duration = Duration::from_secs(3);
/// TERM 之后到 KILL 的间隔
const TERM_TO_KILL: Duration = Duration::from_secs(2);

/// 启动一条流式命令。返回 CmdHandle 注册到 registry；事件流通过 sink 异步推送。
///
/// `sink` 在工作线程上下文调用——sink 的实现需要自身保证非阻塞（典型实现是 mpsc
/// send 到 main.rs 的输出线程）。
pub fn run_streaming<S>(
    target: ConnTarget,
    cmd: RemoteCommand,
    sink: S,
    handle: Arc<CmdHandle>,
    state: Arc<Mutex<DaemonState>>,
) -> Result<(), anyhow::Error>
where
    S: Fn(CommandEvent) + Send + Sync + 'static,
{
    // 把 SSH 握手 + 认证放到 worker 线程内做（多 100ms 的 TCP 建连不能阻塞 main loop）
    let cancel = handle.cancel.clone();
    let pid_slot = handle.remote_pid.clone();
    let session_id = handle.session_id.clone();

    // stdin 增量写入通道：cmd_stdin_write / cmd_stdin_close RPC 通过 handle.stdin_tx
    // 把 StdinMsg push 进来；worker 在 poll 循环里 try_recv 处理。
    // worker 退出时 rx 自动 drop，后续 send 会失败被 send_stdin/close_stdin 静默忽略。
    let (stdin_tx, stdin_rx) = mpsc::channel::<StdinMsg>();
    {
        let mut g = handle.stdin_tx.lock_ok();
        *g = Some(stdin_tx);
    }

    thread::spawn(move || {
        let start = Instant::now();
        let result = run_worker(&target, &cmd, &sink, &cancel, &pid_slot, &stdin_rx, &state);
        let duration_ms = start.elapsed().as_millis() as u64;

        match result {
            Ok((code, signal)) => {
                if cancel.is_cancelled() {
                    sink(CommandEvent::Aborted {
                        reason: format!("cancelled (exit={})", code),
                    });
                } else {
                    sink(CommandEvent::Exit {
                        code,
                        signal,
                        duration_ms,
                    });
                }
            }
            Err(e) => {
                if cancel.is_cancelled() {
                    sink(CommandEvent::Aborted {
                        reason: format!("cancelled: {}", e),
                    });
                } else {
                    sink(CommandEvent::Aborted {
                        reason: format!("{:#}", e),
                    });
                }
            }
        }

        // 从 registry 中移除自己
        let reg_arc = {
            let state_lock = state.lock_ok();
            state_lock.running_commands.clone()
        };
        reg_arc.lock_ok().remove(&session_id);
    });

    Ok(())
}

/// 借会话 → 开 channel 并 exec → 泵数据 → 归还会话。
fn run_worker<S>(
    target: &ConnTarget,
    cmd: &RemoteCommand,
    sink: &S,
    cancel: &CancelToken,
    pid_slot: &Arc<Mutex<Option<u32>>>,
    stdin_rx: &mpsc::Receiver<StdinMsg>,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<(i32, Option<String>), anyhow::Error>
where
    S: Fn(CommandEvent) + Send + Sync + 'static,
{
    // 排队 / 握手期间就被取消：根本不启动远端进程
    if cancel.is_cancelled() {
        return Err(anyhow::anyhow!("cancelled before start"));
    }

    // 1. 从池里取走一个 exec Session 独占使用（池空则新建，首次握手 ≈ 200-500ms）
    let (mut session, mut pooled) =
        borrow_exec_session(&target.user, &target.host, target.port, state)
            .context("Failed to borrow exec session")?;
    if cancel.is_cancelled() {
        return_exec_session(&target.user, &target.host, target.port, session, state);
        return Err(anyhow::anyhow!("cancelled before start"));
    }

    // 2. 开 channel + exec。池里的旧会话可能已经静默断开（NAT 超时等）：
    //    channel 打开失败时远端什么都没执行，可以安全地换一个新会话重试一次。
    let mut channel = loop {
        match open_and_exec(&session, cmd) {
            Ok(ch) => break ch,
            Err(OpenError::BeforeExec(e)) if pooled => {
                debug_log!(
                    "Daemon: 复用的 exec session 不可用 ({:#})，重新握手 {}",
                    e,
                    target.key()
                );
                drop_exec_session(&target.user, &target.host, target.port, state);
                session = open_dedicated_session(&target.user, &target.host, target.port, state)
                    .context("Failed to open exec session")?;
                pooled = false;
                if cancel.is_cancelled() {
                    return Err(anyhow::anyhow!("cancelled before start"));
                }
            }
            Err(OpenError::BeforeExec(e)) | Err(OpenError::AfterExec(e)) => return Err(e),
        }
    };

    // 3. 泵数据
    let result = pump(&session, &mut channel, target, cmd, sink, cancel, pid_slot, stdin_rx, state);
    drop(channel);

    match &result {
        // 正常结束且未取消：会话状态干净，放回池里给下一条命令复用
        Ok(_) if !cancel.is_cancelled() => {
            return_exec_session(&target.user, &target.host, target.port, session, state);
        }
        Ok(_) => {}
        Err(e) => {
            // 会话已死：顺便清掉池里同 target 的其他会话（大概率跟着 TCP 一起断了）
            if is_session_dead(e) {
                drop_exec_session(&target.user, &target.host, target.port, state);
            }
        }
    }
    result
}

enum OpenError {
    /// exec 请求发出前失败：远端没有执行任何东西，可重试
    BeforeExec(anyhow::Error),
    /// exec 之后失败：不可重试
    AfterExec(anyhow::Error),
}

fn open_and_exec(session: &Session, cmd: &RemoteCommand) -> Result<Channel, OpenError> {
    // channel_session / exec / write_all 阶段需要 blocking
    session.set_blocking(true);
    session.set_timeout(10000);

    let mut channel = session
        .channel_session()
        .context("Failed to open channel")
        .map_err(OpenError::BeforeExec)?;

    if cmd.pty {
        channel
            .request_pty("xterm-256color", None, None)
            .context("Failed to request pty")
            .map_err(OpenError::BeforeExec)?;
    }

    // exec —— 永远走 PID 包装，stderr 头一行用于 cancel
    let shell_cmd = cmd.to_shell_command(true);
    channel
        .exec(&shell_cmd)
        .context("Failed to exec")
        .map_err(OpenError::AfterExec)?;

    // 写 stdin（如果有 spec.stdin，一次性写完后立刻 send_eof）
    //
    // 增量 stdin 走 stdin_rx 通道（cmd_stdin_write/close RPC）；spec.stdin 是
    // 快路径——典型场景如 `git commit -F -` 把 message 一次性塞进去。两条路
    // 不冲突：caller 要么用 spec.stdin（一次性），要么用增量（不传 spec.stdin），
    // 不应该混用。混用时 spec.stdin 先走，eof 后增量写会被远端忽略。
    if let Some(stdin_data) = &cmd.stdin {
        channel
            .write_all(stdin_data)
            .context("Failed to write stdin")
            .map_err(OpenError::AfterExec)?;
        channel.send_eof().ok();
    }
    Ok(channel)
}

/// 真正的流式执行体。返回 (exit_code, signal_name?)。任何错误都被外层 catch。
#[allow(clippy::too_many_arguments)]
fn pump<S>(
    session: &Session,
    channel: &mut Channel,
    target: &ConnTarget,
    cmd: &RemoteCommand,
    sink: &S,
    cancel: &CancelToken,
    pid_slot: &Arc<Mutex<Option<u32>>>,
    stdin_rx: &mpsc::Receiver<StdinMsg>,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<(i32, Option<String>), anyhow::Error>
where
    S: Fn(CommandEvent) + Send + Sync + 'static,
{
    let mut stdin_eof_sent = cmd.stdin.is_some();

    // 切到 non-blocking。timeout 同时归零，让 read 立刻返回 WouldBlock 而不是 Timeout。
    session.set_blocking(false);
    session.set_timeout(0);

    let mut batcher = Batcher::new();
    let mut stderr_pid_buf: Vec<u8> = Vec::with_capacity(64);
    let mut pid_extracted = false;

    let mut buf_out = [0u8; 8192];
    let mut buf_err = [0u8; 4096];

    // cancel 后的宽限截止时间；None = 未取消
    let mut grace_deadline: Option<Instant> = None;
    // 是否需要 TERM/KILL 升级（宽限期内没看到 EOF，或 close 后读出错）
    let mut escalate = false;

    // 增量 stdin：pending 队列保存"还没写完的 chunk"。每次 loop 写一段，
    // 写不完留着下次（保持 stdout/stderr 读取的并发性，不阻塞）。
    let mut pending_writes: VecDeque<(Vec<u8>, usize)> = VecDeque::new();
    let mut close_after_writes = false;

    loop {
        // 5a. 处理 cancel：第一档 close channel，让远端 SIGPIPE
        if cancel.is_cancelled() && grace_deadline.is_none() {
            close_channel(session, channel);
            grace_deadline = Some(Instant::now() + CANCEL_GRACE);
        }
        if let Some(deadline) = grace_deadline {
            if Instant::now() >= deadline {
                escalate = true;
                break;
            }
        }
        let cancelling = grace_deadline.is_some();

        let mut idle = true;

        if !cancelling {
            // 5b-pre. 排空增量 stdin queue：把外部 RPC 推过来的 Write/Close 消息
            // 缓存到 pending_writes / close_after_writes，实际写入在 5b-mid 处理。
            while let Ok(msg) = stdin_rx.try_recv() {
                match msg {
                    StdinMsg::Write(data) => {
                        // eof 已发：丢弃增量数据，但不报错（caller 行为问题不应炸 daemon）
                        if !stdin_eof_sent {
                            pending_writes.push_back((data, 0));
                        }
                    }
                    StdinMsg::Close => close_after_writes = true,
                }
            }

            // 5b-mid. 尝试写一段 stdin（non-blocking）
            if let Some((data, off)) = pending_writes.front_mut() {
                match channel.write(&data[*off..]) {
                    Ok(0) => {}
                    Ok(n) => {
                        *off += n;
                        if *off >= data.len() {
                            pending_writes.pop_front();
                        }
                        idle = false;
                    }
                    Err(e) if is_would_block(&e) => {}
                    Err(e) => return Err(anyhow::anyhow!("write stdin: {}", e)),
                }
            }

            // 5b-post. close 请求 + 队列清空 → send_eof
            // send_eof 在 non-blocking 模式下偶发 EAGAIN：失败就下轮再试。
            if close_after_writes && pending_writes.is_empty() && !stdin_eof_sent {
                match channel.send_eof() {
                    Ok(()) => stdin_eof_sent = true,
                    Err(e) if e.code() == ssh2::ErrorCode::Session(-37) => {}
                    Err(_) => stdin_eof_sent = true,
                }
            }
        }

        // 5c. 读 stdout / stderr（non-blocking）
        // cancel 之后 channel 已 close，读错误很常见：不能直接返回（会跳过 TERM/KILL
        // 升级），而是停止读取并进入升级。
        match channel.read(&mut buf_out) {
            Ok(0) => {}
            Ok(n) => {
                idle = false;
                batcher.feed_stdout(&buf_out[..n]);
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
                let bytes = &buf_err[..n];
                if !pid_extracted {
                    stderr_pid_buf.extend_from_slice(bytes);
                    if let Some((pid, off)) = try_extract_pid(&stderr_pid_buf) {
                        *pid_slot.lock_ok() = Some(pid);
                        // 把 PID 行之后的内容当作正常 stderr 喂给 batcher
                        if off < stderr_pid_buf.len() {
                            batcher.feed_stderr(&stderr_pid_buf[off..]);
                        }
                        pid_extracted = true;
                        stderr_pid_buf.clear();
                    } else if stderr_pid_buf.len() > 64 {
                        // 没收到 PID 行就有 >64 byte 杂物 —— 不再等，原样冲出去
                        batcher.feed_stderr(&stderr_pid_buf);
                        pid_extracted = true;
                        stderr_pid_buf.clear();
                    }
                } else {
                    batcher.feed_stderr(bytes);
                }
            }
            Err(e) if is_would_block(&e) => {}
            Err(_) if cancelling => {
                escalate = true;
                break;
            }
            Err(e) => return Err(anyhow::anyhow!("read stderr: {}", e)),
        }

        // 5d. 按阈值 flush
        for ev in batcher.flush_if_due() {
            sink(ev);
        }

        // 5e. EOF 检测
        if channel.eof() {
            break;
        }

        // 5f. 没数据时短歇，避免空转
        if idle {
            thread::park_timeout(Duration::from_millis(5));
        }
    }

    // 把残留全部 flush
    for ev in batcher.flush_all() {
        sink(ev);
    }

    if escalate {
        // 宽限期内远端没退出（或 channel 已不可读）：后台线程 TERM → KILL 进程组，
        // 不阻塞 Aborted 事件下发（Lua 侧可能在等它释放 target 队列）。
        let pid = *pid_slot.lock_ok();
        if let Some(pid) = pid {
            let state = state.clone();
            let target = target.clone();
            thread::spawn(move || {
                debug_log!("Daemon: cmd {} grace 超时，发 kill -TERM {}", target.key(), pid);
                fire_kill(&state, &target, pid, "TERM");
                thread::sleep(TERM_TO_KILL);
                fire_kill(&state, &target, pid, "KILL");
            });
        }
        return Ok((-1, None));
    }

    // 6. 退出码：切回 blocking 再 wait_close —— non-blocking 下 wait_close 可能
    //    EAGAIN 提前返回，此时 exit_status() 读到的是默认值 0，会把失败误报成成功。
    session.set_blocking(true);
    session.set_timeout(5000);
    channel
        .wait_close()
        .map_err(|e| anyhow::anyhow!("wait_close: {}", e))?;
    let exit_code = channel
        .exit_status()
        .map_err(|e| anyhow::anyhow!("exit_status: {}", e))?;
    let exit_signal = channel
        .exit_signal()
        .ok()
        .and_then(|s| s.exit_signal);

    // 如果是 cancel 路径，把退出语义换成 Aborted（外层判断 cancel 标志）
    Ok((exit_code, exit_signal))
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

/// 兼容判断：不同 ssh2 版本里 EAGAIN 既可能是 io::ErrorKind::WouldBlock，也可能
/// 透传为带 Session(-37) 的 io::Error::Other。
fn is_would_block(e: &std::io::Error) -> bool {
    if e.kind() == ErrorKind::WouldBlock {
        return true;
    }
    let msg = format!("{}", e);
    msg.contains("EAGAIN") || msg.contains("Session(-37)") || msg.contains("would block")
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

/// 在 with_conn 的池子里另开 channel，发一条 kill 命令。失败仅打日志，不影响主流程。
fn fire_kill(state: &Arc<Mutex<DaemonState>>, target: &ConnTarget, pid: u32, signal: &str) {
    // 注意：这里走 with_conn，会霸占 SFTP mutex 几十毫秒，但 kill 命令短，可接受。
    let cmd = build_kill_command(pid, signal);
    let result = DaemonState::with_conn(state, &target.user, &target.host, target.port, |conn| {
        let mut ch = conn.session.channel_session()?;
        ch.exec(&cmd)?;
        let mut sink = Vec::new();
        let _ = ch.read_to_end(&mut sink);
        ch.wait_close().ok();
        Ok(())
    });
    if let Err(e) = result {
        eprintln!("Daemon: fire_kill {} {} 失败: {}", signal, pid, e);
    }
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
}
