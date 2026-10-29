// =============================================================================
// ssh_config.rs — ~/.ssh/config 查询 RPC
// =============================================================================
// list_ssh_hosts / resolve_ssh_target，通过 ssh2-config 库实现完整 OpenSSH 语法支持。

use crate::rpc::map;
use crate::state::{LockExt, SharedState};
use rmpv::Value;
use ssh2_config::SshConfig;

/// 列出所有非通配符 Host 条目
///
/// 返回: [{ host, hostname, user, port, identity_file }]
pub fn list_hosts(state: &SharedState) -> anyhow::Result<Value> {
    let st = state.lock_ok();
    let config = st
        .ssh_config
        .as_ref()
        .ok_or(anyhow::anyhow!("SSH config not loaded"))?;

    let mut result = Vec::new();
    for clause in config.get_hosts().iter().flat_map(|h| &h.pattern) {
        // 跳过通配符模式（如 Host *）和取反模式（如 Host !bad-host）
        let name = clause.pattern.as_str();
        if clause.negated || name.contains(['*', '?']) {
            continue;
        }
        // query() 按 OpenSSH 规则解析出该 Host 的完整参数
        let params = config.query(name);
        let identity_file = params
            .identity_file
            .as_ref()
            .and_then(|files| files.first())
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();
        result.push(map([
            ("host", Value::from(name)),
            (
                "hostname",
                Value::from(params.host_name.as_deref().unwrap_or(name)),
            ),
            ("user", Value::from(params.user.as_deref().unwrap_or(""))),
            ("port", Value::from(params.port.unwrap_or(22))),
            ("identity_file", Value::from(identity_file)),
        ]));
    }
    Ok(Value::Array(result))
}

/// 解析目标字符串为连接参数 { user, hostname, port }
///
/// 支持格式:
///   - "alias"          → 从 SSH Config 查找（user 缺省 root）
///   - "user@host"      → 手动解析 + Config 查找 hostname
///   - "user@host:port" → 手动解析 + Config 查找 hostname
pub fn resolve_target(target: &str, state: &SharedState) -> anyhow::Result<Value> {
    let st = state.lock_ok();
    let config = st.ssh_config.as_ref();

    let (user, hostname, port) = match (target.split_once('@'), config) {
        (None, Some(config)) => {
            let params = config.query(target);
            (
                params.user.unwrap_or_else(|| "root".into()),
                params.host_name.unwrap_or_else(|| target.into()),
                params.port.unwrap_or(22),
            )
        }
        (Some((user, rest)), _) => {
            let (host, port) = match rest.split_once(':') {
                Some((host, port)) => (host, port.parse().unwrap_or(22)),
                None => (rest, 22),
            };
            (user.to_string(), resolve_hostname(host, config), port)
        }
        (None, None) => return Err(anyhow::anyhow!("Cannot resolve SSH target: {}", target)),
    };
    Ok(map([
        ("user", Value::from(user)),
        ("hostname", Value::from(hostname)),
        ("port", Value::from(port)),
    ]))
}

/// 如果 host 在 SSH Config 中有 HostName 映射，返回映射后的值
fn resolve_hostname(host: &str, config: Option<&SshConfig>) -> String {
    config
        .and_then(|c| c.query(host).host_name)
        .unwrap_or_else(|| host.to_string())
}
