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
}
