// =============================================================================
// search.rs — 远程全局搜索
// =============================================================================

use crate::state::DaemonState;
use anyhow::Context;
use rmpv::Value;
use std::io::{BufRead, BufReader};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;

pub fn handle_global_search(
    user: &str,
    host: &str,
    port: u16,
    path: &str,
    query: &str,
    session_id: &str,
    case_sensitive: bool,
    whole_word: bool,
    file_types: &str,
    state: &Arc<Mutex<DaemonState>>,
    tx: mpsc::Sender<Value>,
) -> Result<Value, anyhow::Error> {
    let state = state.clone();
    let user = user.to_string();
    let host = host.to_string();
    let path = path.to_string();
    let query = query.to_string();
    let session_id = session_id.to_string();
    let file_types = file_types.to_string();

    eprintln!("Daemon: 搜索 \"{}\" in {}", query, path);

    // 后台线程跑搜索；走 with_conn 来覆盖死会话自动重连。
    // 注意：with_conn 在 dead-session 错误时会重试一次闭包，如果连接是
    // 在流式输出**中途**断的，重试会重发早期 chunk。这种情况罕见
    // （典型场景是 idle 后 channel_session 直接失败，0 chunk 已发），
    // 用户再触发一次搜索就能拿到干净结果，不为它增加复杂度。
    thread::spawn(move || {
        let result = DaemonState::with_conn(&state, &user, &host, port, |conn| {
            run_search(
                conn,
                &path,
                &query,
                &session_id,
                case_sensitive,
                whole_word,
                &file_types,
                &tx,
            )
        });

        if let Err(e) = &result {
            let msg = format!("{}", e);
            eprintln!("Daemon: 搜索失败: {}", msg);
            send_error(&tx, &session_id, &msg);
        }
        // 无条件发 end，确保 Lua 侧 UI 不会卡在加载状态
        send_end(&tx, &session_id);
    });

    Ok(Value::Boolean(true))
}

fn run_search(
    conn: &mut crate::state::ConnSession,
    path: &str,
    query: &str,
    session_id: &str,
    case_sensitive: bool,
    whole_word: bool,
    file_types: &str,
    tx: &mpsc::Sender<Value>,
) -> Result<(), anyhow::Error> {
    let mut channel = conn
        .session
        .channel_session()
        .context("Failed to create channel_session")?;

    let quote = |s: &str| format!("'{}'", s.replace('\'', "'\\''"));

    let mut flags = vec![
        "--line-number",
        "--column",
        "--no-heading",
        "--color=never",
        "--with-filename",
    ];
    if case_sensitive {
        flags.push("--case-sensitive");
    } else {
        flags.push("--ignore-case");
    }
    if whole_word {
        flags.push("--word-regexp");
    }

    // Parse file_types: "type:lua,rust;glob:vue,svelte"
    let mut type_flags: Vec<String> = Vec::new();
    if !file_types.is_empty() {
        for part in file_types.split(';') {
            if let Some(types) = part.strip_prefix("type:") {
                for t in types.split(',').filter(|t| !t.is_empty()) {
                    type_flags.push(format!("--type {}", t));
                }
            } else if let Some(globs) = part.strip_prefix("glob:") {
                for g in globs.split(',').filter(|g| !g.is_empty()) {
                    type_flags.push(format!("--glob '*.{}'", g));
                }
            }
        }
    }

    let rg_core = format!(
        "PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:/home/linuxbrew/.linuxbrew/bin\" rg {} {} {} {}",
        flags.join(" "),
        type_flags.join(" "),
        quote(query),
        quote(path)
    );

    // Using sh -c to ensure the PATH assignment works robustly without relying on interactive profiles
    let rg_cmd = format!("sh -c {}", quote(&rg_core));

    channel.exec(&rg_cmd).context("Failed to exec rg command")?;

    let stdout = channel.stream(0);
    let mut stderr_stream = channel.stderr();

    let reader = BufReader::new(stdout);

    let mut chunk = Vec::new();
    let chunk_size = 50;

    for line_result in reader.lines() {
        if let Ok(line) = line_result {
            chunk.push(Value::String(line.into()));
            if chunk.len() >= chunk_size {
                send_chunk(tx, session_id, &chunk);
                chunk.clear();
            }
        }
    }

    if !chunk.is_empty() {
        send_chunk(tx, session_id, &chunk);
    }

    // Read any remaining stderr output
    use std::io::Read;
    let mut stderr_str = String::new();
    let _ = stderr_stream.read_to_string(&mut stderr_str);
    if !stderr_str.trim().is_empty() {
        eprintln!("Daemon: rg stderr: {}", stderr_str.trim());
        send_error(tx, session_id, stderr_str.trim());
    }

    let _ = channel.wait_close();

    Ok(())
}

fn send_chunk(tx: &mpsc::Sender<Value>, session_id: &str, lines: &[Value]) {
    let code = "require('zero-nvim.search').on_chunk(...)";
    let args = Value::Array(vec![
        Value::String(session_id.into()),
        Value::Array(lines.to_vec()),
    ]);

    let notification = Value::Array(vec![
        Value::Integer(2.into()),
        Value::String("nvim_exec_lua".into()),
        Value::Array(vec![Value::String(code.into()), args]),
    ]);
    let _ = tx.send(notification);
}

fn send_error(tx: &mpsc::Sender<Value>, session_id: &str, error_msg: &str) {
    let code = "require('zero-nvim.search').on_error(...)";
    let args = Value::Array(vec![
        Value::String(session_id.into()),
        Value::String(error_msg.into()),
    ]);

    let notification = Value::Array(vec![
        Value::Integer(2.into()),
        Value::String("nvim_exec_lua".into()),
        Value::Array(vec![Value::String(code.into()), args]),
    ]);
    let _ = tx.send(notification);
}

fn send_end(tx: &mpsc::Sender<Value>, session_id: &str) {
    let code = "require('zero-nvim.search').on_end(...)";
    let args = Value::Array(vec![Value::String(session_id.into())]);

    let notification = Value::Array(vec![
        Value::Integer(2.into()),
        Value::String("nvim_exec_lua".into()),
        Value::Array(vec![Value::String(code.into()), args]),
    ]);
    let _ = tx.send(notification);
}
