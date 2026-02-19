// =============================================================================
// ssh_config.rs — SSH 配置解析 RPC 处理
// =============================================================================
// 提供 list_ssh_hosts 和 resolve_ssh_target 两个 RPC 方法，
// 通过 ssh2-config 库实现完整 OpenSSH 语法支持。

use crate::state::DaemonState;
use rmpv::Value;
use std::sync::{Arc, Mutex};

/// list_ssh_hosts — 列出 ~/.ssh/config 中所有非通配符 Host 条目
///
/// 返回: [{ host, hostname, user, port, identity_file }]
pub fn handle_list_ssh_hosts(state: &Arc<Mutex<DaemonState>>) -> Result<Value, anyhow::Error> {
    let state_lock = state.lock().unwrap();
    let config = state_lock
        .ssh_config
        .as_ref()
        .ok_or(anyhow::anyhow!("SSH config not loaded"))?;

    let mut result = Vec::new();

    // get_hosts() 返回 &Vec<Host>，每个 Host 有 pattern: Vec<HostClause>
    // HostClause.pattern 是 host 名/模式字符串
    for host in config.get_hosts() {
        for clause in &host.pattern {
            // 跳过通配符模式（如 Host *）和取反模式（如 Host !bad-host）
            if clause.negated || clause.pattern.contains('*') || clause.pattern.contains('?') {
                continue;
            }

            let host_name = &clause.pattern;
            // query() 按 OpenSSH 规则解析出该 Host 的完整参数
            let params = config.query(host_name);

            let hostname = params.host_name.as_deref().unwrap_or(host_name.as_str());
            let user = params.user.as_deref().unwrap_or("");
            let port = params.port.unwrap_or(22);
            let identity_file = params
                .identity_file
                .as_ref()
                .and_then(|files| files.first())
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_default();

            let entry = vec![
                (
                    Value::String("host".into()),
                    Value::String(host_name.clone().into()),
                ),
                (
                    Value::String("hostname".into()),
                    Value::String(hostname.to_string().into()),
                ),
                (
                    Value::String("user".into()),
                    Value::String(user.to_string().into()),
                ),
                (
                    Value::String("port".into()),
                    Value::Integer((port as i64).into()),
                ),
                (
                    Value::String("identity_file".into()),
                    Value::String(identity_file.into()),
                ),
            ];
            result.push(Value::Map(entry));
        }
    }

    Ok(Value::Array(result))
}

/// resolve_ssh_target — 解析目标字符串为连接参数
///
/// 支持格式:
///   - "alias"          → 从 SSH Config 查找
///   - "user@host"      → 手动解析 + Config 查找 hostname
///   - "user@host:port" → 手动解析 + Config 查找 hostname
pub fn handle_resolve_ssh_target(
    target: &str,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    let state_lock = state.lock().unwrap();

    // 先尝试从 SSH 配置中解析（处理纯 alias 场景）
    if let Some(ref config) = state_lock.ssh_config {
        if !target.contains('@') {
            // 纯 alias — 直接 query
            let params = config.query(target);
            let hostname = params.host_name.as_deref().unwrap_or(target);
            let user = params.user.as_deref().unwrap_or("root");
            let port = params.port.unwrap_or(22);

            let map = vec![
                (
                    Value::String("user".into()),
                    Value::String(user.to_string().into()),
                ),
                (
                    Value::String("hostname".into()),
                    Value::String(hostname.to_string().into()),
                ),
                (
                    Value::String("port".into()),
                    Value::Integer((port as i64).into()),
                ),
            ];
            return Ok(Value::Map(map));
        }
    }

    // 手动解析 user@host:port 或 user@host
    if let Some((user_part, rest)) = target.split_once('@') {
        if let Some((host_part, port_str)) = rest.split_once(':') {
            let port: u16 = port_str.parse().unwrap_or(22);
            let hostname = resolve_hostname(host_part, &state_lock);
            let map = vec![
                (
                    Value::String("user".into()),
                    Value::String(user_part.to_string().into()),
                ),
                (
                    Value::String("hostname".into()),
                    Value::String(hostname.into()),
                ),
                (
                    Value::String("port".into()),
                    Value::Integer((port as i64).into()),
                ),
            ];
            return Ok(Value::Map(map));
        } else {
            let hostname = resolve_hostname(rest, &state_lock);
            let map = vec![
                (
                    Value::String("user".into()),
                    Value::String(user_part.to_string().into()),
                ),
                (
                    Value::String("hostname".into()),
                    Value::String(hostname.into()),
                ),
                (Value::String("port".into()), Value::Integer(22.into())),
            ];
            return Ok(Value::Map(map));
        }
    }

    Err(anyhow::anyhow!("Cannot resolve SSH target: {}", target))
}

/// 辅助函数：如果 host 在 SSH Config 中有 HostName 映射，返回映射后的值
fn resolve_hostname(host: &str, state: &DaemonState) -> String {
    if let Some(ref config) = state.ssh_config {
        let params = config.query(host);
        if let Some(ref hn) = params.host_name {
            return hn.clone();
        }
    }
    host.to_string()
}
