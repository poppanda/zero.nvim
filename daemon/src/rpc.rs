// =============================================================================
// rpc.rs — Msgpack-RPC 收发 & 方法分发
// =============================================================================
// stdin 逐条读消息；所有输出（response / 通知）经同一个 mpsc 通道交给唯一的
// stdout 写线程，避免多线程写冲突。

use crate::state::{SharedState, Target};
use crate::{cmd, connect, fs, lsp, ssh_config};
use anyhow::anyhow;
use rmpv::{decode, encode, Value};
use std::io::Write;
use std::sync::mpsc;

pub type Outbox = mpsc::Sender<Value>;

pub fn serve(state: SharedState) {
    let (tx, rx) = mpsc::channel::<Value>();
    std::thread::spawn(move || {
        let mut stdout = std::io::stdout();
        while let Ok(msg) = rx.recv() {
            if encode::write_value(&mut stdout, &msg).is_ok() {
                let _ = stdout.flush();
            }
        }
    });

    // stdin 关闭 = Neovim 退出
    let mut reader = std::io::stdin().lock();
    while let Ok(msg) = decode::read_value(&mut reader) {
        let Value::Array(mut args) = msg else {
            continue;
        };
        // request: [0, msgid, method, params]；notification（rpcnotify）: [2, method, params]
        let (id, method, params) = match (args.first().and_then(|v| v.as_u64()), args.len()) {
            (Some(0), 4) => {
                let Some(id) = args[1].as_u64() else { continue };
                (
                    Some(id),
                    args[2].as_str().map(str::to_string),
                    args.pop().unwrap(),
                )
            }
            (Some(2), 3) => (
                None,
                args[1].as_str().map(str::to_string),
                args.pop().unwrap(),
            ),
            _ => continue,
        };
        let Some(method) = method else {
            if let Some(id) = id {
                let _ = tx.send(response(id, Err(anyhow!("Invalid method name"))));
            }
            continue;
        };

        let (state, tx) = (state.clone(), tx.clone());
        let inline = is_inline_method(&method);
        let run = move || {
            let result = dispatch(&method, &params, &state, &tx);
            match id {
                Some(id) => {
                    let _ = tx.send(response(id, result));
                }
                // 通知无需回复；错误只打到 stderr
                None => {
                    if let Err(e) = result {
                        eprintln!("Daemon: notification {} 失败: {:#}", method, e);
                    }
                }
            }
        };
        if inline {
            run();
        } else {
            // 慢请求（建连 / 扫描 / 命令执行）各起一条线程，避免队头阻塞。
            // 同一连接上的操作仍由 ConnSession 的 Mutex 串行化。
            std::thread::spawn(run);
        }
    }
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
fn response(id: u64, result: anyhow::Result<Value>) -> Value {
    let (err, res) = match result {
        Ok(val) => (Value::Nil, val),
        Err(e) => (Value::from(format!("{:#}", e)), Value::Nil),
    };
    Value::Array(vec![Value::from(1), Value::from(id), err, res])
}

/// 字符串键的 msgpack map
pub fn map<const N: usize>(pairs: [(&str, Value); N]) -> Value {
    Value::Map(
        pairs
            .into_iter()
            .map(|(k, v)| (Value::from(k), v))
            .collect(),
    )
}

// =============================================================================
// 方法分发表
// =============================================================================
// 大多数方法的参数形如 [user, host, port, ...]。

fn dispatch(
    method: &str,
    params: &Value,
    state: &SharedState,
    tx: &Outbox,
) -> anyhow::Result<Value> {
    // msgpack-rpc 的 params 总是数组；万一不是，按"全部参数缺失"处理
    let a = Args(params.as_array().map_or(&[], |v| v.as_slice()));
    match method {
        "list_ssh_hosts" => ssh_config::list_hosts(state),
        "resolve_ssh_target" => ssh_config::resolve_target(a.str(0, "target")?, state),

        "connect" => connect::connect(&a.target(0)?, a.opt_str(3, "password")?, state)
            .map(|_| Value::Boolean(true)),

        "fetch_path" => fs::fetch_path(&a.target(0)?, a.str(3, "path")?, state),
        "fetch_paths" => {
            let paths = a
                .value(3, "paths")?
                .as_array()
                .ok_or(anyhow!("Invalid paths: expected array"))?;
            let paths = paths
                .iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect();
            fs::fetch_paths(&a.target(0)?, paths, state)
        }
        "fetch_file" => fs::fetch_file(&a.target(0)?, a.str(3, "path")?, state),
        // 内容可能不是合法 UTF-8（Latin-1 源码、二进制）：按原始字节接收
        "write_file" => fs::write_file(
            &a.target(0)?,
            a.str(3, "path")?,
            a.bytes(4, "content")?,
            state,
        ),
        "read_dir" => fs::read_dir(&a.target(0)?, a.str(3, "path")?, state),
        "stat" => fs::stat(&a.target(0)?, a.str(3, "path")?, state),
        "scan_project" => fs::scan_project(&a.target(0)?, a.str(3, "path")?, state),
        "mkdir" => fs::mkdir(&a.target(0)?, a.str(3, "path")?, state),
        "remove_file" => fs::remove_file(&a.target(0)?, a.str(3, "path")?, state),
        "remove_dir" => fs::remove_dir(&a.target(0)?, a.str(3, "path")?, state),
        "rename" => fs::rename(&a.target(0)?, a.str(3, "src")?, a.str(4, "dst")?, state),
        "exec_remote" => cmd::exec_remote(&a.target(0)?, a.str(3, "cmd")?, state),

        // ── 通用远程命令 ──
        "cmd_sync" => cmd::sync(&a.target(0)?, a.value(3, "spec")?, state),
        "cmd_stream" => cmd::stream(
            a.str(0, "session_id")?,
            a.target(1)?,
            a.value(4, "spec")?,
            state,
            tx,
        ),
        "cmd_cancel" => cmd::cancel(a.str(0, "session_id")?, state),
        "cmd_stdin_write" => cmd::stdin_write(a.str(0, "session_id")?, a.bytes(1, "data")?, state),
        "cmd_stdin_close" => cmd::stdin_close(a.str(0, "session_id")?, state),

        // ── LSP 代理 ──
        "lsp_probe" => lsp::probe(&a.target(0)?, lsp::parse_argv(a.value(3, "cmd")?)?, state),
        "lsp_start" => {
            let t = a.target(0)?;
            let argv = lsp::parse_argv(a.value(3, "cmd")?)?;
            let default_prefix = format!("zero://{}", t);
            let client_prefix = a.opt_str(4, "client_prefix")?.unwrap_or(&default_prefix);
            lsp::start(&t, argv, client_prefix, state)
        }

        _ => Err(anyhow!("Unknown method: {}", method)),
    }
}

/// 按位置取参数；区分"缺失"与"类型不对"两种错误
struct Args<'a>(&'a [Value]);

