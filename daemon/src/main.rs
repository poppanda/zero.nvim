// =============================================================================
// zero-nvim daemon — 入口 & RPC 分发
// =============================================================================
// 通过 stdin/stdout Msgpack-RPC 与 Neovim 通信。
// 实际处理逻辑分布在各子模块中：
//   - state:      全局状态和数据结构
//   - ssh_config: SSH 配置解析
//   - connect:    SSH 连接管理
//   - fs:         远程文件系统操作（读/写/目录/扫描）

mod cmd;
mod connect;
mod fs;
mod lsp;
mod ssh_config;
mod state;

use rmpv::{decode, encode, Value};
use state::DaemonState;
use std::io::Write;
use std::sync::{mpsc, Arc, Mutex};

// =============================================================================
// 主循环
// =============================================================================

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let state = Arc::new(Mutex::new(DaemonState::new()));
    let stdin = std::io::stdin();
    let mut reader = stdin.lock();
    let mut stdout = std::io::stdout();

    // 唯一的输出通道
    let (tx, rx) = mpsc::channel::<Value>();

    // 专门负责写 stdout 的后台线程，防止多线程写冲突
    std::thread::spawn(move || {
        while let Ok(msg) = rx.recv() {
            if encode::write_value(&mut stdout, &msg).is_ok() {
                let _ = stdout.flush();
            }
        }
    });

    loop {
        // 从 stdin 读取一条 Msgpack 消息
        let msg = match decode::read_value(&mut reader) {
            Ok(v) => v,
            Err(_) => break, // stdin 关闭 = Neovim 退出
        };

        // Msgpack-RPC request: [type=0, msgid, method, params]
        if let Value::Array(ref args) = msg {
            if args.len() == 4 {
                let msg_type = args[0].as_u64();
                let msg_id = args[1].as_u64();
                let method_val = &args[2];
                let params = &args[3];

                if let (Some(0), Some(id)) = (msg_type, msg_id) {
                    if let Some(method) = method_val.as_str() {
                        let result = dispatch(method, params, state.clone(), tx.clone());
                        let (err, res) = match result {
                            Ok(val) => (Value::Nil, val),
                            Err(e) => (Value::String(format!("{}", e).into()), Value::Nil),
                        };
                        // Msgpack-RPC response: [type=1, msgid, error, result]
                        let response = Value::Array(vec![
                            Value::Integer(1.into()),
                            Value::Integer(id.into()),
                            err,
                            res,
                        ]);
                        let _ = tx.send(response);
                    }
                }
            }
        }
    }
    Ok(())
}

// =============================================================================
// RPC 方法分发表
// =============================================================================
// 每个方法负责从 params 中提取参数，然后委托给对应模块的处理函数。

