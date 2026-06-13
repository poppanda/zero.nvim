// =============================================================================
// cmd/spec.rs — 远程命令 / 连接目标 描述
// =============================================================================

use std::time::Duration;

/// 远程连接目标三元组
#[derive(Debug, Clone)]
pub struct ConnTarget {
    pub user: String,
    pub host: String,
    pub port: u16,
}

impl ConnTarget {
    pub fn new(user: impl Into<String>, host: impl Into<String>, port: u16) -> Self {
        Self {
            user: user.into(),
            host: host.into(),
            port,
        }
    }

    /// 与 DaemonState::connection_key 同样格式
    pub fn key(&self) -> String {
        format!("{}@{}:{}", self.user, self.host, self.port)
    }
}

/// 远程命令规约
///
/// argv[0] 是命令名（远端 PATH 查找），argv[1..] 是参数。**不要把整条 shell 命令
/// 拼成一个字符串塞 argv[0]**——除非确实需要 sh -c 的功能（环境变量展开、管道）。
/// 远端实际跑的是 `sh -c 'echo $$ >&2; exec "$@"' -- argv[0] argv[1] ...`，
/// 头一行 stderr 抓出 PID 用于 cancel 时 kill。
#[derive(Debug, Clone)]
pub struct RemoteCommand {
    pub argv: Vec<String>,
    pub env: Vec<(String, String)>,
    pub cwd: Option<String>,
    pub stdin: Option<Vec<u8>>,
    pub timeout: Option<Duration>,
    pub pty: bool,
}

impl RemoteCommand {
    pub fn new<I, S>(argv: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self {
            argv: argv.into_iter().map(|s| s.into()).collect(),
            env: Vec::new(),
            cwd: None,
            stdin: None,
            timeout: None,
            pty: false,
        }
    }

    #[cfg(test)]
    pub fn env(mut self, k: impl Into<String>, v: impl Into<String>) -> Self {
        self.env.push((k.into(), v.into()));
        self
    }

    #[cfg(test)]
    pub fn cwd(mut self, cwd: impl Into<String>) -> Self {
        self.cwd = Some(cwd.into());
        self
    }

    pub fn timeout_ms(mut self, ms: u64) -> Self {
        self.timeout = Some(Duration::from_millis(ms));
        self
    }

    /// 把 argv + env + cwd 拼成发到远端的 shell 命令字符串。
    ///
    /// 最终远端实际 exec 的形式：
    ///
    /// ```sh
    /// cd '<cwd>' && export 'KEY'='VAL' ... && (echo "ZERO_PID:$$" >&2; exec '<argv0>' '<argv1>' ...)
    /// ```
    ///
    /// `wrap_for_pid=true` 时插入 `echo "ZERO_PID:$$"` 行，给 cancel 提取远端 PID 用；
    /// `false` 时为纯净执行（不污染 stderr）。
    pub fn to_shell_command(&self, wrap_for_pid: bool) -> String {
        let mut prefix = String::new();
        if let Some(cwd) = &self.cwd {
            prefix.push_str(&format!("cd {} && ", shell_quote(cwd)));
        }
        for (k, v) in &self.env {
            prefix.push_str(&format!("export {}={} && ", shell_quote(k), shell_quote(v)));
        }

        let argv_quoted: Vec<String> = self.argv.iter().map(|s| shell_quote(s)).collect();
        let argv_joined = argv_quoted.join(" ");

        if wrap_for_pid {
            format!(
                "{}sh -c 'echo \"ZERO_PID:$$\" >&2; exec \"$@\"' -- {}",
                prefix, argv_joined
            )
        } else {
            format!("{}{}", prefix, argv_joined)
        }
    }
}

/// 单引号包裹，内部 ' 转成 '\''
pub fn shell_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for ch in s.chars() {
        if ch == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_quote_basic() {
        assert_eq!(shell_quote("hello"), "'hello'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
        assert_eq!(shell_quote("a b"), "'a b'");
    }

    #[test]
    fn cmd_basic() {
        let c = RemoteCommand::new(vec!["echo", "hi"]);
        let s = c.to_shell_command(false);
        assert_eq!(s, "'echo' 'hi'");
    }

    #[test]
    fn cmd_with_pid_wrap() {
        let c = RemoteCommand::new(vec!["sleep", "5"]);
        let s = c.to_shell_command(true);
        assert!(s.contains("ZERO_PID:$$"));
        assert!(s.contains("'sleep' '5'"));
    }

    #[test]
    fn cmd_with_env_cwd() {
        let c = RemoteCommand::new(vec!["pwd"])
            .cwd("/tmp")
            .env("FOO", "bar");
        let s = c.to_shell_command(false);
        assert!(s.starts_with("cd '/tmp' && export 'FOO'='bar' && "));
    }
}
