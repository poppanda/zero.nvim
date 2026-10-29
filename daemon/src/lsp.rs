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
//   TCP→SSH: 替换 `"zero://user@host:port/` → `"file:///`
//   SSH→TCP: 替换 `"file:///`               → `"zero://user@host:port/`
//   只改 JSON 字符串值开头的 URI（前面紧跟 `"`，前缀后紧跟 `/`）：
//   避免 `:22` 误匹配 `:2222`，也不改 hover 文本里出现的 file:// 字样。
//
// 注意：vim.uri_from_bufnr 对已带 scheme 的 buffer name（如 zero://...）原样返回，
// 不会加 file:// 前缀，因此 client_prefix 不含 "file://" 前缀。

use crate::cmd::spec::shell_quote;
use crate::state::{DaemonState, LockExt};
use anyhow::Context;
use rmpv::Value;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// Neovim 拿到端口后应在这段时间内连上来；超时则关掉 listener，避免线程泄漏
const ACCEPT_TIMEOUT: Duration = Duration::from_secs(60);

/// 校验交给系统 ssh 的 user / host，防止参数注入（如 host = "-oProxyCommand=..."）。
fn validate_ssh_target(user: &str, host: &str) -> Result<(), anyhow::Error> {
    fn bad(s: &str) -> bool {
        s.starts_with('-') || s.chars().any(|c| c.is_whitespace() || c.is_control())
    }
    if host.is_empty() || bad(host) || host.contains('@') {
        return Err(anyhow::anyhow!("Invalid SSH host: {:?}", host));
    }
    if bad(user) || user.contains('@') {
        return Err(anyhow::anyhow!("Invalid SSH user: {:?}", user));
    }
    Ok(())
}

/// ControlMaster socket 目录：放在用户私有目录（0700），而不是全局可写的 /tmp。
/// 优先 $XDG_RUNTIME_DIR/zero-nvim，否则 ~/.cache/zero-nvim/ssh。
/// 返回 None 表示目录不可用或路径过长（unix socket 路径上限 ~104 字节），此时
/// 不启用连接复用。
fn control_dir() -> Option<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    let dir = match std::env::var_os("XDG_RUNTIME_DIR").filter(|v| !v.is_empty()) {
        Some(rt) => PathBuf::from(rt).join("zero-nvim"),
        None => dirs::home_dir()?.join(".cache").join("zero-nvim").join("ssh"),
    };
    // "cm-" + %C（40 位十六进制）+ ssh 临时后缀（约 17 字节）
    if dir.as_os_str().len() + 1 + 3 + 40 + 17 > 104 {
        return None;
    }
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&dir)
        .ok()?;
    // 目录若早已存在（权限更宽），收紧到 0700
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).ok()?;
    Some(dir)
}

/// 系统 ssh 的公共参数（不含目的地和远端命令）
fn base_ssh_args(port: u16) -> Vec<String> {
    let mut args: Vec<String> = vec![
        "-o".into(),
        // 首次连接自动接受 host key，但 key 变化时拒绝（防中间人）
        "StrictHostKeyChecking=accept-new".into(),
        "-o".into(),
        "BatchMode=yes".into(), // non-interactive (uses Agent)
        "-o".into(),
        // 压掉 "Permanently added ... to known hosts" 之类的提示（否则会显示成 WARN）
        "LogLevel=ERROR".into(),
    ];
    // ControlMaster=auto + ControlPersist multiplexes LSP launches over a
    // single SSH connection. The first LSP pays the full TCP+key+auth cost;
    // subsequent ones (or restart-after-stop) attach in milliseconds.
    // %C hashes (local_user, host, port, remote_user) → unique per target.
    if let Some(dir) = control_dir() {
        args.push("-o".into());
        args.push("ControlMaster=auto".into());
        args.push("-o".into());
        args.push(format!("ControlPath={}/cm-%C", dir.display()));
        args.push("-o".into());
        args.push("ControlPersist=10m".into());
    }
    args.push("-p".into());
    args.push(port.to_string());
    args
}