fn dispatch(
    method: &str,
    params: &Value,
    state: Arc<Mutex<DaemonState>>,
    tx: mpsc::Sender<Value>,
) -> Result<Value, anyhow::Error> {
    match method {
        // ── SSH 配置 ──
        "list_ssh_hosts" => ssh_config::handle_list_ssh_hosts(&state),

        "resolve_ssh_target" => {
            let args = params.as_array().ok_or(anyhow::anyhow!("Invalid params"))?;
            let target = args
                .get(0)
                .and_then(|v| v.as_str())
                .ok_or(anyhow::anyhow!("Missing target"))?;
            ssh_config::handle_resolve_ssh_target(target, &state)
        }

        // ── 连接管理 ──
        "connect" => {
            let (user, host, port, password) = extract_connect_params(params)?;
            connect::handle_connect(user, host, port, password, &state)
        }

        // ── 文件操作 ──
        "fetch_path" => {
            let (user, host, port, path) = extract_path_params(params)?;
            fs::handle_fetch_path(user, host, port, path, &state)
        }

        "fetch_paths" => {
            let args = params.as_array().ok_or(anyhow::anyhow!("Invalid params"))?;
            let user = args
                .get(0)
                .and_then(|v| v.as_str())
                .ok_or(anyhow::anyhow!("Missing user"))?;
            let host = args
                .get(1)
                .and_then(|v| v.as_str())
                .ok_or(anyhow::anyhow!("Missing host"))?;
            let port = args.get(2).and_then(|v| v.as_u64()).unwrap_or(22) as u16;

            let paths_array = args
                .get(3)
                .and_then(|v| v.as_array())
                .ok_or(anyhow::anyhow!("Missing paths array"))?;
            let paths = paths_array
                .iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect();

            fs::handle_fetch_paths(user, host, port, paths, &state)
        }

        "fetch_file" => {
            let (user, host, port, path) = extract_path_params(params)?;
            fs::handle_fetch_file(user, host, port, path, &state)
        }

        "write_file" => {
            let args = params.as_array().ok_or(anyhow::anyhow!("Invalid params"))?;
            let (user, host, port, path) = extract_path_params(params)?;
            let content = args
                .get(4)
                .and_then(|v| v.as_str())
                .ok_or(anyhow::anyhow!("Missing content"))?;
            fs::handle_write_file(user, host, port, path, content, &state)
        }

        // ── 目录操作 ──
        "read_dir" => {
            let (user, host, port, path) = extract_path_params(params)?;
            fs::handle_read_dir(user, host, port, path, &state)
        }

        "stat" => {
            let (user, host, port, path) = extract_path_params(params)?;
            fs::handle_stat(user, host, port, path, &state)
        }

        "scan_project" => {
            let (user, host, port, path) = extract_path_params(params)?;
            fs::handle_scan_project(user, host, port, path, &state)
        }

        // ── 扩展文件操作 ──
        "mkdir" => {
            let (user, host, port, path) = extract_path_params(params)?;
            fs::handle_mkdir(user, host, port, path, &state)
        }

        "remove_file" => {
            let (user, host, port, path) = extract_path_params(params)?;
            fs::handle_remove_file(user, host, port, path, &state)
        }

        "remove_dir" => {
            let (user, host, port, path) = extract_path_params(params)?;
            fs::handle_remove_dir(user, host, port, path, &state)
        }

        "rename" => {
            let args = params.as_array().ok_or(anyhow::anyhow!("Invalid params"))?;
            let user = args
                .get(0)
                .and_then(|v| v.as_str())
                .ok_or(anyhow::anyhow!("Missing user"))?;
            let host = args
                .get(1)
                .and_then(|v| v.as_str())
                .ok_or(anyhow::anyhow!("Missing host"))?;
            let port = args.get(2).and_then(|v| v.as_u64()).unwrap_or(22) as u16;
            let src = args
                .get(3)
                .and_then(|v| v.as_str())
                .ok_or(anyhow::anyhow!("Missing src"))?;
            let dst = args
                .get(4)
                .and_then(|v| v.as_str())
                .ok_or(anyhow::anyhow!("Missing dst"))?;
            fs::handle_rename(user, host, port, src, dst, &state)
        }

        // ── 通用远程命令基座 ──
        "cmd_sync" => cmd::dispatch::handle_cmd_sync(params, &state),

        "cmd_stream" => cmd::dispatch::handle_cmd_stream(params, &state, tx),

        "cmd_cancel" => cmd::dispatch::handle_cmd_cancel(params, &state),

        "cmd_stdin_write" => cmd::dispatch::handle_cmd_stdin_write(params, &state),

        "cmd_stdin_close" => cmd::dispatch::handle_cmd_stdin_close(params, &state),

        // ── 远端命令执行 (legacy) ──
        "exec_remote" => {
            let args = params.as_array().ok_or(anyhow::anyhow!("Invalid params"))?;
            let user = args
                .get(0)
                .and_then(|v| v.as_str())
                .ok_or(anyhow::anyhow!("Missing user"))?;
            let host = args
                .get(1)
                .and_then(|v| v.as_str())
                .ok_or(anyhow::anyhow!("Missing host"))?;
            let port = args.get(2).and_then(|v| v.as_u64()).unwrap_or(22) as u16;
            let cmd = args
                .get(3)
                .and_then(|v| v.as_str())
                .ok_or(anyhow::anyhow!("Missing cmd"))?;
            fs::handle_exec_remote(user, host, port, cmd, &state)
        }

        // ── LSP 代理 ──
        "lsp_start" => {
            let args = params.as_array().ok_or(anyhow::anyhow!("Invalid params"))?;
            let user = args
                .get(0)
                .and_then(|v| v.as_str())
                .ok_or(anyhow::anyhow!("Missing user"))?;
            let host = args
                .get(1)
                .and_then(|v| v.as_str())
                .ok_or(anyhow::anyhow!("Missing host"))?;
            let port = args.get(2).and_then(|v| v.as_u64()).unwrap_or(22) as u16;
            let cmd = args.get(3).ok_or(anyhow::anyhow!("Missing cmd"))?;
            let cmd_argv = extract_lsp_cmd_argv(cmd)?;
            let default_prefix = format!("zero://{}@{}:{}", user, host, port);
            let client_prefix = args
                .get(4)
                .and_then(|v| v.as_str())
                .unwrap_or(&default_prefix);
            lsp::handle_start_lsp(user, host, port, cmd_argv, client_prefix, &state)
        }

        _ => Err(anyhow::anyhow!("Unknown method: {}", method)),
    }
}

