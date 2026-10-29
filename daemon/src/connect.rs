// =============================================================================
// connect.rs — SSH 连接建立
// =============================================================================
// 实现 connect RPC 方法。
// 认证策略按优先级: SSH Agent → Config IdentityFile → 默认密钥 → 密码
//
// 模块对外提供两个入口：
//   - handle_connect:    RPC handler，建好 Session 后插到 state.sessions
//   - open_dedicated_session: 给流式命令用，建好返回，不入 state（解耦长命令与 SFTP 池）

use crate::state::{ConnSession, DaemonState, LockExt, ProjectCache};
use rmpv::Value;
use socket2::{Socket, TcpKeepalive};
use ssh2::Session;
use ssh2_config::SshConfig;
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// TCP 建连超时：不可达主机不应让 connect RPC 卡上几分钟（系统默认 ~75s+）
const TCP_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// 每个 target 最多缓存的空闲 exec session 数
const EXEC_POOL_MAX: usize = 4;

pub fn handle_connect(
    user: &str,
    host: &str,
    port: u16,
    password: Option<&str>,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    let key = DaemonState::connection_key(user, host, port);

    // 同一 target 的建连串行化：并发请求（或并发自动重连）只握手一次，
    // 后到者拿到锁后直接命中下面的"已有连接"检查。
    let connect_lock = {
        let mut st = state.lock_ok();
        st.connect_locks
            .entry(key.clone())
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    };
    let _connect_guard = connect_lock.lock_ok();

    // ── 检查是否已有有效连接 ──
    // sessions 里只存认证成功的会话（死会话由 with_conn 移除），所以存在即有效。
    // 刻意不去 lock 该 conn：它可能正被长操作（scan_project）占用。
    // 拿一份 ssh_config 的克隆 + 记住的密码，认证期间不持 state 锁
    let (ssh_config, saved_password) = {
        let state_lock = state.lock_ok();
        if state_lock.sessions.contains_key(&key) {
            return Ok(Value::Boolean(true));
        }
        (
            state_lock.ssh_config.clone(),
            state_lock.passwords.get(&key).cloned(),
        )
    };
    let effective_password = password.map(|s| s.to_string()).or(saved_password);

    let sess = open_session(
        user,
        host,
        port,
        effective_password.as_deref(),
        ssh_config.as_ref(),
    )?;

    // ── 保存会话；缓存若已存在则保留（自动重连时不应清空目录缓存）──
    {
        let mut state_lock = state.lock_ok();
        state_lock
            .sessions
            .insert(key.clone(), Arc::new(Mutex::new(ConnSession::new(sess))));
        if let Some(pwd) = password {
            // 仅内存保存：自动重连 / 流式命令的独立会话需要它
            state_lock.passwords.insert(key.clone(), pwd.to_string());
        }
        // 进到这一段意味着刚做了一次完整 SSH 握手 —— 要么首次连接、要么 with_conn
        // 探测到旧 SFTP session 已死后调用了我们。这两种情况下，之前缓存的 exec
        // session（如果有）也很可能跟着 TCP 一起断了。直接丢弃，让 schedule_exec_warm
        // 跑后台预热重建一条。
        state_lock.exec_sessions.remove(&key);
        state_lock
            .caches
            .entry(key.clone())
            .or_insert_with(ProjectCache::new);
    } // 释放 state_lock 之后再启动后台预热线程，避免锁交叉
    debug_log!("Daemon: 已连接 {}", key);

    schedule_exec_warm(user, host, port, state);
    Ok(Value::Boolean(true))
}

/// 后台预热该 target 的 exec session：连接成功后立刻起一条线程做 SSH 握手 +
/// 放进空闲池，让用户第一条 `cmd.stream`（典型场景：`:Neogit` 触发的 git 命令）
/// 不必再付一次 200-500ms 握手代价。
///
/// 故意非阻塞：connect RPC 立刻返回，预热在后台跑——失败也只打日志，首条
/// cmd.stream 会自己走 `borrow_exec_session` 新建。
fn schedule_exec_warm(user: &str, host: &str, port: u16, state: &Arc<Mutex<DaemonState>>) {
    let key = DaemonState::connection_key(user, host, port);
    {
        let st = state.lock_ok();
        if st.exec_sessions.get(&key).is_some_and(|v| !v.is_empty()) {
            return;
        }
    }
    let user = user.to_string();
    let host = host.to_string();
    let state = state.clone();
    std::thread::spawn(
        move || match open_dedicated_session(&user, &host, port, &state) {
            Ok(sess) => {
                return_exec_session(&user, &host, port, sess, &state);
                debug_log!("Daemon: exec session 预热完成 {}@{}:{}", user, host, port);
            }
            Err(e) => debug_log!(
                "Daemon: exec session 预热失败 {}@{}:{}: {} (首次 cmd.stream 会重试)",
                user,
                host,
                port,
                e
            ),
        },
    );
}