/// 完整的 ssh 参数：公共参数 + `--` + user@host + 远端命令
fn ssh_command_args(
    user: &str,
    host: &str,
    port: u16,
    extra_opts: &[&str],
    remote_cmd: &str,
) -> Result<Vec<String>, anyhow::Error> {
    validate_ssh_target(user, host)?;
    let mut args = base_ssh_args(port);
    args.extend(extra_opts.iter().map(|s| s.to_string()));
    let dest = if user.is_empty() {
        host.to_string()
    } else {
        format!("{}@{}", user, host)
    };
    // `--` 之后的参数不会再被当作选项解析
    args.push("--".into());
    args.push(dest);
    args.push(remote_cmd.to_string());
    Ok(args)
}

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
        let state_lock = state.lock_ok();
        if !state_lock.sessions.contains_key(&key) {
            return Err(anyhow::anyhow!("NOT_CONNECTED: {}", key));
        }
    }

    let file_prefix = "file://".to_string();
    let client_prefix_s = client_prefix.trim_end_matches('/').to_string();

    let login_cmd = build_lsp_login_command(&cmd_argv)?;
    let ssh_args = ssh_command_args(
        user,
        host,
        port,
        // SSH-layer keepalive：每 30s 发一个心跳；连续 3 次（90s）无应答
        // 才判死。两个作用：(1) 让 NAT/防火墙的 idle flow timeout 永远归
        // 零，避免 idle-disconnect；(2) 真正掉线时 90s 内 ssh 子进程退出，
        // 触发 Lua 端的 on_exit 自动重启路径。否则一直 idle 又没人发包，
        // 进程会僵在 read() 上几十分钟，直到 TCP RST 才感知。
        &[
            "-o",
            "ServerAliveInterval=30",
            "-o",
            "ServerAliveCountMax=3",
        ],
        &login_cmd,
    )?;
    let cmd_display = cmd_argv.join(" ");

    // Bind a random ephemeral port locally
    let listener = TcpListener::bind("127.0.0.1:0").context("Failed to bind random TCP port")?;
    let local_port = listener.local_addr()?.port();
    listener
        .set_nonblocking(true)
        .context("Failed to set listener non-blocking")?;

    debug_log!(
        "Daemon: LSP proxy :{} → {}@{}:{} ({})",
        local_port,
        user,
        host,
        port,
        cmd_display
    );

    thread::spawn(move || {
        let tcp_stream = match accept_with_timeout(&listener, ACCEPT_TIMEOUT) {
            Some(s) => s,
            None => {
                eprintln!(
                    "Daemon: LSP proxy :{} 在 {:?} 内无客户端连接，已关闭",
                    local_port, ACCEPT_TIMEOUT
                );
                return;
            }
        };
        drop(listener);
        if let Err(e) = run_lsp_proxy(tcp_stream, &ssh_args, client_prefix_s, file_prefix) {
            eprintln!("Daemon: LSP proxy :{} 失败: {:#}", local_port, e);
        }
    });

    Ok(Value::Integer(local_port.into()))
}

/// 非阻塞 accept 轮询，带超时。返回的 stream 已切回 blocking。
fn accept_with_timeout(listener: &TcpListener, timeout: Duration) -> Option<TcpStream> {
    let deadline = Instant::now() + timeout;
    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                stream.set_nonblocking(false).ok()?;
                return Some(stream);
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                if Instant::now() >= deadline {
                    return None;
                }
                thread::sleep(Duration::from_millis(50));
            }
            Err(e) => {
                eprintln!("Daemon: LSP proxy accept 失败: {}", e);
                return None;
            }
        }
    }
}