fn extract_lsp_cmd_argv(value: &Value) -> Result<Vec<String>, anyhow::Error> {
    if let Some(cmd) = value.as_str() {
        // Backward compatibility for older Lua clients that sent a single shell
        // string. New clients send argv directly so paths/args can be quoted
        // safely in daemon/src/lsp.rs.
        return Ok(vec!["sh".to_string(), "-c".to_string(), cmd.to_string()]);
    }

    let arr = value
        .as_array()
        .ok_or(anyhow::anyhow!("cmd must be string or string[]"))?;
    let mut argv = Vec::with_capacity(arr.len());
    for item in arr {
        let s = item
            .as_str()
            .ok_or(anyhow::anyhow!("cmd argv item must be string"))?;
        argv.push(s.to_string());
    }
    if argv.is_empty() {
        return Err(anyhow::anyhow!("cmd argv is empty"));
    }
    Ok(argv)
}

// =============================================================================
// 参数提取辅助函数
// =============================================================================

/// 从 [user, host, port, path] 提取通用路径参数
fn extract_path_params(params: &Value) -> Result<(&str, &str, u16, &str), anyhow::Error> {
    let args = params.as_array().ok_or(anyhow::anyhow!("Invalid params"))?;
    let user = args
        .get(0)
        .and_then(|v| v.as_str())
        .ok_or(anyhow::anyhow!("Missing user"))?;
    let host = args
        .get(1)
        .and_then(|v| v.as_str())
        .ok_or(anyhow::anyhow!("Missing host"))?;
    let port = args.get(2).and_then(|v| v.as_u64()).unwrap_or(22) as u16;
    let path = args
        .get(3)
        .and_then(|v| v.as_str())
        .ok_or(anyhow::anyhow!("Missing path"))?;
    Ok((user, host, port, path))
}

/// 从 [user, host, port, password?] 提取连接参数
fn extract_connect_params(
    params: &Value,
) -> Result<(&str, &str, u16, Option<&str>), anyhow::Error> {
    let args = params.as_array().ok_or(anyhow::anyhow!("Invalid params"))?;
    let user = args
        .get(0)
        .and_then(|v| v.as_str())
        .ok_or(anyhow::anyhow!("Missing user"))?;
    let host = args
        .get(1)
        .and_then(|v| v.as_str())
        .ok_or(anyhow::anyhow!("Missing host"))?;
    let port = args.get(2).and_then(|v| v.as_u64()).unwrap_or(22) as u16;
    let password = args.get(3).and_then(|v| v.as_str());
    Ok((user, host, port, password))
}
