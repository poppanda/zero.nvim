// =============================================================================
// zero-nvim daemon — 入口 & RPC 分发
// =============================================================================
// 通过 stdin/stdout Msgpack-RPC 与 Neovim 通信。
// 实际处理逻辑分布在各子模块中：
//   - state:      全局状态和数据结构
//   - ssh_config: SSH 配置解析
//   - connect:    SSH 连接管理
//   - fs:         远程文件系统操作（读/写/目录/扫描）

// 路由日志：stderr 在 Neovim 侧会显示成 WARN 通知，所以常规信息只在设置了
// ZERO_NVIM_DEBUG 环境变量时输出；真正的错误仍直接 eprintln!。
macro_rules! debug_log {
    ($($arg:tt)*) => {
        if $crate::debug_enabled() {
            eprintln!($($arg)*);
        }
    };
}

mod cmd;
mod connect;
mod fs;
mod lsp;
mod ssh_config;
mod state;

use rmpv::{decode, encode, Value};
use state::DaemonState;
use std::io::Write;
use std::sync::{mpsc, Arc, Mutex, OnceLock};

/// 是否输出调试日志（ZERO_NVIM_DEBUG 非空且不为 "0"）
pub(crate) fn debug_enabled() -> bool {
    static FLAG: OnceLock<bool> = OnceLock::new();
    *FLAG.get_or_init(|| {
        std::env::var("ZERO_NVIM_DEBUG")
            .map(|v| !v.is_empty() && v != "0")
            .unwrap_or(false)
    })
}

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

    // 从 stdin 逐条读取 Msgpack 消息；stdin 关闭 = Neovim 退出
    while let Ok(msg) = decode::read_value(&mut reader) {
        let Value::Array(args) = msg else { continue };
        match args.first().and_then(|v| v.as_u64()) {
            // Msgpack-RPC request: [type=0, msgid, method, params]
            Some(0) if args.len() == 4 => {
                let Some(id) = args[1].as_u64() else { continue };
                let Some(method) = args[2].as_str().map(|s| s.to_string()) else {
                    let _ = tx.send(response(id, Err(anyhow::anyhow!("Invalid method name"))));
                    continue;
                };
                let params = args[3].clone();
                if is_inline_method(&method) {
                    let result = dispatch(&method, &params, state.clone(), tx.clone());
                    let _ = tx.send(response(id, result));
                } else {
                    // 慢请求（建连 / 扫描 / 命令执行）各起一条线程，避免队头阻塞。
                    // 同一连接上的操作仍由 ConnSession 的 Mutex 串行化。
                    let state = state.clone();
                    let tx = tx.clone();
                    std::thread::spawn(move || {
                        let result = dispatch(&method, &params, state, tx.clone());
                        let _ = tx.send(response(id, result));
                    });
                }
            }
            // Msgpack-RPC notification: [type=2, method, params]（rpcnotify）
            // 无需回复；错误只打到 stderr。
            Some(2) if args.len() == 3 => {
                let Some(method) = args[1].as_str().map(|s| s.to_string()) else {
                    continue;
                };
                let params = args[2].clone();
                if is_inline_method(&method) {
                    if let Err(e) = dispatch(&method, &params, state.clone(), tx.clone()) {
                        eprintln!("Daemon: notification {} 失败: {}", method, e);
                    }
                } else {
                    let state = state.clone();
                    let tx = tx.clone();
                    std::thread::spawn(move || {
                        if let Err(e) = dispatch(&method, &params, state, tx) {
                            eprintln!("Daemon: notification {} 失败: {}", method, e);
                        }
                    });
                }
            }
            _ => {}
        }
    }
    Ok(())
}

/// 在主线程上同步处理的方法：都是不阻塞的快操作（查注册表、推 mpsc、读内存配置）。
///
/// cmd_stdin_write 必须同步处理以保证多条写入的顺序；cmd_cancel 同步处理保证
/// 不会排在任何长请求后面；cmd_stream 同步注册句柄，保证随后到达的
/// cancel / stdin 通知一定能找到它（真正的执行在它自己的 worker 线程里）。
fn is_inline_method(method: &str) -> bool {
    matches!(
        method,
        "cmd_cancel"
            | "cmd_stdin_write"
            | "cmd_stdin_close"
            | "cmd_stream"
            | "list_ssh_hosts"
            | "resolve_ssh_target"
    )
}

