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
    state: &Arc<Mutex<DaemonState>>,
    tx: mpsc::Sender<Value>,
) -> Result<Value, anyhow::Error> {
    eprintln!("handle_global_search triggered for path: {}", path);
    let key = DaemonState::connection_key(user, host, port);

    let state_lock = state.lock().unwrap();
    let sess = state_lock
        .sessions
        .get(&key)
        .ok_or(anyhow::anyhow!("NOT_CONNECTED: {}", key))?;

    let sess_clone = sess.clone();
    let path_clone = path.to_string();
    let query_clone = query.to_string();
    let session_id_clone = session_id.to_string();

    drop(state_lock);

    thread::spawn(move || {
        eprintln!("Background thread spawned for global_search");
        if let Err(e) = run_search(
            sess_clone,
            &path_clone,
            &query_clone,
            &session_id_clone,
            case_sensitive,
            whole_word,
            tx,
        ) {
            eprintln!("run_search error: {:?}", e);
        }
    });

    Ok(Value::Boolean(true))
}

fn run_search(
    sess: ssh2::Session,
    path: &str,
    query: &str,
    session_id: &str,
    case_sensitive: bool,
    whole_word: bool,
    tx: mpsc::Sender<Value>,
) -> Result<(), anyhow::Error> {
    let mut channel = sess
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

    let rg_core = format!(
        "PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:/home/linuxbrew/.linuxbrew/bin\" rg {} {} {}",
        flags.join(" "),
        quote(query),
        quote(path)
    );

    // Using sh -c to ensure the PATH assignment works robustly without relying on interactive profiles
    let rg_cmd = format!("sh -c {}", quote(&rg_core));

    eprintln!("Executing remote command: {}", rg_cmd);

    channel.exec(&rg_cmd).context("Failed to exec rg command")?;

    let stdout = channel.stream(0);
    // Read stderr in a separate buffer
    let mut stderr_stream = channel.stderr();

    let reader = BufReader::new(stdout);

    let mut chunk = Vec::new();
    let chunk_size = 50;

    let mut line_count = 0;
    for line_result in reader.lines() {
        if let Ok(line) = line_result {
            chunk.push(Value::String(line.into()));
            line_count += 1;
            if chunk.len() >= chunk_size {
                send_chunk(&tx, session_id, &chunk);
                chunk.clear();
            }
        }
    }
    eprintln!("run_search read {} lines from stdout", line_count);

    if !chunk.is_empty() {
        send_chunk(&tx, session_id, &chunk);
    }

    // Read any remaining stderr output
    use std::io::Read;
    let mut stderr_str = String::new();
    let _ = stderr_stream.read_to_string(&mut stderr_str);
    if !stderr_str.trim().is_empty() {
        eprintln!("rg stderr: {}", stderr_str.trim());
        send_error(&tx, session_id, stderr_str.trim());
    }

    let _ = channel.wait_close();
    send_end(&tx, session_id);

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