/// 起 ssh 子进程并在 TCP ↔ ssh stdio 之间双向转发。
///
/// 生命周期：任一方向结束都对 TCP 做 shutdown(Both)——另一线程持有的 clone fd
/// 不会阻止对端看到 EOF；并确保 ssh 子进程被回收（宽限后 kill），不会无限挂在
/// child.wait() 上。
fn run_lsp_proxy(
    tcp_stream: TcpStream,
    ssh_args: &[String],
    client_prefix: String,
    file_prefix: String,
) -> Result<(), anyhow::Error> {
    // Spawn ssh as a child process. It reuses ~/.ssh/config + SSH Agent.
    // Prepend mason/bin to PATH so tools installed via Mason are found
    // without needing a login shell or modifying ~/.profile.
    let mut child = Command::new("ssh")
        .args(ssh_args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped()) // Pipe stderr to prevent blocking if parent doesn't read fast enough
        .spawn()
        .context("Failed to spawn ssh for LSP")?;

    let child_stdin = child.stdin.take().context("child stdin")?;
    let child_stdout = child.stdout.take().context("child stdout")?;
    let child_stderr = child.stderr.take().context("child stderr")?;
    let child = Arc::new(Mutex::new(child));

    // Thread 0: Consume SSH stderr to prevent blocking
    // We also log it to daemon stderr so Neovim can see it
    thread::spawn(move || {
        use std::io::{BufRead, BufReader};
        let reader = BufReader::new(child_stderr);
        for l in reader.lines().map_while(Result::ok) {
            eprintln!("[SSH-ERR] {}", l);
        }
    });

    let tcp_writer = tcp_stream.try_clone().context("Failed to clone TCP stream")?;
    let tcp_ctl_a = tcp_stream.try_clone().context("Failed to clone TCP stream")?;
    let tcp_ctl_b = tcp_stream.try_clone().context("Failed to clone TCP stream")?;

    // Thread 1: TCP (Neovim) → SSH stdin
    // Translate: zero://user@host:port/ → file:///
    let from1 = client_prefix.clone();
    let to1 = file_prefix.clone();
    let child_a = child.clone();
    thread::spawn(move || {
        let mut r = tcp_stream;
        let mut w = child_stdin;
        let _ = pump_and_translate(&mut r, &mut w, &from1, &to1, "TCP->SSH");
        // Neovim 断开：关 ssh stdin（远端 LSP 读到 EOF），关 TCP，宽限后杀 ssh
        drop(w);
        let _ = tcp_ctl_a.shutdown(Shutdown::Both);
        reap_child(&child_a, Duration::from_secs(2));
    });

    // Thread 2 (当前线程): SSH stdout → TCP (Neovim)
    // Translate: file:/// → zero://user@host:port/
    let mut r = child_stdout;
    let mut w = tcp_writer;
    let _ = pump_and_translate(&mut r, &mut w, &file_prefix, &client_prefix, "SSH->TCP");
    // 远端 LSP / ssh 退出：shutdown 让 Neovim 立刻看到 EOF，并让 Thread 1 的 read 返回
    let _ = tcp_ctl_b.shutdown(Shutdown::Both);
    if let Some(status) = reap_child(&child, Duration::from_secs(5)) {
        if !status.success() {
            eprintln!("Daemon: LSP process exited abnormally: {:?}", status);
        }
    }
    Ok(())
}

