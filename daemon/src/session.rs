// =============================================================================
// session.rs — SSH 会话池 & 远程命令执行
// =============================================================================
// 两个池，互相解耦：
//   - 共享会话（state.sessions）：每个 target 一个 ConnSession，SFTP / 短命令
//     走 with_conn 串行使用，检测到断连时自动重连重试一次。
//   - exec 池（state.exec_pool）：流式命令从池中**取走**一个 Session 独占使用，
//     结束后归还；池空时新建。长跑 git 命令不会霸占 SFTP / read_dir 的 mutex，
//     同一 target 的多条流互不阻塞，取消也不必排队。

use crate::connect;
use crate::state::{LockExt, SharedState, Target};
use anyhow::Context;
use ssh2::{Session, Sftp};
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// libssh2 blocking 调用的默认超时
pub const DEFAULT_TIMEOUT_MS: u32 = 10_000;

/// 每个 target 最多缓存的空闲 exec session 数
const EXEC_POOL_MAX: usize = 4;

// =============================================================================
// 共享会话
// =============================================================================

/// 单个 SSH 连接的资源容器
///
/// 包裹在 `Arc<Mutex<_>>` 里跨线程共享。libssh2 不是线程安全的，且同一会话上
/// 同时启动多个通道（SFTP / channel_session）会触发 CHANNEL_FAILURE，所以所
/// 有针对该会话的操作都必须串行化。
///
/// SFTP 通道在首次使用时打开并复用：每次操作都新开一个 SFTP 通道容易撞 sshd
/// 的 MaxSessions 上限。
pub struct ConnSession {
    pub session: Session,
    sftp: Option<Sftp>,
}

impl ConnSession {
    pub fn new(session: Session) -> Self {
        Self {
            session,
            sftp: None,
        }
    }

    /// 获取（或惰性创建）共享的 SFTP 通道
    pub fn sftp(&mut self) -> anyhow::Result<&Sftp> {
        if self.sftp.is_none() {
            let sftp = self
                .session
                .sftp()
                .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;
            self.sftp = Some(sftp);
        }
        Ok(self.sftp.as_ref().unwrap())
    }
}

/// 取出连接的 Arc 克隆，全局锁仅在查表时短暂持有
pub fn get_conn(state: &SharedState, t: &Target) -> anyhow::Result<Arc<Mutex<ConnSession>>> {
    let key = t.key();
    state
        .lock_ok()
        .sessions
        .get(&key)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("NOT_CONNECTED: {}", key))
}

/// 在共享会话上执行操作；若错误看起来是连接已死，则丢弃旧会话、重连一次后重试一次。
///
/// 回调只能持有 `&mut ConnSession`，不能借用 `state`，避免锁顺序冲突
/// （with_conn 在外层动态获取 state 锁来移除/重建 entry）。
pub fn with_conn<F, T>(state: &SharedState, t: &Target, mut f: F) -> anyhow::Result<T>
where
    F: FnMut(&mut ConnSession) -> anyhow::Result<T>,
{
    let conn = get_conn(state, t)?;
    let first_err = match run_on_conn(&conn, &mut f) {
        Err(e) if is_session_dead(&e) => e,
        r => return r,
    };
    debug_log!("Daemon: {} 连接异常 ({:#})，尝试自动重连...", t, first_err);

    // 把死会话从 state 里清掉，让 connect 走完整握手。
    // 只移除我们刚用过的那个 Arc：并发场景下别的线程可能已经重连好了新会话。
    {
        let mut st = state.lock_ok();
        let key = t.key();
        if st
            .sessions
            .get(&key)
            .is_some_and(|cur| Arc::ptr_eq(cur, &conn))
        {
            st.sessions.remove(&key);
        }
    }

    // password=None：connect 会回退到 state.passwords 里记住的密码
    connect::connect(t, None, state)
        .map_err(|re| anyhow::anyhow!("自动重连失败: {} (原错误: {:#})", re, first_err))?;
    debug_log!("Daemon: {} 重连成功，重试操作", t);
    let conn = get_conn(state, t)?;
    run_on_conn(&conn, &mut f)
}

/// 持锁执行一次回调；若错误表明 SFTP 子系统已坏，丢掉缓存的 SFTP 通道下次重建。
fn run_on_conn<F, T>(conn: &Mutex<ConnSession>, f: &mut F) -> anyhow::Result<T>
where
    F: FnMut(&mut ConnSession) -> anyhow::Result<T>,
{
    let mut guard = conn.lock_ok();
    let r = f(&mut guard);
    if let Err(e) = &r {
        if is_sftp_broken(e) {
            debug_log!("Daemon: SFTP 通道异常 ({:#})，下次操作时重建", e);
            guard.sftp = None;
        }
    }
    r
}

// =============================================================================
// exec 池（流式命令）
// =============================================================================

