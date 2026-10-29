// =============================================================================
// state.rs — Daemon 全局状态和数据结构
// =============================================================================

use ssh2::{Session, Sftp};
use ssh2_config::{ParseRule, SshConfig};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

/// 容忍 poison 的加锁：某个 worker 线程 panic 时不应让整个 daemon 后续所有
/// 请求都跟着 panic。共享状态在 panic 点上最多是"半更新"，对缓存 / 注册表
/// 这类数据来说可接受。
pub trait LockExt<T> {
    fn lock_ok(&self) -> MutexGuard<'_, T>;
}

impl<T> LockExt<T> for Mutex<T> {
    fn lock_ok(&self) -> MutexGuard<'_, T> {
        self.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// 单个目录项（文件或文件夹）
#[derive(Clone, Debug)]
pub struct DirEntry {
    pub name: String,
    pub file_type: String, // "directory" | "file"
}

/// 目录缓存条目的有效期：过期后 read_dir 会重新走 SFTP，让外部改动
/// （git checkout、远端其他进程写文件）最终能被看到。
pub const DIR_CACHE_TTL: Duration = Duration::from_secs(30);

struct CachedDir {
    entries: Vec<DirEntry>,
    at: Instant,
}

/// 按连接维度的目录缓存
#[derive(Default)]
pub struct ProjectCache {
    directories: HashMap<PathBuf, CachedDir>,
}

impl ProjectCache {
    pub fn new() -> Self {
        Self::default()
    }

    /// 取未过期的目录列表
    pub fn get(&self, path: &Path) -> Option<&Vec<DirEntry>> {
        self.get_at(path, Instant::now())
    }

    fn get_at(&self, path: &Path, now: Instant) -> Option<&Vec<DirEntry>> {
        self.directories
            .get(path)
            .filter(|c| now.saturating_duration_since(c.at) < DIR_CACHE_TTL)
            .map(|c| &c.entries)
    }

    pub fn insert(&mut self, path: PathBuf, entries: Vec<DirEntry>) {
        self.directories.insert(
            path,
            CachedDir {
                entries,
                at: Instant::now(),
            },
        );
    }

    /// 只失效父目录的列表（新建 / 删除 / 写入单个文件）
    pub fn invalidate_parent(&mut self, path: &Path) {
        if let Some(parent) = path.parent() {
            self.directories.remove(parent);
        }
    }

    /// 失效 path 本身、它的所有后代、以及父目录的列表（rename / rmdir）
    pub fn invalidate_tree(&mut self, path: &Path) {
        self.directories.retain(|k, _| !k.starts_with(path));
        self.invalidate_parent(path);
    }

    #[cfg(test)]
    fn contains(&self, path: &str) -> bool {
        self.directories.contains_key(Path::new(path))
    }
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
        Self {
            session,
            sftp: None,
        }
    }

    /// 获取（或惰性创建）共享的 SFTP 通道
    pub fn sftp(&mut self) -> Result<&Sftp, ssh2::Error> {
        if self.sftp.is_none() {
            self.sftp = Some(self.session.sftp()?);
        }
        Ok(self.sftp.as_ref().unwrap())
    }

    /// 丢掉缓存的 SFTP 通道，下次 sftp() 时重新打开。
    /// 用于 SSH 会话还活着、但 SFTP 子系统已坏的情况。
    pub fn reset_sftp(&mut self) {
        self.sftp = None;
    }
}

/// Daemon 全局状态
pub struct DaemonState {
    /// 已建立的 SSH 会话，key 格式: "user@host:port"
    ///
    /// 只有认证成功的会话才会被插入；with_conn 检测到会话死亡时会将其移除。
    pub sessions: HashMap<String, Arc<Mutex<ConnSession>>>,
    /// 每个连接对应的目录缓存
    pub caches: HashMap<String, ProjectCache>,
    /// 解析后的 SSH 配置（启动时加载一次）
    pub ssh_config: Option<SshConfig>,
    /// 流式命令注册表：session_id → 句柄。供 cmd_cancel RPC 查询。
    pub running_commands: Arc<Mutex<crate::cmd::CmdRegistry>>,
    /// 流式命令的空闲 SSH 会话池，key 格式: "user@host:port"
    ///
    /// 与 `sessions`（SFTP 共享池）解耦：避免长跑 git 命令霸占 SFTP / read_dir
    /// 的 mutex。每条 cmd_stream 从池中**取走**一个 Session 独占使用，结束后归还；
    /// 池为空时新建。这样同一 target 的多条流互不阻塞，取消也不必排队。
    pub exec_sessions: HashMap<String, Vec<Session>>,
    /// connect 时用过的密码（仅内存），自动重连 / 新开流式会话时复用
    pub passwords: HashMap<String, String>,
    /// 每个 target 的建连互斥锁：防止并发请求同时为同一 target 握手
    pub connect_locks: HashMap<String, Arc<Mutex<()>>>,
}

