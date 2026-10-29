// =============================================================================
// connect.rs — SSH 建连与认证
// =============================================================================
// 认证策略按优先级: SSH Agent → Config IdentityFile → 默认密钥 → 密码
//
//   - connect:                建好会话后插入 state.sessions（connect RPC / 自动重连）
//   - open_dedicated_session: 给 exec 池用，建好直接返回，不入 state

use crate::session::{self, ConnSession, DEFAULT_TIMEOUT_MS};
use crate::state::{LockExt, SharedState, Target};
use socket2::{Socket, TcpKeepalive};
use ssh2::Session;
use ssh2_config::SshConfig;
use std::net::{TcpStream, ToSocketAddrs};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// TCP 建连超时：不可达主机不应让 connect RPC 卡上几分钟（系统默认 ~75s+）
const TCP_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// 确保 target 有一个已认证的共享会话。password 为 None 时复用 connect 时记住的密码。
pub fn connect(t: &Target, password: Option<&str>, state: &SharedState) -> anyhow::Result<()> {
    let key = t.key();

    // 同一 target 的建连串行化：并发请求（或并发自动重连）只握手一次，
    // 后到者拿到锁后直接命中下面的"已有连接"检查。
    let connect_lock = state
        .lock_ok()
        .connect_locks
        .entry(key.clone())
        .or_default()
        .clone();
    let _connect_guard = connect_lock.lock_ok();

    // sessions 里只存认证成功的会话（死会话由 with_conn 移除），所以存在即有效。
    // 刻意不去 lock 该 conn：它可能正被长操作（scan_project）占用。
    if state.lock_ok().sessions.contains_key(&key) {
        return Ok(());
    }

    let sess = authenticate(t, password, state)?;
    {
        let mut st = state.lock_ok();
        st.sessions
            .insert(key.clone(), Arc::new(Mutex::new(ConnSession::new(sess))));
        if let Some(pwd) = password {
            st.passwords.insert(key, pwd.to_string());
        }
    }
    // 刚做了一次完整握手 —— 要么首次连接、要么旧会话已死。池里旧的 exec session
    // 很可能跟着 TCP 一起断了：丢弃并后台预热一条新的。
    session::exec_pool_clear(state, t);
    session::exec_pool_warm(state, t);
    debug_log!("Daemon: 已连接 {}", t);
    Ok(())
}

/// 给 exec 池使用的独立 Session：不入 `state.sessions`，调用方自己管理生命周期。
pub fn open_dedicated_session(t: &Target, state: &SharedState) -> anyhow::Result<Session> {
    authenticate(t, None, state)
}

/// 用 state 里的 ssh_config 和记住的密码（password 参数优先）打开会话；
/// 认证期间不持 state 锁。
fn authenticate(
    t: &Target,
    password: Option<&str>,
    state: &SharedState,
) -> anyhow::Result<Session> {
    let (ssh_config, saved_password) = {
        let st = state.lock_ok();
        (st.ssh_config.clone(), st.passwords.get(&t.key()).cloned())
    };
    let password = password.map(str::to_string).or(saved_password);
    open_session(t, password.as_deref(), ssh_config.as_ref())
}

/// 解析地址并逐个带超时尝试 TCP 建连
fn tcp_connect(host: &str, port: u16) -> anyhow::Result<TcpStream> {
    let addrs = (host, port)
        .to_socket_addrs()
        .map_err(|e| anyhow::anyhow!("无法解析主机 {}:{}: {}", host, port, e))?;
    let mut last_err = None;
    for addr in addrs {
        match TcpStream::connect_timeout(&addr, TCP_CONNECT_TIMEOUT) {
            Ok(s) => return Ok(s),
            Err(e) => last_err = Some(e),
        }
    }
    Err(match last_err {
        Some(e) => anyhow::anyhow!("TCP 连接失败 {}:{}: {}", host, port, e),
        None => anyhow::anyhow!("无法解析主机 {}:{}: 无可用地址", host, port),
    })
}

/// TCP 连接 + handshake + 认证
fn open_session(
    t: &Target,
    password: Option<&str>,
    ssh_config: Option<&SshConfig>,
) -> anyhow::Result<Session> {
    let tcp = tcp_connect(&t.host, t.port)?;
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

    let mut sess = Session::new()?;
    sess.set_tcp_stream(TcpStream::from(socket));
    sess.set_timeout(DEFAULT_TIMEOUT_MS);
    sess.handshake()
        .map_err(|e| anyhow::anyhow!("握手失败: {}", e))?;

    // SSH-layer keepalive：libssh2 自己每 30s 发 SSH_MSG_IGNORE 心跳。TCP
    // keepalive 包在某些 NAT/middlebox 上不算「应用流量」、idle 计时器照常往前
    // 走；SSH 层心跳走的是 SSH session 字节流，能真正把 idle 计时器归零。
    // `true` 表示对端无应答时 libssh2 在下次操作返回错误而不是无限挂起 ——
    // with_conn 的死会话自动重连路径会接住。
    sess.set_keepalive(true, 30);

    let user = t.user.as_str();
    let try_key =
        |path: &Path| path.exists() && sess.userauth_pubkey_file(user, None, path, None).is_ok();

    let authenticated = auth_with_agent(&sess, user)
        // ~/.ssh/config 中的 IdentityFile
        || config_identity_files(ssh_config, &t.host).iter().any(|p| try_key(p))
        // 默认密钥文件 ~/.ssh/id_*
        || dirs::home_dir().is_some_and(|home| {
            ["id_ed25519", "id_rsa", "id_ecdsa", "id_dsa"]
                .iter()
                .any(|name| try_key(&home.join(".ssh").join(name)))
        })
        || password.is_some_and(|pwd| sess.userauth_password(user, pwd).is_ok());

    if !authenticated {
        return Err(anyhow::anyhow!("AUTH_FAILED: 认证失败 {}", t));
    }
    Ok(sess)
}

fn auth_with_agent(sess: &Session, user: &str) -> bool {
    let Ok(mut agent) = sess.agent() else {
        return false;
    };
    if agent.connect().is_err() || agent.list_identities().is_err() {
        return false;
    }
    agent
        .identities()
        .is_ok_and(|ids| ids.iter().any(|id| agent.userauth(user, id).is_ok()))
}

/// ssh_config 中该 host 的 IdentityFile 列表（展开 `~`）
fn config_identity_files(ssh_config: Option<&SshConfig>, host: &str) -> Vec<std::path::PathBuf> {
    let files = ssh_config
        .and_then(|c| c.query(host).identity_file)
        .unwrap_or_default();
    let home = dirs::home_dir();
    files
        .into_iter()
        .map(|p| match (p.strip_prefix("~"), &home) {
            (Ok(rest), Some(home)) => home.join(rest),
            _ => p,
        })
        .collect()
}
