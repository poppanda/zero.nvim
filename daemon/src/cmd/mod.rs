// =============================================================================
// cmd — 通用远程命令（RPC 入口）
// =============================================================================
//   cmd_sync        [user, host, port, spec] -> { stdout, stderr, code, duration_ms }
//   cmd_stream      [session_id, user, host, port, spec] -> true（事件流走通知）
//   cmd_cancel      [session_id] -> true（无须等结果）
//   cmd_stdin_write [session_id, data]（rpcnotify）
//   cmd_stdin_close [session_id]（rpcnotify）
//
// 两档执行：
//   - sync:   走共享会话（with_conn）；只用于探针式短命令，持锁时长 = 命令时长，
//             **绝不能用于长命令**（会饿死 SFTP / read_dir）
//   - stream: 从 exec 池取独占 Session + non-blocking poll（见 stream.rs）
//
// spec 字段见 spec.rs。

mod batcher;
mod spec;
mod stream;

use crate::rpc::{map, Outbox};
use crate::session::exec_shared;
use crate::state::{LockExt, SharedState, Target};
use rmpv::Value;
use spec::RemoteCommand;
use std::time::Instant;
pub use stream::CmdHandle;

/// stdout/stderr 用 String 而非 Binary：nvim 内部 RPC 把 bin 解成 vim.Blob
/// (userdata)，传给 fnamemodify / vim.split 触发 E976。git 输出 99% 是 UTF-8
/// 文本，from_utf8_lossy 处理偶发非 UTF-8 字节（替换为 U+FFFD）。
fn lossy(bytes: &[u8]) -> Value {
    Value::from(String::from_utf8_lossy(bytes).into_owned())
}

pub fn sync(t: &Target, spec: &Value, state: &SharedState) -> anyhow::Result<Value> {
    let cmd = RemoteCommand::from_value(spec)?;
    // 短命令——不需要 PID 包装，纯净执行减少 stderr 噪音
    let shell_cmd = cmd.to_shell_command(false);
    let start = Instant::now();
    let out = exec_shared(state, t, &shell_cmd, cmd.stdin.as_deref(), cmd.timeout)?;
    Ok(map([
        ("stdout", lossy(&out.stdout)),
        ("stderr", lossy(&out.stderr)),
        ("code", Value::from(out.code)),
        (
            "duration_ms",
            Value::from(start.elapsed().as_millis() as u64),
        ),
    ]))
}

/// exec_remote（旧接口）：执行一条 shell 命令，返回 trim 后的 stdout（如 `which python3`）
pub fn exec_remote(t: &Target, cmd: &str, state: &SharedState) -> anyhow::Result<Value> {
    let out = exec_shared(state, t, cmd, None, None)?;
    Ok(Value::from(String::from_utf8_lossy(&out.stdout).trim()))
}

/// 同步注册句柄后立即返回；执行在 worker 线程里，事件通过通知推给 Lua
pub fn stream(
    sid: &str,
    t: Target,
    spec: &Value,
    state: &SharedState,
    tx: &Outbox,
) -> anyhow::Result<Value> {
    let cmd = RemoteCommand::from_value(spec)?;
    let (handle, stdin_rx) = CmdHandle::new();
    state
        .lock_ok()
        .commands
        .insert(sid.to_string(), handle.clone());
    stream::spawn(
        sid.to_string(),
        t,
        cmd,
        handle,
        stdin_rx,
        state.clone(),
        tx.clone(),
    );
    Ok(Value::Boolean(true))
}

pub fn cancel(sid: &str, state: &SharedState) -> anyhow::Result<Value> {
    with_handle(sid, state, "cmd_cancel", |h| {
        h.cancel();
        debug_log!("Daemon: cmd_cancel session={}", sid);
        true
    })
}

/// 把 data 推到 worker 的 stdin 队列（rpcnotify，失败仅打日志）
pub fn stdin_write(sid: &str, data: &[u8], state: &SharedState) -> anyhow::Result<Value> {
    with_handle(sid, state, "cmd_stdin_write", |h| {
        h.send_stdin(data.to_vec())
    })
}

/// 让 worker 在写完队列后 send_eof 关闭 stdin
pub fn stdin_close(sid: &str, state: &SharedState) -> anyhow::Result<Value> {
    with_handle(sid, state, "cmd_stdin_close", |h| h.close_stdin())
}

/// 查找句柄并执行 f；找不到 / f 返回 false（worker 已结束）都只打调试日志
fn with_handle(
    sid: &str,
    state: &SharedState,
    what: &str,
    f: impl FnOnce(&CmdHandle) -> bool,
) -> anyhow::Result<Value> {
    let handle = state.lock_ok().commands.get(sid).cloned();
    match handle {
        Some(h) if !f(&h) => debug_log!("Daemon: {} session={} 失败（worker 已结束）", what, sid),
        Some(_) => {}
        None => debug_log!("Daemon: {} session={} 未找到（可能已结束）", what, sid),
    }
    Ok(Value::Boolean(true))
}