/// 等子进程退出，最多 grace；超时则 kill。返回退出状态（若此次回收到）。
/// 用 try_wait 轮询而不是 wait()，避免持锁阻塞导致另一线程无法 kill。
fn reap_child(child: &Mutex<Child>, grace: Duration) -> Option<std::process::ExitStatus> {
    let deadline = Instant::now() + grace;
    loop {
        {
            let mut c = child.lock_ok();
            match c.try_wait() {
                Ok(Some(status)) => return Some(status),
                Ok(None) if Instant::now() >= deadline => {
                    let _ = c.kill();
                    return c.wait().ok();
                }
                Ok(None) => {}
                Err(_) => return None,
            }
        }
        thread::sleep(Duration::from_millis(50));
    }
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
        let state_lock = state.lock_ok();
        if !state_lock.sessions.contains_key(&key) {
            return Err(anyhow::anyhow!("NOT_CONNECTED: {}", key));
        }
    }

    let probe_cmd = build_lsp_probe_command(&cmd_argv)?;
    let ssh_args = ssh_command_args(user, host, port, &["-o", "ConnectTimeout=5"], &probe_cmd)?;
    let output = Command::new("ssh").args(&ssh_args).output();

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
            if let Some((name, val)) = line.split_once(':') {
                if name.trim().eq_ignore_ascii_case("content-length") {
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
        // tcp->ssh: "zero://user@host:port/path" → "file:///path"
        // ssh->tcp: "file:///path"               → "zero://user@host:port/path"
        let new_body = match String::from_utf8(body) {
            Ok(s) => rewrite_uri_prefix(&s, from, to).into_bytes(),
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

/// 把 JSON 字符串值开头的 `from/` 换成 `to/`。
///
/// 只匹配 `"` + from + `/`：
///   - 要求前缀后紧跟 `/`，`zero://u@h:22` 不会误伤 `zero://u@h:2222/...`；
///   - 要求前面紧跟 `"`，即 URI 是整个 JSON 字符串值的开头，hover / 诊断文本
///     中间出现的 file:// 不会被改写。
///
/// from / to 均不带结尾 `/`（如 "zero://u@h:22"、"file://"）。
fn rewrite_uri_prefix(body: &str, from: &str, to: &str) -> String {
    let pat = format!("\"{}/", from);
    if !body.contains(&pat) {
        return body.to_string();
    }
    body.replace(&pat, &format!("\"{}/", to))
}

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
    fn uri_rewrite_tcp_to_ssh() {
        let body = r#"{"uri":"zero://u@h:22/src/main.rs","rootUri":"zero://u@h:22/"}"#;
        assert_eq!(
            rewrite_uri_prefix(body, "zero://u@h:22", "file://"),
            r#"{"uri":"file:///src/main.rs","rootUri":"file:///"}"#
        );
    }

    #[test]
    fn uri_rewrite_does_not_match_longer_port() {
        let body = r#"{"uri":"zero://u@h:2222/x"}"#;
        assert_eq!(rewrite_uri_prefix(body, "zero://u@h:22", "file://"), body);
    }

    #[test]
    fn uri_rewrite_ssh_to_tcp_only_uri_values() {
        let body = r#"{"uri":"file:///a/b.rs","contents":"see file:///a/b.rs for details"}"#;
        assert_eq!(
            rewrite_uri_prefix(body, "file://", "zero://u@h:22"),
            r#"{"uri":"zero://u@h:22/a/b.rs","contents":"see file:///a/b.rs for details"}"#
        );
    }

    #[test]
    fn ssh_target_validation_blocks_option_injection() {
        assert!(validate_ssh_target("root", "example.com").is_ok());
        assert!(validate_ssh_target("", "example.com").is_ok());
        assert!(validate_ssh_target("root", "-oProxyCommand=touch /tmp/x").is_err());
        assert!(validate_ssh_target("-oProxyCommand=x", "h").is_err());
        assert!(validate_ssh_target("root", "h st").is_err());
        assert!(validate_ssh_target("root", "").is_err());
    }

    #[test]
    fn ssh_args_put_double_dash_before_destination() {
        let args = ssh_command_args("u", "h", 2200, &[], "cmd").unwrap();
        let n = args.len();
        assert_eq!(&args[n - 3..], &["--", "u@h", "cmd"]);
        assert!(args.contains(&"StrictHostKeyChecking=accept-new".to_string()));
        assert!(!args.iter().any(|a| a.contains("StrictHostKeyChecking=no")));
        assert!(!args.iter().any(|a| a.contains("ControlPath=/tmp/")));
    }

    #[test]
    fn lsp_probe_command_rejects_empty_argv() {
        let err = build_lsp_probe_command(&[]).expect_err("empty argv must fail");
        assert!(err.to_string().contains("empty"));
    }
}
