// =============================================================================
// cmd/dispatch.rs — RPC handler 入口
// =============================================================================
// 三个 RPC：
//   cmd_sync     [user, host, port, spec_map] -> { stdout, stderr, code, duration_ms }
//   cmd_stream   [session_id, user, host, port, spec_map] -> true（事件流走通知）
//   cmd_cancel   [session_id] -> true（无须等结果）
//
// spec_map 字段：
//   argv: string[]               (必填)
//   env:  [[k,v], [k,v], ...]    (可选)
//   cwd:  string                 (可选)
//   stdin: bytes/string          (可选)
//   timeout_ms: integer          (可选)
//   pty: bool                    (可选)
//
// 通知格式（daemon → Lua）：
//   [2, "nvim_exec_lua",
//    ["require('zero-nvim.cmd.exec')._dispatch(...)",
//     [session_id, kind, payload]]]
//
// payload 按 kind：
//   "stdout" / "stderr" → Binary(bytes)
//   "exit"              → Array [code, signal_or_nil, duration_ms]
//   "aborted"           → String(reason)

use crate::cmd::exec_stream::run_streaming;
use crate::cmd::exec_sync::run_sync;
use crate::cmd::registry::CmdHandle;
use crate::cmd::spec::{ConnTarget, RemoteCommand};
use crate::cmd::CommandEvent;
use crate::state::DaemonState;
use rmpv::Value;
use std::sync::{mpsc, Arc, Mutex};

pub fn handle_cmd_sync(
    params: &Value,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    let args = params.as_array().ok_or(anyhow::anyhow!("Invalid params"))?;
    let user = args.get(0).and_then(|v| v.as_str()).ok_or(anyhow::anyhow!("Missing user"))?;
    let host = args.get(1).and_then(|v| v.as_str()).ok_or(anyhow::anyhow!("Missing host"))?;
    let port = args.get(2).and_then(|v| v.as_u64()).unwrap_or(22) as u16;
    let spec = args.get(3).ok_or(anyhow::anyhow!("Missing spec"))?;

    let cmd = parse_spec(spec)?;
    let out = run_sync(user, host, port, &cmd, state)?;

    Ok(Value::Map(vec![
        (
            Value::String("stdout".into()),
            Value::Binary(out.stdout),
        ),
        (
            Value::String("stderr".into()),
            Value::Binary(out.stderr),
        ),
        (
            Value::String("code".into()),
            Value::Integer(out.code.into()),
        ),
        (
            Value::String("duration_ms".into()),
            Value::Integer(out.duration_ms.into()),
        ),
    ]))
}

pub fn handle_cmd_stream(
    params: &Value,
    state: &Arc<Mutex<DaemonState>>,
    tx: mpsc::Sender<Value>,
) -> Result<Value, anyhow::Error> {
    let args = params.as_array().ok_or(anyhow::anyhow!("Invalid params"))?;
    let session_id = args.get(0).and_then(|v| v.as_str()).ok_or(anyhow::anyhow!("Missing session_id"))?;
    let user = args.get(1).and_then(|v| v.as_str()).ok_or(anyhow::anyhow!("Missing user"))?;
    let host = args.get(2).and_then(|v| v.as_str()).ok_or(anyhow::anyhow!("Missing host"))?;
    let port = args.get(3).and_then(|v| v.as_u64()).unwrap_or(22) as u16;
    let spec = args.get(4).ok_or(anyhow::anyhow!("Missing spec"))?;

    let target = ConnTarget::new(user.to_string(), host.to_string(), port);
    let cmd = parse_spec(spec)?;

    // 注册句柄
    let handle = Arc::new(CmdHandle::new(session_id.to_string()));
    {
        let state_lock = state.lock().unwrap();
        let reg_arc = state_lock.running_commands.clone();
        drop(state_lock);
        let mut reg = reg_arc.lock().unwrap();
        reg.insert(handle.clone());
    }

    // sink：把 CommandEvent 翻译成 RPC notification 推到 tx
    let sid_for_sink = session_id.to_string();
    let tx_for_sink = tx.clone();
    let sink = move |ev: CommandEvent| {
        let kind = ev.kind();
        let payload = match ev {
            CommandEvent::Stdout(b) => Value::Binary(b),
            CommandEvent::Stderr(b) => Value::Binary(b),
            CommandEvent::Exit {
                code,
                signal,
                duration_ms,
            } => {
                let signal_v = signal.map(|s| Value::String(s.into())).unwrap_or(Value::Nil);
                Value::Array(vec![
                    Value::Integer(code.into()),
                    signal_v,
                    Value::Integer(duration_ms.into()),
                ])
            }
            CommandEvent::Aborted { reason } => Value::String(reason.into()),
        };

        let lua_args = Value::Array(vec![
            Value::String(sid_for_sink.clone().into()),
            Value::String(kind.into()),
            payload,
        ]);
        let notification = Value::Array(vec![
            Value::Integer(2.into()),
            Value::String("nvim_exec_lua".into()),
            Value::Array(vec![
                Value::String("require('zero-nvim.cmd.exec')._dispatch(...)".into()),
                lua_args,
            ]),
        ]);
        let _ = tx_for_sink.send(notification);
    };

    run_streaming(target, cmd, sink, handle, state.clone())?;

    Ok(Value::Boolean(true))
}

