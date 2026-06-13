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
//   zero://user@host:port/path  ↔  file:///path
//   TCP→SSH: 替换 "zero://user@host:port" → "file://"
//   SSH→TCP: 替换 "file://"               → "zero://user@host:port"
//
// 注意：vim.uri_from_bufnr 对已带 scheme 的 buffer name（如 zero://...）原样返回，
// 不会加 file:// 前缀，因此 client_prefix 不含 "file://" 前缀。

use crate::cmd::spec::shell_quote;
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
    cmd_argv: Vec<String>,
    client_prefix: &str,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    let key = DaemonState::connection_key(user, host, port);

    // Verify the connection exists in state
    {
        let state_lock = state.lock().unwrap();
        if !state_lock.sessions.contains_key(&key) {
            return Err(anyhow::anyhow!("NOT_CONNECTED: {}", key));
        }
    }

    let file_prefix = "file://".to_string();
    let client_prefix_s = client_prefix.to_string();

    let user_s = user.to_string();
    let host_s = host.to_string();
    let login_cmd = build_lsp_login_command(&cmd_argv)?;
    let cmd_display = cmd_argv.join(" ");

    // Bind a random ephemeral port locally
    let listener = TcpListener::bind("127.0.0.1:0").context("Failed to bind random TCP port")?;
    let local_port = listener.local_addr()?.port();

    eprintln!(
        "Daemon: LSP proxy :{} → {}@{}:{} ({})",
        local_port, user, host, port, cmd_display
    );

    thread::spawn(move || {
        if let Ok((tcp_stream, _)) = listener.accept() {
            drop(listener);

            // Spawn ssh as a child process. It reuses ~/.ssh/config + SSH Agent.
            // Prepend mason/bin to PATH so tools installed via Mason are found
            // without needing a login shell or modifying ~/.profile.
            //
            // ControlMaster=auto + ControlPersist multiplexes LSP launches over a
            // single SSH connection. The first LSP pays the full TCP+key+auth cost;
            // subsequent ones (or restart-after-stop) attach in milliseconds.
            // %C hashes (local_user, host, port, remote_user) → unique per target.
            let ssh_result = Command::new("ssh")
                .arg("-o")
                .arg("StrictHostKeyChecking=no")
                .arg("-o")
                .arg("BatchMode=yes") // non-interactive (uses Agent)
                .arg("-o")
                .arg("ControlMaster=auto")
                .arg("-o")
                .arg("ControlPath=/tmp/zero-nvim-cm-%C")
                .arg("-o")
                .arg("ControlPersist=10m")
                // SSH-layer keepalive：每 30s 发一个心跳；连续 3 次（90s）无应答
                // 才判死。两个作用：(1) 让 NAT/防火墙的 idle flow timeout 永远归
                // 零，避免 idle-disconnect；(2) 真正掉线时 90s 内 ssh 子进程退出，
                // 触发 Lua 端的 on_exit 自动重启路径。否则一直 idle 又没人发包，
                // 进程会僵在 read() 上几十分钟，直到 TCP RST 才感知。
                .arg("-o")
                .arg("ServerAliveInterval=30")
                .arg("-o")
                .arg("ServerAliveCountMax=3")
                .arg("-p")
                .arg(port.to_string())
                .arg(format!("{}@{}", user_s, host_s))
                .arg(&login_cmd)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped()) // Pipe stderr to prevent blocking if parent doesn't read fast enough
                .spawn();

            match ssh_result {
                Ok(mut child) => {
                    let child_stdin = child.stdin.take().expect("child stdin");
                    let child_stdout = child.stdout.take().expect("child stdout");
                    let child_stderr = child.stderr.take().expect("child stderr");

                    // Thread 0: Consume SSH stderr to prevent blocking
                    // We also log it to daemon stderr so Neovim can see it (optionally filtered)
                    thread::spawn(move || {
                        use std::io::{BufRead, BufReader};
                        let reader = BufReader::new(child_stderr);
                        for line in reader.lines() {
                            if let Ok(l) = line {
                                eprintln!("[SSH-ERR] {}", l);
                            }
                        }
                    });

                    let tcp_writer = tcp_stream.try_clone().expect("Failed to clone TCP stream");

                    let tcp_reader = tcp_stream;
                    let from1 = client_prefix_s.clone();
                    let to1 = file_prefix.clone();
                    thread::spawn(move || {
                        let mut r = tcp_reader;
                        let mut w = child_stdin;
                        let _ = pump_and_translate(&mut r, &mut w, &from1, &to1, "TCP->SSH");
                    });

                    // Thread 2: SSH stdout → TCP (Neovim)
                    // Translate: file:// → zero://user@host:port
                    let from2 = file_prefix;
                    let to2 = client_prefix_s;
                    thread::spawn(move || {
                        let mut r = child_stdout;
                        let mut w = tcp_writer;
                        let _ = pump_and_translate(&mut r, &mut w, &from2, &to2, "SSH->TCP");
                        // Wait for child process to finish
                        if let Ok(status) = child.wait() {
                            if !status.success() {
                                eprintln!("Daemon: LSP process exited abnormally: {:?}", status);
                            }
                        }
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

pub fn handle_probe_lsp(
    user: &str,
    host: &str,
    port: u16,
    cmd_argv: Vec<String>,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    let key = DaemonState::connection_key(user, host, port);
    {
        let state_lock = state.lock().unwrap();
        if !state_lock.sessions.contains_key(&key) {
            return Err(anyhow::anyhow!("NOT_CONNECTED: {}", key));
        }
    }

    let probe_cmd = build_lsp_probe_command(&cmd_argv)?;
    let output = Command::new("ssh")
        .arg("-o")
        .arg("StrictHostKeyChecking=no")
        .arg("-o")
        .arg("BatchMode=yes")
        .arg("-o")
        .arg("ControlMaster=auto")
        .arg("-o")
        .arg("ControlPath=/tmp/zero-nvim-cm-%C")
        .arg("-o")
        .arg("ControlPersist=10m")
        .arg("-o")
        .arg("ConnectTimeout=5")
        .arg("-p")
        .arg(port.to_string())
        .arg(format!("{}@{}", user, host))
        .arg(&probe_cmd)
        .output();

    match output {
        Ok(out) if out.status.success() => Ok(lsp_probe_result(true, "")),
        Ok(out) => {
            let stderr = String::from_utf8_lossy(&out.stderr);
            let stdout = String::from_utf8_lossy(&out.stdout);
            let msg = if !stderr.trim().is_empty() {
                stderr.trim().to_string()
            } else if !stdout.trim().is_empty() {
                stdout.trim().to_string()
            } else {
                format!("ssh exited with status {}", out.status)
            };
            Ok(lsp_probe_result(false, &msg))
        }
        Err(e) => Ok(lsp_probe_result(
            false,
            &format!("failed to spawn ssh: {}", e),
        )),
    }
}

fn lsp_probe_result(ok: bool, message: &str) -> Value {
    Value::Map(vec![
        (Value::String("ok".into()), Value::Boolean(ok)),
        (
            Value::String("message".into()),
            Value::String(message.into()),
        ),
    ])
}

fn build_lsp_login_command(argv: &[String]) -> Result<String, anyhow::Error> {
    if argv.is_empty() {
        return Err(anyhow::anyhow!("LSP command argv is empty"));
    }
    let argv_quoted = argv
        .iter()
        .map(|arg| shell_quote(arg))
        .collect::<Vec<_>>()
        .join(" ");
    Ok(format!(
        "PATH=$HOME/.local/share/nvim/mason/bin:$PATH exec {}",
        argv_quoted
    ))
}

fn build_lsp_probe_command(argv: &[String]) -> Result<String, anyhow::Error> {
    let bin = argv
        .first()
        .ok_or_else(|| anyhow::anyhow!("LSP command argv is empty"))?;
    Ok(format!(
        "PATH=$HOME/.local/share/nvim/mason/bin:$PATH command -v -- {} >/dev/null 2>&1",
        shell_quote(bin)
    ))
}

fn pump_and_translate<R: Read, W: Write>(
    reader: &mut R,
    writer: &mut W,
    from: &str,
    to: &str,
    label: &str,
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

            // [Safety Check] If headers grow too large, it's likely non-LSP garbage (e.g. stdout logs)
            if headers.len() > 8192 {
                eprintln!(
                    "[{}] HEADER OVERFLOW (>8KB). Dumping buffer:\n{}",
                    label, headers
                );
                return Err(anyhow::anyhow!(
                    "Header overflow - potential non-LSP output detected"
                ));
            }

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
        // tcp->ssh: "zero://user@host:port" → "file://"   (zero://user@host:22/path → file:///path)
        // ssh->tcp: "file://"               → "zero://user@host:port" (file:///path → zero://user@host:22/path)
        let new_body = match String::from_utf8(body) {
            Ok(s) => s.replace(from, to).into_bytes(),
            Err(e) => e.into_bytes(),
        };

        // 5. Reconstruct headers EXACTLY as LSP expects
        // (Just Content-Length + \r\n\r\n. We drop other headers like Content-Type to avoid
        // complexity, which is generally safe for Language Servers).
        let new_headers = format!("Content-Length: {}\r\n\r\n", new_body.len());
        // 6. Write out
        writer.write_all(new_headers.as_bytes())?;
        writer.write_all(&new_body)?;
        writer.flush()?;
    }
}

// Removing unused shell_quote to keep lints happy
// fn shell_quote(s: &str) -> String { ... }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lsp_login_command_quotes_argv_items() {
        let argv = vec![
            "/tmp/my language server".to_string(),
            "--stdio".to_string(),
            "--config=path with spaces.json".to_string(),
            "it's-ok".to_string(),
        ];

        let cmd = build_lsp_login_command(&argv).expect("command");

        assert_eq!(
            cmd,
            "PATH=$HOME/.local/share/nvim/mason/bin:$PATH exec '/tmp/my language server' '--stdio' '--config=path with spaces.json' 'it'\\''s-ok'"
        );
    }

    #[test]
    fn lsp_login_command_rejects_empty_argv() {
        let err = build_lsp_login_command(&[]).expect_err("empty argv must fail");
        assert!(err.to_string().contains("empty"));
    }

    #[test]
    fn lsp_probe_command_checks_first_argv_in_lsp_path() {
        let argv = vec!["based pyright".to_string(), "--stdio".to_string()];

        let cmd = build_lsp_probe_command(&argv).expect("probe command");

        assert_eq!(
            cmd,
            "PATH=$HOME/.local/share/nvim/mason/bin:$PATH command -v -- 'based pyright' >/dev/null 2>&1"
        );
    }

    #[test]
    fn lsp_probe_command_rejects_empty_argv() {
        let err = build_lsp_probe_command(&[]).expect_err("empty argv must fail");
        assert!(err.to_string().contains("empty"));
    }
}