/// 从该 target 的空闲池里**取走**一个 exec session；池空则新建。
///
/// 返回 `(Session, pooled)`：pooled=true 表示是复用的旧会话（可能已静默断开，
/// 调用方在 channel 打开失败时可以丢弃并重建一次）。
pub fn exec_pool_take(state: &SharedState, t: &Target) -> anyhow::Result<(Session, bool)> {
    if let Some(sess) = state
        .lock_ok()
        .exec_pool
        .get_mut(&t.key())
        .and_then(Vec::pop)
    {
        return Ok((sess, true));
    }
    // 未缓存：建新 session（不持 state 锁完成握手）
    let sess = connect::open_dedicated_session(t, state)?;
    debug_log!("Daemon: exec session 已建立 {}", t);
    Ok((sess, false))
}

/// 把用完的 exec session 放回空闲池（超过上限则直接丢弃）。
pub fn exec_pool_put(state: &SharedState, t: &Target, sess: Session) {
    // 归还前恢复默认的 blocking + 超时，下一个借用者从干净状态开始
    sess.set_blocking(true);
    sess.set_timeout(DEFAULT_TIMEOUT_MS);
    let mut st = state.lock_ok();
    let pool = st.exec_pool.entry(t.key()).or_default();
    if pool.len() < EXEC_POOL_MAX {
        pool.push(sess);
    }
}

/// 清空 target 的 exec 池：下次 take 会重新握手。
/// 在重新握手（connect）或 `is_session_dead` 命中时调用——池里的会话大概率跟着
/// TCP 一起断了。
pub fn exec_pool_clear(state: &SharedState, t: &Target) {
    if state.lock_ok().exec_pool.remove(&t.key()).is_some() {
        debug_log!("Daemon: exec session 池已清空 {}", t);
    }
}

/// 后台预热一个 exec session 放进空闲池，让用户第一条 `cmd_stream`（典型场景：
/// `:Neogit` 触发的 git 命令）不必再付一次 200-500ms 握手代价。
///
/// 故意非阻塞：失败也只打日志，首条 cmd_stream 会自己新建。
pub fn exec_pool_warm(state: &SharedState, t: &Target) {
    if state
        .lock_ok()
        .exec_pool
        .get(&t.key())
        .is_some_and(|v| !v.is_empty())
    {
        return;
    }
    let (state, t) = (state.clone(), t.clone());
    std::thread::spawn(move || match connect::open_dedicated_session(&t, &state) {
        Ok(sess) => {
            exec_pool_put(&state, &t, sess);
            debug_log!("Daemon: exec session 预热完成 {}", t);
        }
        Err(e) => debug_log!("Daemon: exec session 预热失败 {}: {:#}", t, e),
    });
}

// =============================================================================
// 远程命令
// =============================================================================

pub struct ExecOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub code: i32,
}

/// 在会话上开一个 channel 执行 shell 命令并收集全部输出（blocking）。
///
/// 先读完 stdout 再读 stderr，只适合 stderr 很少的短命令；长命令 / 大量交错
/// 输出走 cmd::stream 的 non-blocking poll。
pub fn exec(session: &Session, cmd: &str, stdin: Option<&[u8]>) -> anyhow::Result<ExecOutput> {
    let mut ch = session.channel_session().context("无法开启 SSH 通道")?;
    ch.exec(cmd).context("远程执行失败")?;
    if let Some(data) = stdin {
        ch.write_all(data).context("写入 stdin 失败")?;
        ch.send_eof().context("send_eof 失败")?;
    }
    let mut stdout = Vec::new();
    ch.read_to_end(&mut stdout).context("读取 stdout 失败")?;
    let mut stderr = Vec::new();
    ch.stderr()
        .read_to_end(&mut stderr)
        .context("读取 stderr 失败")?;
    ch.wait_close().ok();
    Ok(ExecOutput {
        stdout,
        stderr,
        code: ch.exit_status().unwrap_or(-1),
    })
}

/// 在共享会话上执行一条短命令（经 with_conn，断连时自动重连重试）。
/// timeout 为命令级超时，结束后恢复会话原超时。
pub fn exec_shared(
    state: &SharedState,
    t: &Target,
    cmd: &str,
    stdin: Option<&[u8]>,
    timeout: Option<Duration>,
) -> anyhow::Result<ExecOutput> {
    with_conn(state, t, |conn| {
        let prev_timeout = conn.session.timeout();
        if let Some(d) = timeout {
            conn.session.set_timeout(d.as_millis() as u32);
        }
        let r = exec(&conn.session, cmd, stdin);
        conn.session.set_timeout(prev_timeout);
        r
    })
}

/// 单引号包裹，内部 ' 转成 '\''
pub fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

// =============================================================================
// 错误分类
// =============================================================================
// 先沿 source chain 找具体类型；再对完整错误链文本做字符串兜底——handler 用
// `anyhow!("...{}", e)` 包裹时 chain 里只剩字符串，ssh2 错误转成 io::Error 后
// 也只能从文本里认出 Session(n)。

fn ssh_code_in_chain(err: &anyhow::Error, pred: impl Fn(ssh2::ErrorCode) -> bool) -> bool {
    err.chain()
        .filter_map(|c| c.downcast_ref::<ssh2::Error>())
        .any(|e| pred(e.code()))
}