pub fn handle_cmd_cancel(
    params: &Value,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    let args = params.as_array().ok_or(anyhow::anyhow!("Invalid params"))?;
    let session_id = args
        .get(0)
        .and_then(|v| v.as_str())
        .ok_or(anyhow::anyhow!("Missing session_id"))?;

    let reg_arc = {
        let state_lock = state.lock().unwrap();
        state_lock.running_commands.clone()
    };
    let handle_opt = {
        let reg = reg_arc.lock().unwrap();
        reg.get(session_id)
    };
    if let Some(h) = handle_opt {
        h.cancel.cancel();
        eprintln!("Daemon: cmd_cancel session={}", session_id);
    } else {
        eprintln!("Daemon: cmd_cancel session={} 未找到（可能已结束）", session_id);
    }
    Ok(Value::Boolean(true))
}

/// 把 spec_map（rmpv Value） 解析为 RemoteCommand
fn parse_spec(spec: &Value) -> Result<RemoteCommand, anyhow::Error> {
    let map = spec
        .as_map()
        .ok_or(anyhow::anyhow!("spec must be a map"))?;

    let mut argv: Vec<String> = Vec::new();
    let mut env: Vec<(String, String)> = Vec::new();
    let mut cwd: Option<String> = None;
    let mut stdin: Option<Vec<u8>> = None;
    let mut timeout_ms: Option<u64> = None;
    let mut pty = false;

    for (k, v) in map {
        let key = k.as_str().unwrap_or("");
        match key {
            "argv" => {
                let arr = v.as_array().ok_or(anyhow::anyhow!("argv must be array"))?;
                for item in arr {
                    let s = item
                        .as_str()
                        .ok_or(anyhow::anyhow!("argv item must be string"))?;
                    argv.push(s.to_string());
                }
            }
            "env" => {
                if let Some(arr) = v.as_array() {
                    for pair in arr {
                        if let Some(p) = pair.as_array() {
                            if p.len() == 2 {
                                if let (Some(k), Some(val)) = (p[0].as_str(), p[1].as_str()) {
                                    env.push((k.to_string(), val.to_string()));
                                }
                            }
                        }
                    }
                }
            }
            "cwd" => {
                cwd = v.as_str().map(|s| s.to_string());
            }
            "stdin" => {
                if let Some(s) = v.as_str() {
                    stdin = Some(s.as_bytes().to_vec());
                } else if let Value::Binary(b) = v {
                    stdin = Some(b.clone());
                }
            }
            "timeout_ms" => {
                timeout_ms = v.as_u64();
            }
            "pty" => {
                pty = v.as_bool().unwrap_or(false);
            }
            _ => {}
        }
    }

    if argv.is_empty() {
        return Err(anyhow::anyhow!("spec.argv is empty"));
    }

    let mut cmd = RemoteCommand::new(argv);
    cmd.env = env;
    cmd.cwd = cwd;
    cmd.stdin = stdin;
    cmd.pty = pty;
    if let Some(ms) = timeout_ms {
        cmd = cmd.timeout_ms(ms);
    }
    Ok(cmd)
}
