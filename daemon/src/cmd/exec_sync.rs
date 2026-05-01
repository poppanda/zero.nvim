// =============================================================================
// cmd/exec_sync.rs — 同步命令执行（短命令快路径）
// =============================================================================
// 复用 with_conn 的现有会话 + 单 channel；适合 git rev-parse / docker info 这类
// 输出小、需要 stderr 和 exit code 的探针式命令。
//
// 不进 cmd_registry，不开 dedicated session。Mutex 持有时间 = 命令执行时长，
// 因此**绝不能用于长命令**（会饿死 SFTP / read_dir）。

use crate::cmd::spec::RemoteCommand;
use crate::state::DaemonState;
use anyhow::Context;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::time::Instant;

/// 同步执行返回值
#[derive(Debug, Clone)]
pub struct SyncOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub code: i32,
    pub duration_ms: u64,
}

pub fn run_sync(
    user: &str,
    host: &str,
    port: u16,
    cmd: &RemoteCommand,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<SyncOutput, anyhow::Error> {
    let start = Instant::now();

    // 短命令——不需要 PID 包装，纯净执行减少 stderr 噪音
    let shell_cmd = cmd.to_shell_command(false);

    let result = DaemonState::with_conn(state, user, host, port, |conn| {
        // 临时调整 timeout（命令级），结束后恢复 10s
        let prev_timeout = conn.session.timeout();
        if let Some(t) = cmd.timeout {
            conn.session.set_timeout(t.as_millis() as u32);
        }

        let exec_result = (|| -> Result<SyncOutput, anyhow::Error> {
            let mut channel = conn
                .session
                .channel_session()
                .context("Failed to create channel_session")?;

            channel.exec(&shell_cmd).context("Failed to exec command")?;

            // 写 stdin（如果有）
            if let Some(stdin_data) = &cmd.stdin {
                channel
                    .write_all(stdin_data)
                    .context("Failed to write stdin")?;
                channel.send_eof().context("Failed to send eof")?;
            }

            // 读 stdout 全部
            let mut stdout_buf = Vec::new();
            channel
                .read_to_end(&mut stdout_buf)
                .context("Failed to read stdout")?;

            // 读 stderr 全部
            let mut stderr_buf = Vec::new();
            channel
                .stderr()
                .read_to_end(&mut stderr_buf)
                .context("Failed to read stderr")?;

            channel.wait_close().ok();
            let code = channel.exit_status().unwrap_or(-1);

            Ok(SyncOutput {
                stdout: stdout_buf,
                stderr: stderr_buf,
                code,
                duration_ms: start.elapsed().as_millis() as u64,
            })
        })();

        // 还原 timeout
        conn.session.set_timeout(prev_timeout);
        exec_result
    })?;

    Ok(result)
}
