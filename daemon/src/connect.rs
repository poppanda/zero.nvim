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
    {
        let mut state_lock = state.lock().unwrap();
        state_lock
            .sessions
            .insert(key.clone(), Arc::new(Mutex::new(ConnSession::new(sess))));
        // 进到这一段意味着刚做了一次完整 SSH 握手 —— 要么首次连接、要么 with_conn
        // 探测到旧 SFTP session 已死后调用了我们。这两种情况下，之前缓存的 exec
        // session（如果有）也很可能跟着 TCP 一起断了。直接丢弃，让 schedule_exec_warm
        // 跑后台预热重建一条。
        state_lock.exec_sessions.remove(&key);
        state_lock
            .caches
            .entry(key.clone())
            .or_insert_with(|| ProjectCache {
                directories: HashMap::new(),
            });
    } // 释放 state_lock 之后再启动后台预热线程，避免锁交叉
    eprintln!("Daemon: 已连接 {}", key);

    schedule_exec_warm(user, host, port, state);
    Ok(Value::Boolean(true))
}

/// 后台预热该 target 的 exec session：连接成功后立刻起一条线程做 SSH 握手 +
/// 缓存好备用，让用户第一条 `cmd.stream`（典型场景：`:Neogit` 触发的 git 命令）
/// 不必再付一次 200-500ms 握手代价。
///
/// 故意非阻塞：connect RPC 立刻返回，预热在后台跑——失败也只打日志，首条
/// cmd.stream 会自己走 `borrow_exec_session` 重试。
///
/// 若 exec session 已缓存则直接 no-op；handle_connect 在调用本函数前已经把
/// 老条目清掉，所以这种情况只会出现在 schedule 重入（理论上不会发生）。
fn schedule_exec_warm(user: &str, host: &str, port: u16, state: &Arc<Mutex<DaemonState>>) {
    let key = DaemonState::connection_key(user, host, port);
    {
        let st = state.lock().unwrap();
        if st.exec_sessions.contains_key(&key) {
            return;
        }
    }
    let user = user.to_string();
    let host = host.to_string();
    let state = state.clone();
    std::thread::spawn(
        move || match borrow_exec_session(&user, &host, port, &state) {
            Ok(_) => eprintln!("Daemon: exec session 预热完成 {}@{}:{}", user, host, port),
            Err(e) => eprintln!(
                "Daemon: exec session 预热失败 {}@{}:{}: {} (首次 cmd.stream 会重试)",
                user, host, port, e
            ),
        },
    );
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

/// 取（或惰性创建）该 target 的 exec session（流式命令复用池）。
///
/// 第一次调用对该 target 付一次 SSH 握手开销（TCP + 协议握手 + 认证 ≈ 200-500ms）；
/// 后续 `cmd.stream` 共用此 Session，仅做 `channel_session()` 协议级轻量协商。
/// 对 `:Neogit` 这种打开瞬间触发 6+ git 命令的场景，理论加速 3-5×。
///
/// 返回 `Arc<Mutex<Session>>`：调用方持锁的整个 duration 内独占该 Session。
/// libssh2 不支持同会话并发 channel ops，必须串行化。Lua-side `target_gates`
/// 已经把同 target 的 cmd.stream 调用排队到 1 路，所以 daemon 端 mutex 实际
/// 上没有竞争。
pub fn borrow_exec_session(
    user: &str,
    host: &str,
    port: u16,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Arc<Mutex<Session>>, anyhow::Error> {
    let key = DaemonState::connection_key(user, host, port);

    // 已缓存：直接返回 Arc 克隆
    {
        let st = state.lock().unwrap();
        if let Some(arc) = st.exec_sessions.get(&key) {
            return Ok(arc.clone());
        }
    }

    // 未缓存：建新 session（不持 state 锁完成握手）
    let sess = open_dedicated_session(user, host, port, state)?;
    let arc = Arc::new(Mutex::new(sess));

    // 双检：握手期间可能被其他线程抢先填了
    let mut st = state.lock().unwrap();
    if let Some(existing) = st.exec_sessions.get(&key) {
        // 抢先存在：丢弃我们刚建的，用已有的
        return Ok(existing.clone());
    }
    st.exec_sessions.insert(key, arc.clone());
    eprintln!("Daemon: exec session 已建立 {}@{}:{}", user, host, port);
    Ok(arc)
}

/// 把 target 的 exec session 从缓存里移除：下次 borrow 会重新握手。
/// 在 `is_session_dead` 命中（broken pipe / socket disconnect）时调用。
pub fn drop_exec_session(user: &str, host: &str, port: u16, state: &Arc<Mutex<DaemonState>>) {
    let key = DaemonState::connection_key(user, host, port);
    let mut st = state.lock().unwrap();
    if st.exec_sessions.remove(&key).is_some() {
        eprintln!(
            "Daemon: exec session 已丢弃 {} (将于下次 cmd.stream 重建)",
            key
        );
    }
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

    // SSH-layer keepalive：libssh2 自己每 30s 发 SSH_MSG_IGNORE 心跳。TCP
    // keepalive 包在某些 NAT/middlebox 上不算「应用流量」、idle 计时器照常往前
    // 走；SSH 层心跳走的是 SSH session 字节流，对端 sshd 一定会处理，能真正把
    // idle 计时器归零。`true` 第二参表示如果对端无应答，libssh2 在下次操作时
    // 返回错误而不是无限挂起 —— with_conn 的死会话自动重连路径会接住。
    sess.set_keepalive(true, 30);

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