/// Msgpack-RPC response: [type=1, msgid, error, result]
fn response(id: u64, result: Result<Value, anyhow::Error>) -> Value {
    let (err, res) = match result {
        Ok(val) => (Value::Nil, val),
        Err(e) => (Value::String(format!("{}", e).into()), Value::Nil),
    };
    Value::Array(vec![
        Value::Integer(1.into()),
        Value::Integer(id.into()),
        err,
        res,
    ])
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
            let args = params_array(params)?;
            let target = arg_str(args, 0, "target")?;
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
            let args = params_array(params)?;
            let (user, host, port) = extract_target(args)?;
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
            let args = params_array(params)?;
            let (user, host, port, path) = extract_path_params(params)?;
            // 内容可能不是合法 UTF-8（Latin-1 源码、二进制）：按原始字节接收
            let content = arg_bytes(args, 4, "content")?;
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
            let args = params_array(params)?;
            let (user, host, port) = extract_target(args)?;
            let src = arg_str(args, 3, "src")?;
            let dst = arg_str(args, 4, "dst")?;
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
            let args = params_array(params)?;
            let (user, host, port) = extract_target(args)?;
            let cmd = arg_str(args, 3, "cmd")?;
            fs::handle_exec_remote(user, host, port, cmd, &state)
        }

        // ── LSP 代理 ──
        "lsp_probe" => {
            let args = params_array(params)?;
            let (user, host, port) = extract_target(args)?;
            let cmd = args.get(3).ok_or(anyhow::anyhow!("Missing cmd"))?;
            let cmd_argv = extract_lsp_cmd_argv(cmd)?;
            lsp::handle_probe_lsp(user, host, port, cmd_argv, &state)
        }

        "lsp_start" => {
            let args = params_array(params)?;
            let (user, host, port) = extract_target(args)?;
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

fn params_array(params: &Value) -> Result<&[Value], anyhow::Error> {
    params
        .as_array()
        .map(|v| v.as_slice())
        .ok_or(anyhow::anyhow!("Invalid params"))
}

/// 取第 idx 个字符串参数；区分"缺失"与"不是合法 UTF-8 字符串"两种错误
fn arg_str<'a>(args: &'a [Value], idx: usize, name: &str) -> Result<&'a str, anyhow::Error> {
    match args.get(idx) {
        None | Some(Value::Nil) => Err(anyhow::anyhow!("Missing {}", name)),
        Some(Value::String(s)) => s
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Invalid {}: not valid UTF-8", name)),
        Some(Value::Binary(b)) => std::str::from_utf8(b)
            .map_err(|_| anyhow::anyhow!("Invalid {}: not valid UTF-8", name)),
        Some(_) => Err(anyhow::anyhow!("Invalid {}: expected string", name)),
    }
}

/// 取第 idx 个参数的原始字节：接受 msgpack String（含非 UTF-8 内容）或 Binary
fn arg_bytes<'a>(args: &'a [Value], idx: usize, name: &str) -> Result<&'a [u8], anyhow::Error> {
    match args.get(idx) {
        None | Some(Value::Nil) => Err(anyhow::anyhow!("Missing {}", name)),
        Some(Value::String(s)) => Ok(s.as_bytes()),
        Some(Value::Binary(b)) => Ok(b.as_slice()),
        Some(_) => Err(anyhow::anyhow!("Invalid {}: expected string or binary", name)),
    }
}

/// 从 [user, host, port, ...] 提取连接目标
fn extract_target(args: &[Value]) -> Result<(&str, &str, u16), anyhow::Error> {
    let user = arg_str(args, 0, "user")?;
    let host = arg_str(args, 1, "host")?;
    let port = match args.get(2) {
        None | Some(Value::Nil) => 22,
        Some(v) => {
            let p = v
                .as_u64()
                .ok_or(anyhow::anyhow!("Invalid port: expected integer"))?;
            u16::try_from(p).map_err(|_| anyhow::anyhow!("Invalid port: {}", p))?
        }
    };
    Ok((user, host, port))
}

/// 从 [user, host, port, path] 提取通用路径参数
fn extract_path_params(params: &Value) -> Result<(&str, &str, u16, &str), anyhow::Error> {
    let args = params_array(params)?;
    let (user, host, port) = extract_target(args)?;
    let path = arg_str(args, 3, "path")?;
    Ok((user, host, port, path))
}

/// 从 [user, host, port, password?] 提取连接参数
fn extract_connect_params(
    params: &Value,
) -> Result<(&str, &str, u16, Option<&str>), anyhow::Error> {
    let args = params_array(params)?;
    let (user, host, port) = extract_target(args)?;
    let password = match args.get(3) {
        None | Some(Value::Nil) => None,
        Some(_) => Some(arg_str(args, 3, "password")?),
    };
    Ok((user, host, port, password))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arg_helpers_report_accurate_errors() {
        let args = vec![
            Value::String("u".into()),
            Value::Binary(vec![0xff, 0xfe]),
            Value::Integer(22.into()),
        ];
        assert_eq!(arg_str(&args, 0, "user").unwrap(), "u");
        let e = arg_str(&args, 1, "host").unwrap_err().to_string();
        assert!(e.contains("not valid UTF-8"), "{}", e);
        let e = arg_str(&args, 5, "path").unwrap_err().to_string();
        assert_eq!(e, "Missing path");
        assert_eq!(arg_bytes(&args, 1, "content").unwrap(), &[0xff, 0xfe]);
    }

    #[test]
    fn extract_target_defaults_port() {
        let args = vec![Value::String("u".into()), Value::String("h".into())];
        assert_eq!(extract_target(&args).unwrap(), ("u", "h", 22));
    }
}
