// =============================================================================
// state.rs — Daemon 全局状态和数据结构
// =============================================================================

use ssh2::{Session, Sftp};
use ssh2_config::{ParseRule, SshConfig};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// 单个目录项（文件或文件夹）
#[derive(Clone, Debug)]
pub struct DirEntry {
    pub name: String,
    pub file_type: String, // "directory" | "file"
}

/// 按连接维度的目录缓存
pub struct ProjectCache {
    pub directories: HashMap<PathBuf, Vec<DirEntry>>,
}

/// 单个 SSH 连接的资源容器
///
/// 包裹在 `Arc<Mutex<_>>` 里跨线程共享。libssh2 不是线程安全的，且同一会话上
/// 同时启动多个通道（SFTP / channel_session）会触发 CHANNEL_FAILURE，所以所
/// 有针对该会话的操作都必须串行化。
///
/// `sftp` 字段在首次使用时打开并复用：每次写文件、读目录都新开一个 SFTP 通道
/// 容易撞 sshd 的 MaxSessions 上限，缓存后所有 SFTP 操作走同一个通道。
pub struct ConnSession {
    pub session: Session,
    sftp: Option<Sftp>,
}

impl ConnSession {
    pub fn new(session: Session) -> Self {
        Self { session, sftp: None }
    }

    /// 获取（或惰性创建）共享的 SFTP 通道
    pub fn sftp(&mut self) -> Result<&Sftp, ssh2::Error> {
        if self.sftp.is_none() {
            self.sftp = Some(self.session.sftp()?);
        }
        Ok(self.sftp.as_ref().unwrap())
    }
}

/// Daemon 全局状态
pub struct DaemonState {
    /// 已建立的 SSH 会话，key 格式: "user@host:port"
    pub sessions: HashMap<String, Arc<Mutex<ConnSession>>>,
    /// 每个连接对应的目录缓存
    pub caches: HashMap<String, ProjectCache>,
    /// 解析后的 SSH 配置（启动时加载一次）
    pub ssh_config: Option<SshConfig>,
}

impl DaemonState {
    pub fn new() -> Self {
        // 启动时尝试解析 ~/.ssh/config
        let ssh_config = Self::load_ssh_config();
        Self {
            sessions: HashMap::new(),
            caches: HashMap::new(),
            ssh_config,
        }
    }

    /// 读取并解析 ~/.ssh/config 文件
    fn load_ssh_config() -> Option<SshConfig> {
        let home = dirs::home_dir()?;
        let config_path = home.join(".ssh").join("config");
        let mut file = std::fs::File::open(&config_path).ok()?;
        let mut reader = std::io::BufReader::new(&mut file);
        // ALLOW_UNKNOWN_FIELDS 模式更宽容，跳过未知指令
        match SshConfig::default().parse(&mut reader, ParseRule::ALLOW_UNKNOWN_FIELDS) {
            Ok(config) => Some(config),
            Err(e) => {
                eprintln!(
                    "Daemon: SSH 配置解析失败: {} — {}",
                    config_path.display(),
                    e
                );
                None
            }
        }
    }

    /// 生成连接 key: "user@host:port"
    pub fn connection_key(user: &str, host: &str, port: u16) -> String {
        format!("{}@{}:{}", user, host, port)
    }

