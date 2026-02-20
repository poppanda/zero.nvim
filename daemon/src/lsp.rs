// =============================================================================
// lsp.rs — 远程 LSP 代理 (TCP ↔ SSH process Stdio Forwarding)
// =============================================================================
// 为什么不用 libssh2 channel 做双向 IO？
//   libssh2 不是线程安全的。将同一个 session/channel 同时用在两个线程（一个写
//   stdin、一个读 stdout）会导致竞态，使 initialize 握手数据损坏，LSP 随即退出。
//
// 解决方案：使用系统 `ssh` 子进程，获得真正线程安全的 OS pipe。
//   - 子进程 stdin  ← TCP (Neovim 发来的 LSP 请求)
//   - 子进程 stdout → TCP (远端 LSP 响应)
//   - ssh reuses ~/.ssh/config + SSH Agent，无需再次输入密码
//
// URI 转换（TCP→SSH and SSH→TCP）:
//   remote://user@host:port:/path  ↔  file:///path
//   具体: 替换 "remote://user@host:port:" ↔ "file://"

use crate::state::DaemonState;
use anyhow::Context;
use rmpv::Value;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;

pub fn handle_start_lsp(
    user: &str,
    host: &str,
    port: u16,
    cmd: &str,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    eprintln!("handle_start_lsp triggered for cmd: {}", cmd);
    let key = DaemonState::connection_key(user, host, port);

    // Verify the connection exists in state
    {
        let state_lock = state.lock().unwrap();
        if !state_lock.sessions.contains_key(&key) {
            return Err(anyhow::anyhow!("NOT_CONNECTED: {}", key));
        }
    }

    // URI translation prefix for remote://user@host:port: ↔ file://
    // remote://ec2-user@52.197.224.3:22:/home/...  becomes  file:///home/...
    // Replacing "remote://ec2-user@52.197.224.3:22:" with "file://" (path /home/... stays intact)
    let remote_file_prefix = format!("remote://{}@{}:{}:", user, host, port);
    let file_prefix = "file://".to_string();

    let user_s = user.to_string();
    let host_s = host.to_string();
    let cmd_s = cmd.to_string();

    // Bind a random ephemeral port locally
    let listener = TcpListener::bind("127.0.0.1:0").context("Failed to bind random TCP port")?;
    let local_port = listener.local_addr()?.port();

    eprintln!("LSP Proxy listening on 127.0.0.1:{}", local_port);

    thread::spawn(move || {
        eprintln!(
            "Background thread spawned to accept LSP connection on {}",
            local_port
        );

        if let Ok((tcp_stream, _)) = listener.accept() {
            eprintln!(
                "Accepted Neovim LSP connection from {}",
                tcp_stream.peer_addr().unwrap()
            );
            drop(listener);

            // Spawn ssh as a child process. It reuses ~/.ssh/config + SSH Agent.
            // Prepend mason/bin to PATH so tools installed via Mason are found
            // without needing a login shell or modifying ~/.profile.
            let login_cmd = format!("PATH=$HOME/.local/share/nvim/mason/bin:$PATH {}", cmd_s);
            let ssh_result = Command::new("ssh")
                .arg("-o")
                .arg("StrictHostKeyChecking=no")
                .arg("-o")
                .arg("BatchMode=yes") // non-interactive (uses Agent)
                .arg("-p")
                .arg(port.to_string())
                .arg(format!("{}@{}", user_s, host_s))
                .arg(&login_cmd)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::inherit()) // let ssh errors flow to daemon stderr (Neovim WARN)
                .spawn();

            match ssh_result {
                Ok(mut child) => {
                    eprintln!("SSH child process started for LSP: {}", cmd_s);

                    let child_stdin = child.stdin.take().expect("child stdin");
                    let child_stdout = child.stdout.take().expect("child stdout");

                    let tcp_writer = tcp_stream.try_clone().expect("Failed to clone TCP stream");

                    let u1 = user_s.clone();
                    let h1 = host_s.clone();
                    // Thread 1: TCP (Neovim) → SSH stdin
                    // Translate: remote://user@host:port: → file://
                    let tcp_reader = tcp_stream;
                    let from1 = remote_file_prefix.clone();
                    let to1 = file_prefix.clone();
                    thread::spawn(move || {
                        let mut r = tcp_reader;
                        let mut w = child_stdin;
                        if let Err(e) = pump_and_translate(
                            &mut r, &mut w, &from1, &to1, "TCP->SSH", &u1, &h1, port,
                        ) {
                            eprintln!("TCP -> SSH pump ended: {:?}", e);
                        }
                    });

                    // Thread 2: SSH stdout → TCP (Neovim)
                    // Translate: file:// → remote://user@host:port:
                    let from2 = file_prefix;
                    let to2 = remote_file_prefix;
                    let u2 = user_s;
                    let h2 = host_s;
                    thread::spawn(move || {
                        let mut r = child_stdout;
                        let mut w = tcp_writer;
                        if let Err(e) = pump_and_translate(
                            &mut r, &mut w, &from2, &to2, "SSH->TCP", &u2, &h2, port,
                        ) {
                            eprintln!("SSH -> TCP pump ended: {:?}", e);
                        }
                        // Wait for child process to finish
                        let status = child.wait();
                        eprintln!("SSH process exited with status: {:?}", status);
                    });
                }
                Err(e) => {
                    eprintln!("Failed to spawn ssh for LSP: {:?}", e);
                }
            }
        }
    });

    Ok(Value::Integer(local_port.into()))
}