impl<'a> Args<'a> {
    fn value(&self, idx: usize, name: &str) -> anyhow::Result<&'a Value> {
        match self.0.get(idx) {
            None | Some(Value::Nil) => Err(anyhow!("Missing {}", name)),
            Some(v) => Ok(v),
        }
    }

    fn str(&self, idx: usize, name: &str) -> anyhow::Result<&'a str> {
        let invalid_utf8 = || anyhow!("Invalid {}: not valid UTF-8", name);
        match self.value(idx, name)? {
            Value::String(s) => s.as_str().ok_or_else(invalid_utf8),
            Value::Binary(b) => std::str::from_utf8(b).map_err(|_| invalid_utf8()),
            _ => Err(anyhow!("Invalid {}: expected string", name)),
        }
    }

    fn opt_str(&self, idx: usize, name: &str) -> anyhow::Result<Option<&'a str>> {
        match self.0.get(idx) {
            None | Some(Value::Nil) => Ok(None),
            Some(_) => self.str(idx, name).map(Some),
        }
    }

    /// 原始字节：接受 msgpack String（含非 UTF-8 内容）或 Binary
    fn bytes(&self, idx: usize, name: &str) -> anyhow::Result<&'a [u8]> {
        match self.value(idx, name)? {
            Value::String(s) => Ok(s.as_bytes()),
            Value::Binary(b) => Ok(b),
            _ => Err(anyhow!("Invalid {}: expected string or binary", name)),
        }
    }

    /// 从 [.., user, host, port?, ..] 提取连接目标（port 缺省 22）
    fn target(&self, idx: usize) -> anyhow::Result<Target> {
        let port = match self.0.get(idx + 2) {
            None | Some(Value::Nil) => 22,
            Some(v) => {
                let p = v
                    .as_u64()
                    .ok_or(anyhow!("Invalid port: expected integer"))?;
                u16::try_from(p).map_err(|_| anyhow!("Invalid port: {}", p))?
            }
        };
        Ok(Target::new(
            self.str(idx, "user")?,
            self.str(idx + 1, "host")?,
            port,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arg_helpers_report_accurate_errors() {
        let args = [
            Value::from("u"),
            Value::Binary(vec![0xff, 0xfe]),
            Value::from(22),
        ];
        let a = Args(&args);
        assert_eq!(a.str(0, "user").unwrap(), "u");
        let e = a.str(1, "host").unwrap_err().to_string();
        assert!(e.contains("not valid UTF-8"), "{}", e);
        assert_eq!(a.str(5, "path").unwrap_err().to_string(), "Missing path");
        assert_eq!(a.bytes(1, "content").unwrap(), &[0xff, 0xfe]);
        assert_eq!(a.opt_str(5, "password").unwrap(), None);
    }

    #[test]
    fn target_defaults_port() {
        let args = [Value::from("u"), Value::from("h")];
        assert_eq!(Args(&args).target(0).unwrap(), Target::new("u", "h", 22));
        let args = [Value::from("u"), Value::from("h"), Value::from(70000)];
        assert!(Args(&args).target(0).is_err());
    }
}