    /// 取出连接的 Arc 克隆，全局锁仅在查表时短暂持有；调用方再 lock 该 conn 做操作
    pub fn get_conn(
        state: &Arc<Mutex<Self>>,
        key: &str,
    ) -> Result<Arc<Mutex<ConnSession>>, anyhow::Error> {
        let state_lock = state.lock().unwrap();
        state_lock
            .sessions
            .get(key)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("NOT_CONNECTED: {}", key))
    }

    /// 在会话上执行操作；若错误看起来是连接已死，则丢弃旧会话、重连一次后重试一次。
    ///
    /// 回调只能持有 `&mut ConnSession`，不能借用 `state`，避免锁顺序冲突
    /// （with_conn 在外层动态获取 state 锁来移除/重建 entry）。
    pub fn with_conn<F, T>(
        state: &Arc<Mutex<Self>>,
        user: &str,
        host: &str,
        port: u16,
        mut f: F,
    ) -> Result<T, anyhow::Error>
    where
        F: FnMut(&mut ConnSession) -> Result<T, anyhow::Error>,
    {
        let key = Self::connection_key(user, host, port);

        // 第一次尝试 — 用现有会话
        let first = {
            let conn = Self::get_conn(state, &key)?;
            let mut guard = conn.lock().unwrap();
            f(&mut guard)
        };

        let first_err = match first {
            Ok(v) => return Ok(v),
            Err(e) if is_session_dead(&e) => e,
            Err(e) => return Err(e),
        };

        eprintln!(
            "Daemon: {} 连接异常 ({})，尝试自动重连...",
            key, first_err
        );

        // 把死会话从 state 里清掉，让 handle_connect 走完整握手
        {
            let mut state_lock = state.lock().unwrap();
            state_lock.sessions.remove(&key);
        }

        crate::connect::handle_connect(user, host, port, None, state)
            .map_err(|re| anyhow::anyhow!("自动重连失败: {} (原错误: {})", re, first_err))?;
        eprintln!("Daemon: {} 重连成功，重试操作", key);

        // 第二次尝试 — 用新会话
        let conn = Self::get_conn(state, &key)?;
        let mut guard = conn.lock().unwrap();
        f(&mut guard)
    }
}

/// 判断错误是否表示 SSH 会话已经断开（broken pipe / socket disconnect / libssh2 socket 错误等）。
/// 命中即触发 with_conn 的自动重连重试。
///
/// 只匹配真正"socket 已死"的错误码，避免把协议层短暂错误（KEX_FAILURE / PROTO /
/// BAD_USE）当成断连——那些错误下旧会话往往还能继续工作，重连反而会引入幂等
/// 性问题（例如流式搜索的重复输出）。
fn is_session_dead(err: &anyhow::Error) -> bool {
    // 沿 source chain 查找具体类型 — 当 handler 用 `.context()` 包裹时有效
    for cause in err.chain() {
        if let Some(io_err) = cause.downcast_ref::<std::io::Error>() {
            use std::io::ErrorKind::*;
            if matches!(
                io_err.kind(),
                BrokenPipe
                    | ConnectionReset
                    | ConnectionAborted
                    | NotConnected
                    | UnexpectedEof
                    | TimedOut
            ) {
                return true;
            }
        }
        if let Some(ssh_err) = cause.downcast_ref::<ssh2::Error>() {
            if let ssh2::ErrorCode::Session(c) = ssh_err.code() {
                // -7  LIBSSH2_ERROR_TIMEOUT
                // -29 LIBSSH2_ERROR_SOCKET_NONE
                // -43 LIBSSH2_ERROR_SOCKET_DISCONNECT
                // -49 LIBSSH2_ERROR_BAD_SOCKET
                if matches!(c, -7 | -29 | -43 | -49) {
                    return true;
                }
            }
        }
    }

    // 字符串兜底 — 当 handler 用 `anyhow!("...{}", e)` 形式包裹时，
    // chain 里就只剩下我们自己写的字符串，需要按特征字符串匹配。
    let s = err.to_string();
    s.contains("Session(-7)")          // LIBSSH2_ERROR_TIMEOUT
        || s.contains("Session(-29)")  // LIBSSH2_ERROR_SOCKET_NONE
        || s.contains("Session(-43)")  // LIBSSH2_ERROR_SOCKET_DISCONNECT
        || s.contains("Session(-49)")  // LIBSSH2_ERROR_BAD_SOCKET
        || s.contains("Broken pipe")
        || s.contains("Connection reset")
        || s.contains("Connection aborted")
        || s.contains("Socket disconnect")
        || s.contains("unexpected end of file")
}