fn pump_and_translate<R: Read, W: Write>(
    reader: &mut R,
    writer: &mut W,
    from: &str,
    to: &str,
    label: &str,
    user: &str,
    host: &str,
    port: u16,
) -> Result<(), anyhow::Error> {
    loop {
        let mut headers = String::new();
        let mut content_length: Option<usize> = None;

        // 1. Read headers byte by byte until \r\n\r\n
        loop {
            let mut byte = [0u8; 1];
            let n = reader.read(&mut byte)?;
            if n == 0 {
                return Ok(()); // EOF — stream closed
            }
            headers.push(byte[0] as char);
            if headers.ends_with("\r\n\r\n") {
                break;
            }
        }

        // 2. Parse Content-Length header
        for line in headers.lines() {
            let lower = line.to_lowercase();
            if lower.starts_with("content-length:") {
                if let Some(val) = line.splitn(2, ':').nth(1) {
                    if let Ok(n) = val.trim().parse::<usize>() {
                        content_length = Some(n);
                    }
                }
            }
        }

        let content_length = content_length.ok_or_else(|| {
            anyhow::anyhow!("Missing or invalid Content-Length header:\n{}", headers)
        })?;

        // 3. Read exactly content_length bytes
        let mut body = vec![0u8; content_length];
        reader.read_exact(&mut body)?;

        // 4. Translate URI in JSON body
        let new_body = match String::from_utf8(body.clone()) {
            Ok(s) => {
                let mut translated = s.clone();

                if label == "TCP->SSH" {
                    // Collect all possible remote prefixes that we might see from Neovim.
                    // Neovim's uri_from_fname or oil.nvim might produce different schemes.
                    let mut prefixes = Vec::new();

                    // Standard remote:// variants
                    prefixes.push(format!("remote://{}@{}:{}:", user, host, port));
                    // oil-zero:// variants (with and without port)
                    prefixes.push(format!("oil-zero://{}@{}:{}/", user, host, port));
                    prefixes.push(format!("oil-zero://{}@{}/", user, host));

                    // Now handle the same with "file://" or "file///" prepended by Neovim
                    let mut all_bad = Vec::new();
                    for p in prefixes {
                        let p_copy = p.clone();
                        all_bad.push(p_copy.clone());
                        all_bad.push(format!("file://{}", p_copy));
                        all_bad.push(format!("file:///{}", p_copy));
                    }

                    all_bad.sort_by(|a, b| b.len().cmp(&a.len()));

                    for bad in all_bad {
                        translated = translated.replace(&bad, to);
                    }
                } else {
                    // SSH->TCP (LSP Server -> Neovim): Standard replacement
                    translated = translated.replace(from, to);
                }

                if translated != s {
                    eprintln!(
                        "[{}] URI translated: '{}...' -> '{}...'",
                        label,
                        &from[..from.len().min(35)],
                        &to[..to.len().min(35)]
                    );
                    eprintln!(
                        "[{}] Translated Payload Preview: {}",
                        label,
                        &translated[..translated.len().min(500)]
                    );
                }
                if translated.contains("\"method\":\"initialize\"") {
                    std::fs::write("/tmp/zero_lsp_init_dump.json", &translated).unwrap();
                }
                translated.into_bytes()
            }
            Err(_) => body,
        };

        // 5. Reconstruct headers EXACTLY as LSP expects
        // (Just Content-Length + \r\n\r\n. We drop other headers like Content-Type to avoid
        // complexity, which is generally safe for Language Servers).
        let new_headers = format!("Content-Length: {}\r\n\r\n", new_body.len());
        if label == "TCP->SSH" {
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open("/tmp/daemon_ssh_in.bin")
            {
                let _ = f.write_all(new_headers.as_bytes());
                let _ = f.write_all(&new_body);
                let _ = f.write_all(b"\n");
            }
        } else {
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open("/tmp/daemon_ssh_out.bin")
            {
                let _ = f.write_all(new_headers.as_bytes());
                let _ = f.write_all(&new_body);
                let _ = f.write_all(b"\n");
            }
        }
        // 6. Write out
        writer.write_all(new_headers.as_bytes())?;
        writer.write_all(&new_body)?;
        writer.flush()?;
    }
}

// Removing unused shell_quote to keep lints happy
// fn shell_quote(s: &str) -> String { ... }
