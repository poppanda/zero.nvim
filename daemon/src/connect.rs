// =============================================================================
// connect.rs — SSH 连接建立
// =============================================================================
// 实现 connect RPC 方法。
// 认证策略按优先级: SSH Agent → Config IdentityFile → 默认密钥 → 密码

use crate::state::{ConnSession, DaemonState, ProjectCache};
use rmpv::Value;
use ssh2::Session;
use std::collections::HashMap;
use std::net::TcpStream;
use std::sync::{Arc, Mutex};

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

    // ── 建立 TCP 连接和 SSH 握手 ──
    let tcp = TcpStream::connect(format!("{}:{}", host, port))?;
    tcp.set_nodelay(true)?;
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
        let identity_files = {
            let state_lock = state.lock().unwrap();
            if let Some(ref config) = state_lock.ssh_config {
                let params = config.query(host);
                params.identity_file.clone()
            } else {
                None
            }
        };

        if let Some(files) = identity_files {
            for key_path in &files {
                // 展开 ~ 为实际 home 路径
                let expanded = if key_path.starts_with("~") {
                    if let Some(home) = dirs::home_dir() {
                        home.join(key_path.strip_prefix("~").unwrap_or(key_path))
                    } else {
                        key_path.clone()
                    }
                } else {
                    key_path.clone()
                };

                if expanded.exists() {
                    if sess
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
            // 按 OpenSSH 默认优先级排列
            let default_keys = ["id_ed25519", "id_rsa", "id_ecdsa", "id_dsa"];
            for key_name in &default_keys {
                let priv_key_path = ssh_dir.join(key_name);
                if priv_key_path.exists() {
                    if sess
                        .userauth_pubkey_file(user, None, &priv_key_path, None)
                        .is_ok()
                    {
                        authenticated = true;
                        break;
                    }
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
        return Err(anyhow::anyhow!("AUTH_FAILED: 认证失败 {}", key));
    }

    // ── 保存会话和初始化缓存 ──
    let mut state_lock = state.lock().unwrap();
    state_lock
        .sessions
        .insert(key.clone(), Arc::new(Mutex::new(ConnSession::new(sess))));
    state_lock.caches.insert(
        key.clone(),
        ProjectCache {
            directories: HashMap::new(),
        },
    );
    eprintln!("Daemon: 已连接 {}", key);
    Ok(Value::Boolean(true))
}
