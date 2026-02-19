// =============================================================================
// state.rs — Daemon 全局状态和数据结构
// =============================================================================

use ssh2::Session;
use ssh2_config::{ParseRule, SshConfig};
use std::collections::HashMap;
use std::path::PathBuf;

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

/// Daemon 全局状态
pub struct DaemonState {
    /// 已建立的 SSH 会话，key 格式: "user@host:port"
    pub sessions: HashMap<String, Session>,
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
            Ok(config) => {
                eprintln!("Daemon: 成功解析 SSH 配置: {}", config_path.display());
                Some(config)
            }
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
}
