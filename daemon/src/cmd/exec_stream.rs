// =============================================================================
// cmd/exec_stream.rs — 流式命令执行
// =============================================================================
// 长跑命令（搜索 / git diff / docker logs）走这里。
//
// 关键设计：
//   * 每条流式命令独占一个 Session（不复用 with_conn 的池子），避免长命令霸占
//     sftp / read_dir 共用的 Session Mutex。
//   * 单个工作线程内部：blocking exec → 切到 non-blocking 后 poll。libssh2 不是
//     线程安全的，所以即便 stdout/stderr 看似两路 IO，也只用单线程交错读，避免
//     竞态。
//   * stderr 头一行解析 "ZERO_PID:<n>"，存到 CmdHandle.remote_pid。cancel 时用
//     这个 PID 在 with_conn 的另一条 channel 上 kill。
//   * cancel 三档升级：close channel → 3s grace → kill -TERM → 2s → kill -KILL。

use crate::cmd::batcher::Batcher;
use crate::cmd::cancel::{try_extract_pid, CancelToken};
use crate::cmd::registry::CmdHandle;
use crate::cmd::spec::{ConnTarget, RemoteCommand};
use crate::cmd::CommandEvent;
use crate::connect::open_dedicated_session;
use crate::state::DaemonState;
use anyhow::Context;
use std::io::{ErrorKind, Read, Write};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

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
    thread::spawn(move || {
        let start = Instant::now();
        let result = run_inner(
            &target,
            &cmd,
            &sink,
            &cancel,
            &pid_slot,
            &state,
        );
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
            let state_lock = state.lock().unwrap();
            state_lock.running_commands.clone()
        };
        if let Ok(mut reg) = reg_arc.lock() {
            reg.remove(&session_id);
        };
    });

    Ok(())
}

/// 真正的流式执行体。返回 (exit_code, signal_name?)。任何错误都被外层 catch。
fn run_inner<S>(
    target: &ConnTarget,
    cmd: &RemoteCommand,
    sink: &S,
    cancel: &CancelToken,
    pid_slot: &Arc<Mutex<Option<u32>>>,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<(i32, Option<String>), anyhow::Error>
where
    S: Fn(CommandEvent) + Send + Sync + 'static,
{
    // 1. 开独占 Session（blocking + 10s timeout 用于握手）
    let session = open_dedicated_session(&target.user, &target.host, target.port, state)
        .context("Failed to open dedicated session")?;

    // 2. 准备 channel（仍 blocking，方便 exec）
    let mut channel = session
        .channel_session()
        .context("Failed to open channel")?;

    if cmd.pty {
        channel
            .request_pty("xterm-256color", None, None)
            .context("Failed to request pty")?;
    }

    // 3. exec —— 永远走 PID 包装，stderr 头一行用于 cancel
    let shell_cmd = cmd.to_shell_command(true);
    channel.exec(&shell_cmd).context("Failed to exec")?;

    // 4. 写 stdin（如果有），写完 send_eof
    if let Some(stdin_data) = &cmd.stdin {
        channel
            .write_all(stdin_data)
            .context("Failed to write stdin")?;
        channel.send_eof().ok();
    }

    // 5. 切到 non-blocking。timeout 同时归零，让 read 立刻返回 WouldBlock 而不是 Timeout。
    session.set_blocking(false);
    session.set_timeout(0);

    let mut batcher = Batcher::new();
    let mut stderr_pid_buf: Vec<u8> = Vec::with_capacity(64);
    let mut pid_extracted = false;

    let mut buf_out = [0u8; 8192];
    let mut buf_err = [0u8; 4096];

    let mut cancel_phase: CancelPhase = CancelPhase::Running;

    loop {
        // 5a. 处理 cancel 升级
        if cancel.is_cancelled() && matches!(cancel_phase, CancelPhase::Running) {
            // 第一档：close channel；让远端 SIGPIPE
            let _ = channel.close();
            cancel_phase = CancelPhase::Closed {
                deadline: Instant::now() + Duration::from_secs(3),
            };
        }
        if let CancelPhase::Closed { deadline } = cancel_phase {
            if Instant::now() >= deadline {
                // 第二档：另开 channel kill -TERM
                let pid = pid_slot.lock().ok().and_then(|g| *g);
                if let Some(pid) = pid {
                    eprintln!(
                        "Daemon: cmd {} grace 超时，发 kill -TERM {}",
                        target.key(),
                        pid
                    );
                    fire_kill(state, target, pid, "TERM");
                }
                cancel_phase = CancelPhase::Termed {
                    deadline: Instant::now() + Duration::from_secs(2),
                };
            }
        }
        if let CancelPhase::Termed { deadline } = cancel_phase {
            if Instant::now() >= deadline {
                let pid = pid_slot.lock().ok().and_then(|g| *g);
                if let Some(pid) = pid {
                    eprintln!(
                        "Daemon: cmd {} TERM 后仍存活，发 kill -KILL {}",
                        target.key(),
                        pid
                    );
                    fire_kill(state, target, pid, "KILL");
                }
                cancel_phase = CancelPhase::Killed;
            }
        }

        // 5b. 读 stdout / stderr（non-blocking）
        let mut idle = true;

        match channel.read(&mut buf_out) {
            Ok(0) => {
                // EOF on stdout
            }
            Ok(n) => {
                idle = false;
                batcher.feed_stdout(&buf_out[..n]);
            }
            Err(e) if is_would_block(&e) => {}
            Err(e) => {
                // 真错误：丢出去，由外层包成 Aborted
                return Err(anyhow::anyhow!("read stdout: {}", e));
            }
        }

        match channel.stderr().read(&mut buf_err) {
            Ok(0) => {}
            Ok(n) => {
                idle = false;
                let bytes = &buf_err[..n];
                if !pid_extracted {
                    stderr_pid_buf.extend_from_slice(bytes);
                    if let Some((pid, off)) = try_extract_pid(&stderr_pid_buf) {
                        if let Ok(mut g) = pid_slot.lock() {
                            *g = Some(pid);
                        }
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
            Err(e) => {
                return Err(anyhow::anyhow!("read stderr: {}", e));
            }
        }

        // 5c. 按阈值 flush
        for ev in batcher.flush_if_due() {
            sink(ev);
        }

        // 5d. EOF 检测
        if channel.eof() {
            // 把残留全部 flush
            for ev in batcher.flush_all() {
                sink(ev);
            }
            break;
        }

        // 5e. 没数据时短歇，避免空转
        if idle {
            thread::park_timeout(Duration::from_millis(5));
        }
    }

    // 6. wait_close（已 EOF 或被 close 后通常很快）
    let _ = channel.wait_close();
    let exit_code = channel.exit_status().unwrap_or(-1);
    let exit_signal = channel
        .exit_signal()
        .ok()
        .and_then(|s| s.exit_signal)
        .map(|s| s.to_string());

    // 如果是 cancel 路径，把退出语义换成 Aborted（外层判断 cancel 标志）
    Ok((exit_code, exit_signal))
}

#[derive(Debug)]
enum CancelPhase {
    Running,
    Closed { deadline: Instant },
    Termed { deadline: Instant },
    Killed,
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

/// 在 with_conn 的池子里另开 channel，发一条 kill 命令。失败仅打日志，不影响主流程。
fn fire_kill(
    state: &Arc<Mutex<DaemonState>>,
    target: &ConnTarget,
    pid: u32,
    signal: &str,
) {
    // 注意：这里走 with_conn，会霸占 SFTP mutex 几十毫秒，但 kill 命令短，可接受。
    let cmd = format!("kill -{} {} 2>/dev/null || true", signal, pid);
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
