// =============================================================================
// connect.rs — SSH 连接建立
// =============================================================================
// 实现 connect RPC 方法。
// 认证策略按优先级: SSH Agent → Config IdentityFile → 默认密钥 → 密码
//
// 模块对外提供两个入口：
//   - handle_connect:    RPC handler，建好 Session 后插到 state.sessions
//   - open_dedicated_session: 给流式命令用，建好返回，不入 state（解耦长命令与 SFTP 池）

use crate::state::{ConnSession, DaemonState, ProjectCache};
use rmpv::Value;
use socket2::{Socket, TcpKeepalive};
use ssh2::Session;
use ssh2_config::SshConfig;
use std::collections::HashMap;
use std::net::TcpStream;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub fn handle_connect(
    user: &str,
    host: &str,
    port: u16,
    password: Option<&str>,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    let key = DaemonState::connection_key(user, host, port);

    // ── 检查是否已有有效连接 ──
    let existing = {
        let state_lock = state.lock().unwrap();
        state_lock.sessions.get(&key).cloned()
    };
    if let Some(conn) = existing {
        let guard = conn.lock().unwrap();
        if guard.session.authenticated() {
            return Ok(Value::Boolean(true));
        }
    }

    // 拿一份 ssh_config 的克隆，认证期间不持 state 锁
    let ssh_config = {
        let state_lock = state.lock().unwrap();
        state_lock.ssh_config.clone()
    };

    let sess = open_session(user, host, port, password, ssh_config.as_ref())?;

    // ── 保存会话；缓存若已存在则保留（自动重连时不应清空目录缓存）──
    let mut state_lock = state.lock().unwrap();
    state_lock
        .sessions
        .insert(key.clone(), Arc::new(Mutex::new(ConnSession::new(sess))));
    state_lock
        .caches
        .entry(key.clone())
        .or_insert_with(|| ProjectCache {
            directories: HashMap::new(),
        });
    eprintln!("Daemon: 已连接 {}", key);
    Ok(Value::Boolean(true))
}

/// 给流式命令使用的独占 Session。
///
/// 不入 `state.sessions`，调用方自己管理生命周期（drop 即关闭）。这样长跑的
/// 流式命令不会霸占 `with_conn` 的 Mutex，SFTP / read_dir / 别的操作可以并行。
///
/// 使用 `state` 仅为读取 ssh_config；密码鉴权当前未支持（流式命令一般在已建立
/// 的会话之后触发，对应主机的 password 不会被持久化）。如需支持，可在调用层传入。
pub fn open_dedicated_session(
    user: &str,
    host: &str,
    port: u16,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Session, anyhow::Error> {
    let ssh_config = {
        let state_lock = state.lock().unwrap();
        state_lock.ssh_config.clone()
    };
    open_session(user, host, port, None, ssh_config.as_ref())
}

/// 实际打开会话：TCP 连接 + handshake + 认证。
///
/// 与 `handle_connect` 拆分是为了让 `open_dedicated_session` 复用同一套认证逻辑。
fn open_session(
    user: &str,
    host: &str,
    port: u16,
    password: Option<&str>,
    ssh_config: Option<&SshConfig>,
) -> Result<Session, anyhow::Error> {
    // ── 建立 TCP 连接和 SSH 握手 ──
    let tcp = TcpStream::connect(format!("{}:{}", host, port))?;
    tcp.set_nodelay(true)?;

    // 开启 TCP keepalive：长时间空闲或网络切换后内核会主动探测对端，
    // 死连接会更快变为 BrokenPipe，让 with_conn 的自动重连能及时触发。
    let socket: Socket = tcp.into();
    let keepalive = TcpKeepalive::new()
        .with_time(Duration::from_secs(60))
        .with_interval(Duration::from_secs(15));
    if let Err(e) = socket.set_tcp_keepalive(&keepalive) {
        eprintln!("Daemon: 设置 TCP keepalive 失败 (忽略): {}", e);
    }
    let tcp: TcpStream = socket.into();

    let mut sess = Session::new()?;
    sess.set_tcp_stream(tcp);
    sess.set_timeout(10000);
    sess.handshake()
        .map_err(|e| anyhow::anyhow!("握手失败: {}", e))?;

    let mut authenticated = false;

    // ── 认证策略 1: SSH Agent ──
    if let Ok(mut agent) = sess.agent() {
        if agent.connect().is_ok() {
            if agent.list_identities().is_ok() {
                if let Ok(identities) = agent.identities() {
                    for identity in identities {
                        if agent.userauth(user, &identity).is_ok() {
                            authenticated = true;
                            break;
                        }
                    }
                }
            }
        }
    }

    // ── 认证策略 2: SSH Config 中的 IdentityFile ──
    if !authenticated {
        if let Some(config) = ssh_config {
            let params = config.query(host);
            if let Some(files) = params.identity_file.clone() {
                for key_path in &files {
                    let expanded = if key_path.starts_with("~") {
                        if let Some(home) = dirs::home_dir() {
                            home.join(key_path.strip_prefix("~").unwrap_or(key_path))
                        } else {
                            key_path.clone()
                        }
                    } else {
                        key_path.clone()
                    };
                    if expanded.exists()
                        && sess
                            .userauth_pubkey_file(user, None, &expanded, None)
                            .is_ok()
                    {
                        authenticated = true;
                        break;
                    }
                }
            }
        }
    }

    // ── 认证策略 3: 默认密钥文件（~/.ssh/id_*）──
    if !authenticated {
        if let Some(home) = dirs::home_dir() {
            let ssh_dir = home.join(".ssh");
            let default_keys = ["id_ed25519", "id_rsa", "id_ecdsa", "id_dsa"];
            for key_name in &default_keys {
                let priv_key_path = ssh_dir.join(key_name);
                if priv_key_path.exists()
                    && sess
                        .userauth_pubkey_file(user, None, &priv_key_path, None)
                        .is_ok()
                {
                    authenticated = true;
                    break;
                }
            }
        }
    }

    // ── 认证策略 4: 密码 ──
    if !authenticated {
        if let Some(pwd) = password {
            if sess.userauth_password(user, pwd).is_ok() {
                authenticated = true;
            }
        }
    }

    if !authenticated {
        return Err(anyhow::anyhow!(
            "AUTH_FAILED: 认证失败 {}@{}:{}",
            user,
            host,
            port
        ));
    }

    Ok(sess)
}