/// 判断错误是否表示 SSH 会话已经断开（broken pipe / socket disconnect 等）。
/// 命中即触发 with_conn 的自动重连重试。
///
/// 只匹配真正"socket 已死"的错误码，避免把协议层短暂错误（KEX_FAILURE / PROTO /
/// BAD_USE）当成断连——那些错误下旧会话往往还能继续工作，重连反而会引入幂等
/// 性问题（例如流式搜索的重复输出）。
///
/// **超时（TimedOut / LIBSSH2_ERROR_TIMEOUT -7）不算死会话**：超时的命令可能已经
/// 在远端执行（git commit / rename / exec_remote），重连后重跑会造成重复副作用。
pub fn is_session_dead(err: &anyhow::Error) -> bool {
    use std::io::ErrorKind::*;
    let io_dead = err
        .chain()
        .filter_map(|c| c.downcast_ref::<std::io::Error>())
        .any(|e| {
            matches!(
                e.kind(),
                BrokenPipe | ConnectionReset | ConnectionAborted | NotConnected | UnexpectedEof
            )
        });
    // -29 SOCKET_NONE / -43 SOCKET_DISCONNECT / -49 BAD_SOCKET
    let ssh_dead = ssh_code_in_chain(err, |c| {
        matches!(c, ssh2::ErrorCode::Session(-29 | -43 | -49))
    });
    if io_dead || ssh_dead {
        return true;
    }
    let s = format!("{:#}", err);
    [
        "Session(-29)",
        "Session(-43)",
        "Session(-49)",
        "Broken pipe",
        "Connection reset",
        "Connection aborted",
        "Socket disconnect",
        "unexpected end of file",
    ]
    .iter()
    .any(|p| s.contains(p))
}

/// 判断错误是否表示 SFTP 子系统（而非整个 SSH 会话）已坏。保守：只匹配协议级
/// 错误，普通 FX_* 状态（NO_SUCH_FILE / PERMISSION_DENIED / FAILURE）不算。
///   Session(-31) SFTP_PROTOCOL / Session(-26) CHANNEL_CLOSED
///   SFTP(6) FX_NO_CONNECTION   / SFTP(7) FX_CONNECTION_LOST
pub fn is_sftp_broken(err: &anyhow::Error) -> bool {
    use ssh2::ErrorCode::{Session as S, SFTP};
    if ssh_code_in_chain(err, |c| matches!(c, S(-31 | -26) | SFTP(6 | 7))) {
        return true;
    }
    let s = format!("{:#}", err);
    ["Session(-31)", "Session(-26)", "SFTP(6)", "SFTP(7)"]
        .iter()
        .any(|p| s.contains(p))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_quote_basic() {
        assert_eq!(shell_quote("hello"), "'hello'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
        assert_eq!(shell_quote("a b"), "'a b'");
    }

    #[test]
    fn timeouts_are_not_dead_sessions() {
        let io = std::io::Error::new(std::io::ErrorKind::TimedOut, "timed out");
        assert!(!is_session_dead(&anyhow::Error::new(io)));
        let ssh = ssh2::Error::from_errno(ssh2::ErrorCode::Session(-7));
        assert!(!is_session_dead(&anyhow::Error::new(ssh)));
        assert!(!is_session_dead(&anyhow::anyhow!(
            "exec 失败: [Session(-7)] timed out"
        )));
    }

    #[test]
    fn socket_errors_are_dead_sessions() {
        let io = std::io::Error::new(std::io::ErrorKind::BrokenPipe, "x");
        assert!(is_session_dead(&anyhow::Error::new(io)));
        let ssh = ssh2::Error::from_errno(ssh2::ErrorCode::Session(-43));
        assert!(is_session_dead(&anyhow::Error::new(ssh)));
        assert!(is_session_dead(&anyhow::anyhow!(
            "读目录失败 /x: [Session(-43)] socket disconnected"
        )));
        assert!(!is_session_dead(&anyhow::anyhow!(
            "stat 失败 /x: [SFTP(2)] no such file"
        )));
    }

    #[test]
    fn dead_session_detected_through_context() {
        // ssh2 错误转成 io::Error(Other) 后再被 .context() 包一层
        let io = std::io::Error::other("[Session(-43)] socket disconnected");
        let err = anyhow::Error::new(io).context("读取 stdout 失败");
        assert!(is_session_dead(&err));
    }

    #[test]
    fn sftp_broken_classification() {
        assert!(is_sftp_broken(&anyhow::anyhow!(
            "读目录失败 /x: [Session(-31)] sftp protocol error"
        )));
        assert!(is_sftp_broken(&anyhow::Error::new(
            ssh2::Error::from_errno(ssh2::ErrorCode::SFTP(7))
        )));
        assert!(!is_sftp_broken(&anyhow::anyhow!(
            "stat 失败 /x: [SFTP(2)] no such file"
        )));
        assert!(!is_sftp_broken(&anyhow::anyhow!(
            "删除失败 /x: [SFTP(3)] permission denied"
        )));
    }
}