impl DaemonState {
    pub fn new() -> Self {
        // 启动时尝试解析 ~/.ssh/config
        let ssh_config = Self::load_ssh_config();
        Self {
            sessions: HashMap::new(),
            caches: HashMap::new(),
            ssh_config,
            running_commands: Arc::new(Mutex::new(crate::cmd::CmdRegistry::new())),
            exec_sessions: HashMap::new(),
            passwords: HashMap::new(),
            connect_locks: HashMap::new(),
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
        let state_lock = state.lock_ok();
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
        let conn = Self::get_conn(state, &key)?;
        let first = run_on_conn(&conn, &mut f);

        let first_err = match first {
            Ok(v) => return Ok(v),
            Err(e) if is_session_dead(&e) => e,
            Err(e) => return Err(e),
        };

        debug_log!("Daemon: {} 连接异常 ({})，尝试自动重连...", key, first_err);

        // 把死会话从 state 里清掉，让 handle_connect 走完整握手。
        // 只移除我们刚用过的那个 Arc：并发场景下别的线程可能已经重连好了新会话。
        {
            let mut state_lock = state.lock_ok();
            if let Some(cur) = state_lock.sessions.get(&key) {
                if Arc::ptr_eq(cur, &conn) {
                    state_lock.sessions.remove(&key);
                }
            }
        }

        // password=None：handle_connect 会回退到 state.passwords 里记住的密码
        crate::connect::handle_connect(user, host, port, None, state)
            .map_err(|re| anyhow::anyhow!("自动重连失败: {} (原错误: {})", re, first_err))?;
        debug_log!("Daemon: {} 重连成功，重试操作", key);

        // 第二次尝试 — 用新会话
        let conn = Self::get_conn(state, &key)?;
        run_on_conn(&conn, &mut f)
    }
}

/// 持锁执行一次回调；若错误表明 SFTP 子系统已坏，顺手丢掉缓存的 SFTP 通道。
fn run_on_conn<F, T>(conn: &Arc<Mutex<ConnSession>>, f: &mut F) -> Result<T, anyhow::Error>
where
    F: FnMut(&mut ConnSession) -> Result<T, anyhow::Error>,
{
    let mut guard = conn.lock_ok();
    let r = f(&mut guard);
    if let Err(e) = &r {
        if is_sftp_broken(e) {
            debug_log!("Daemon: SFTP 通道异常 ({})，下次操作时重建", e);
            guard.reset_sftp();
        }
    }
    r
}

/// 判断错误是否表示 SSH 会话已经断开（broken pipe / socket disconnect / libssh2 socket 错误等）。
/// 命中即触发 with_conn 的自动重连重试。
///
/// 只匹配真正"socket 已死"的错误码，避免把协议层短暂错误（KEX_FAILURE / PROTO /
/// BAD_USE）当成断连——那些错误下旧会话往往还能继续工作，重连反而会引入幂等
/// 性问题（例如流式搜索的重复输出）。
///
/// **超时（TimedOut / LIBSSH2_ERROR_TIMEOUT -7）不算死会话**：超时的命令可能已经
/// 在远端执行（git commit / rename / exec_remote），重连后重跑会造成重复副作用。
pub fn is_session_dead(err: &anyhow::Error) -> bool {
    // 沿 source chain 查找具体类型 — 当 handler 用 `.context()` 包裹时有效
    for cause in err.chain() {
        if let Some(io_err) = cause.downcast_ref::<std::io::Error>() {
            use std::io::ErrorKind::*;
            if matches!(
                io_err.kind(),
                BrokenPipe | ConnectionReset | ConnectionAborted | NotConnected | UnexpectedEof
            ) {
                return true;
            }
        }
        if let Some(ssh_err) = cause.downcast_ref::<ssh2::Error>() {
            if let ssh2::ErrorCode::Session(c) = ssh_err.code() {
                // -29 LIBSSH2_ERROR_SOCKET_NONE
                // -43 LIBSSH2_ERROR_SOCKET_DISCONNECT
                // -49 LIBSSH2_ERROR_BAD_SOCKET
                if matches!(c, -29 | -43 | -49) {
                    return true;
                }
            }
        }
    }

    // 字符串兜底 — 当 handler 用 `anyhow!("...{}", e)` 形式包裹时，
    // chain 里就只剩下我们自己写的字符串，需要按特征字符串匹配。
    let s = err.to_string();
    s.contains("Session(-29)")          // LIBSSH2_ERROR_SOCKET_NONE
        || s.contains("Session(-43)")  // LIBSSH2_ERROR_SOCKET_DISCONNECT
        || s.contains("Session(-49)")  // LIBSSH2_ERROR_BAD_SOCKET
        || s.contains("Broken pipe")
        || s.contains("Connection reset")
        || s.contains("Connection aborted")
        || s.contains("Socket disconnect")
        || s.contains("unexpected end of file")
}

/// 判断错误是否表示 SFTP 子系统（而非整个 SSH 会话）已坏。保守：只匹配协议级
/// 错误，普通 FX_* 状态（NO_SUCH_FILE / PERMISSION_DENIED / FAILURE）不算。
///   Session(-31) LIBSSH2_ERROR_SFTP_PROTOCOL
///   Session(-26) LIBSSH2_ERROR_CHANNEL_CLOSED
///   SFTP(6)      FX_NO_CONNECTION
///   SFTP(7)      FX_CONNECTION_LOST
pub fn is_sftp_broken(err: &anyhow::Error) -> bool {
    for cause in err.chain() {
        if let Some(ssh_err) = cause.downcast_ref::<ssh2::Error>() {
            match ssh_err.code() {
                ssh2::ErrorCode::Session(-31) | ssh2::ErrorCode::Session(-26) => return true,
                ssh2::ErrorCode::SFTP(6) | ssh2::ErrorCode::SFTP(7) => return true,
                _ => {}
            }
        }
    }
    let s = err.to_string();
    s.contains("Session(-31)")
        || s.contains("Session(-26)")
        || s.contains("SFTP(6)")
        || s.contains("SFTP(7)")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(name: &str) -> Vec<DirEntry> {
        vec![DirEntry {
            name: name.to_string(),
            file_type: "file".to_string(),
        }]
    }

    #[test]
    fn invalidate_tree_removes_path_descendants_and_parent() {
        let mut c = ProjectCache::new();
        for p in ["/a", "/a/b", "/a/b/c", "/a/b/c/d", "/a/bb", "/x"] {
            c.insert(PathBuf::from(p), entry("f"));
        }
        c.invalidate_tree(Path::new("/a/b"));
        assert!(!c.contains("/a")); // parent
        assert!(!c.contains("/a/b"));
        assert!(!c.contains("/a/b/c"));
        assert!(!c.contains("/a/b/c/d"));
        assert!(c.contains("/a/bb")); // 前缀相同但不是后代
        assert!(c.contains("/x"));
    }

    #[test]
    fn invalidate_parent_only_touches_parent() {
        let mut c = ProjectCache::new();
        c.insert(PathBuf::from("/a"), entry("f"));
        c.insert(PathBuf::from("/a/f"), entry("g"));
        c.invalidate_parent(Path::new("/a/f"));
        assert!(!c.contains("/a"));
        assert!(c.contains("/a/f"));
    }

    #[test]
    fn cache_entries_expire_after_ttl() {
        let mut c = ProjectCache::new();
        c.insert(PathBuf::from("/a"), entry("f"));
        let now = Instant::now();
        assert!(c.get_at(Path::new("/a"), now).is_some());
        assert!(c
            .get_at(Path::new("/a"), now + DIR_CACHE_TTL + Duration::from_secs(1))
            .is_none());
        // 末尾斜杠按组件比较，视为同一路径
        assert!(c.get(Path::new("/a/")).is_some());
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