/// 给流式命令使用的独占 Session。
///
/// 不入 `state.sessions`，调用方自己管理生命周期（drop 即关闭）。这样长跑的
/// 流式命令不会霸占 `with_conn` 的 Mutex，SFTP / read_dir / 别的操作可以并行。
///
/// 使用 `state` 读取 ssh_config 和 connect 时记住的密码。
pub fn open_dedicated_session(
    user: &str,
    host: &str,
    port: u16,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Session, anyhow::Error> {
    let key = DaemonState::connection_key(user, host, port);
    let (ssh_config, password) = {
        let state_lock = state.lock_ok();
        (
            state_lock.ssh_config.clone(),
            state_lock.passwords.get(&key).cloned(),
        )
    };
    open_session(user, host, port, password.as_deref(), ssh_config.as_ref())
}

/// 从该 target 的空闲池里**取走**一个 exec session；池空则新建。
///
/// 返回 `(Session, pooled)`：pooled=true 表示是复用的旧会话（可能已静默断开，
/// 调用方在 channel 打开失败时可以丢弃并重建一次）。
///
/// 取走后调用方独占该 Session，用完调用 `return_exec_session` 归还，所以同一
/// target 的多条流式命令互不阻塞。
pub fn borrow_exec_session(
    user: &str,
    host: &str,
    port: u16,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<(Session, bool), anyhow::Error> {
    let key = DaemonState::connection_key(user, host, port);
    {
        let mut st = state.lock_ok();
        if let Some(sess) = st.exec_sessions.get_mut(&key).and_then(|v| v.pop()) {
            return Ok((sess, true));
        }
    }
    // 未缓存：建新 session（不持 state 锁完成握手）
    let sess = open_dedicated_session(user, host, port, state)?;
    debug_log!("Daemon: exec session 已建立 {}@{}:{}", user, host, port);
    Ok((sess, false))
}

/// 把用完的 exec session 放回空闲池（超过上限则直接丢弃）。
pub fn return_exec_session(
    user: &str,
    host: &str,
    port: u16,
    sess: Session,
    state: &Arc<Mutex<DaemonState>>,
) {
    // 归还前恢复默认的 blocking + 10s 超时，下一个借用者从干净状态开始
    sess.set_blocking(true);
    sess.set_timeout(10000);
    let key = DaemonState::connection_key(user, host, port);
    let mut st = state.lock_ok();
    let pool = st.exec_sessions.entry(key).or_default();
    if pool.len() < EXEC_POOL_MAX {
        pool.push(sess);
    }
}

/// 清空 target 的 exec session 池：下次 borrow 会重新握手。
/// 在 `is_session_dead` 命中（broken pipe / socket disconnect）时调用。
pub fn drop_exec_session(user: &str, host: &str, port: u16, state: &Arc<Mutex<DaemonState>>) {
    let key = DaemonState::connection_key(user, host, port);
    let mut st = state.lock_ok();
    if st.exec_sessions.remove(&key).is_some() {
        debug_log!(
            "Daemon: exec session 池已清空 {} (将于下次 cmd.stream 重建)",
            key
        );
    }
}

/// 解析地址并逐个带超时尝试 TCP 建连
fn tcp_connect(host: &str, port: u16) -> Result<TcpStream, anyhow::Error> {
    let addrs: Vec<_> = (host, port)
        .to_socket_addrs()
        .map_err(|e| anyhow::anyhow!("无法解析主机 {}:{}: {}", host, port, e))?
        .collect();
    let mut last_err: Option<std::io::Error> = None;
    for addr in &addrs {
        match TcpStream::connect_timeout(addr, TCP_CONNECT_TIMEOUT) {
            Ok(s) => return Ok(s),
            Err(e) => last_err = Some(e),
        }
    }
    Err(match last_err {
        Some(e) => anyhow::anyhow!("TCP 连接失败 {}:{}: {}", host, port, e),
        None => anyhow::anyhow!("无法解析主机 {}:{}: 无可用地址", host, port),
    })
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
    let tcp = tcp_connect(host, port)?;
    tcp.set_nodelay(true)?;

    // 开启 TCP keepalive：长时间空闲或网络切换后内核会主动探测对端，
    // 死连接会更快变为 BrokenPipe，让 with_conn 的自动重连能及时触发。
    let socket: Socket = tcp.into();
    let keepalive = TcpKeepalive::new()
        .with_time(Duration::from_secs(60))
        .with_interval(Duration::from_secs(15));
    if let Err(e) = socket.set_tcp_keepalive(&keepalive) {
        debug_log!("Daemon: 设置 TCP keepalive 失败 (忽略): {}", e);
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
        if agent.connect().is_ok() && agent.list_identities().is_ok() {
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
