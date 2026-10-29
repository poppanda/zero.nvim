// =============================================================================
// state.rs — Daemon 全局状态和数据结构
// =============================================================================

use crate::cmd::CmdHandle;
use crate::session::ConnSession;
use ssh2::Session;
use ssh2_config::{ParseRule, SshConfig};
use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

pub type SharedState = Arc<Mutex<DaemonState>>;

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

/// 远程连接目标；Display / key 格式: "user@host:port"
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub user: String,
    pub host: String,
    pub port: u16,
}

impl Target {
    pub fn new(user: impl Into<String>, host: impl Into<String>, port: u16) -> Self {
        Self {
            user: user.into(),
            host: host.into(),
            port,
        }
    }

    pub fn key(&self) -> String {
        self.to_string()
    }
}

impl fmt::Display for Target {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}@{}:{}", self.user, self.host, self.port)
    }
}

/// 单个目录项（文件或文件夹）
#[derive(Clone, Debug)]
pub struct DirEntry {
    pub name: String,
    pub is_dir: bool,
}

/// 目录缓存条目的有效期：过期后 read_dir 会重新走 SFTP，让外部改动
/// （git checkout、远端其他进程写文件）最终能被看到。
pub const DIR_CACHE_TTL: Duration = Duration::from_secs(30);

/// 按连接维度的目录缓存
#[derive(Default)]
pub struct DirCache {
    directories: HashMap<PathBuf, (Vec<DirEntry>, Instant)>,
}

impl DirCache {
    /// 取未过期的目录列表
    pub fn get(&self, path: &Path) -> Option<&[DirEntry]> {
        self.get_at(path, Instant::now())
    }

    fn get_at(&self, path: &Path, now: Instant) -> Option<&[DirEntry]> {
        self.directories
            .get(path)
            .filter(|(_, at)| now.saturating_duration_since(*at) < DIR_CACHE_TTL)
            .map(|(entries, _)| entries.as_slice())
    }

    pub fn insert(&mut self, path: PathBuf, entries: Vec<DirEntry>) {
        self.directories.insert(path, (entries, Instant::now()));
    }

    /// 只失效父目录的列表（新建 / 删除 / 写入单个文件）
    pub fn invalidate_parent(&mut self, path: &Path) {
        if let Some(parent) = path.parent() {
            self.directories.remove(parent);
        }
    }

    /// 失效 path 本身、它的所有后代、以及父目录的列表（rename / mkdir / rmdir）
    pub fn invalidate_tree(&mut self, path: &Path) {
        self.directories.retain(|k, _| !k.starts_with(path));
        self.invalidate_parent(path);
    }

    #[cfg(test)]
    fn contains(&self, path: &str) -> bool {
        self.directories.contains_key(Path::new(path))
    }
}

/// Daemon 全局状态。以下 HashMap 的 key 都是 `Target::key()`。
///
/// 全局锁只在查表 / 改表时短暂持有，任何网络 IO 都不在持锁期间进行。
#[derive(Default)]
pub struct DaemonState {
    /// 已认证的共享 SSH 会话（SFTP / 短命令）；with_conn 检测到会话死亡时移除
    pub sessions: HashMap<String, Arc<Mutex<ConnSession>>>,
    /// 流式命令的空闲 SSH 会话池（见 session.rs）
    pub exec_pool: HashMap<String, Vec<Session>>,
    /// 每个连接对应的目录缓存
    pub caches: HashMap<String, DirCache>,
    /// connect 时用过的密码（仅内存），自动重连 / 新开流式会话时复用
    pub passwords: HashMap<String, String>,
    /// 每个 target 的建连互斥锁：防止并发请求同时为同一 target 握手
    pub connect_locks: HashMap<String, Arc<Mutex<()>>>,
    /// 正在跑的流式命令：session_id（Lua 端生成）→ 句柄
    pub commands: HashMap<String, Arc<CmdHandle>>,
    /// 解析后的 ~/.ssh/config（启动时加载一次）
    pub ssh_config: Option<SshConfig>,
}

impl DaemonState {
    pub fn new() -> Self {
        Self {
            ssh_config: load_ssh_config(),
            ..Self::default()
        }
    }
}

/// 读取并解析 ~/.ssh/config 文件
fn load_ssh_config() -> Option<SshConfig> {
    let config_path = dirs::home_dir()?.join(".ssh").join("config");
    let file = std::fs::File::open(&config_path).ok()?;
    let mut reader = std::io::BufReader::new(file);
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

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(name: &str) -> Vec<DirEntry> {
        vec![DirEntry {
            name: name.to_string(),
            is_dir: false,
        }]
    }

    #[test]
    fn invalidate_tree_removes_path_descendants_and_parent() {
        let mut c = DirCache::default();
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
        let mut c = DirCache::default();
        c.insert(PathBuf::from("/a"), entry("f"));
        c.insert(PathBuf::from("/a/f"), entry("g"));
        c.invalidate_parent(Path::new("/a/f"));
        assert!(!c.contains("/a"));
        assert!(c.contains("/a/f"));
    }

    #[test]
    fn cache_entries_expire_after_ttl() {
        let mut c = DirCache::default();
        c.insert(PathBuf::from("/a"), entry("f"));
        let now = Instant::now();
        assert!(c.get_at(Path::new("/a"), now).is_some());
        assert!(c
            .get_at(
                Path::new("/a"),
                now + DIR_CACHE_TTL + Duration::from_secs(1)
            )
            .is_none());
        // 末尾斜杠按组件比较，视为同一路径
        assert!(c.get(Path::new("/a/")).is_some());
    }

    #[test]
    fn target_key_format() {
        assert_eq!(Target::new("u", "h", 2222).key(), "u@h:2222");
    }
}
