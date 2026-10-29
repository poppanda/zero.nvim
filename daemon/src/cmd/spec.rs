// =============================================================================
// cmd/spec.rs — 远程命令描述
// =============================================================================

use crate::session::shell_quote;
use rmpv::Value;
use std::time::Duration;

/// 远程命令规约（来自 RPC 的 spec map）
///
///   argv:       string[]               (必填)
///   env:        [[k,v], [k,v], ...]    (可选)
///   cwd:        string                 (可选)
///   stdin:      bytes/string           (可选，一次性写入后 send_eof)
///   timeout_ms: integer                (可选，仅 cmd_sync)
///   pty:        bool                   (可选，仅 cmd_stream)
///
/// argv[0] 是命令名（远端 PATH 查找），argv[1..] 是参数。**不要把整条 shell 命令
/// 拼成一个字符串塞 argv[0]**——除非确实需要 sh -c 的功能（环境变量展开、管道）。
#[derive(Debug, Clone, Default)]
pub struct RemoteCommand {
    pub argv: Vec<String>,
    pub env: Vec<(String, String)>,
    pub cwd: Option<String>,
    pub stdin: Option<Vec<u8>>,
    pub timeout: Option<Duration>,
    pub pty: bool,
}

impl RemoteCommand {
    pub fn from_value(spec: &Value) -> anyhow::Result<Self> {
        let map = spec.as_map().ok_or(anyhow::anyhow!("spec must be a map"))?;
        let mut cmd = Self::default();
        for (k, v) in map {
            match k.as_str().unwrap_or("") {
                "argv" => {
                    for item in v.as_array().ok_or(anyhow::anyhow!("argv must be array"))? {
                        let s = item
                            .as_str()
                            .ok_or(anyhow::anyhow!("argv item must be string"))?;
                        cmd.argv.push(s.to_string());
                    }
                }
                // 格式不对的 env 项静默忽略
                "env" => {
                    for pair in v.as_array().into_iter().flatten() {
                        if let Some([k, val]) = pair.as_array().map(Vec::as_slice) {
                            if let (Some(k), Some(val)) = (k.as_str(), val.as_str()) {
                                cmd.env.push((k.to_string(), val.to_string()));
                            }
                        }
                    }
                }
                "cwd" => cmd.cwd = v.as_str().map(str::to_string),
                "stdin" => {
                    cmd.stdin = match v {
                        Value::String(s) => Some(s.as_bytes().to_vec()),
                        Value::Binary(b) => Some(b.clone()),
                        _ => None,
                    }
                }
                "timeout_ms" => cmd.timeout = v.as_u64().map(Duration::from_millis),
                "pty" => cmd.pty = v.as_bool().unwrap_or(false),
                _ => {}
            }
        }
        if cmd.argv.is_empty() {
            return Err(anyhow::anyhow!("spec.argv is empty"));
        }
        Ok(cmd)
    }

    /// 把 argv + env + cwd 拼成发到远端的 shell 命令字符串：
    ///
    /// ```sh
    /// cd '<cwd>' && export 'KEY'='VAL' && sh -c 'echo "ZERO_PID:$$" >&2; exec "$@"' -- '<argv0>' ...
    /// ```
    ///
    /// `wrap_for_pid=true` 时经 `sh -c` 先把 PID 打到 stderr 头一行，给 cancel 用；
    /// `false` 时为纯净执行（不污染 stderr）。
    pub fn to_shell_command(&self, wrap_for_pid: bool) -> String {
        let mut s = String::new();
        if let Some(cwd) = &self.cwd {
            s.push_str(&format!("cd {} && ", shell_quote(cwd)));
        }
        for (k, v) in &self.env {
            s.push_str(&format!("export {}={} && ", shell_quote(k), shell_quote(v)));
        }
        if wrap_for_pid {
            s.push_str("sh -c 'echo \"ZERO_PID:$$\" >&2; exec \"$@\"' -- ");
        }
        let argv: Vec<String> = self.argv.iter().map(|a| shell_quote(a)).collect();
        s.push_str(&argv.join(" "));
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(pairs: Vec<(&str, Value)>) -> Value {
        Value::Map(
            pairs
                .into_iter()
                .map(|(k, v)| (Value::from(k), v))
                .collect(),
        )
    }

    fn argv(items: &[&str]) -> Value {
        Value::Array(items.iter().map(|s| Value::from(*s)).collect())
    }

    #[test]
    fn cmd_basic() {
        let c = RemoteCommand::from_value(&spec(vec![("argv", argv(&["echo", "hi"]))])).unwrap();
        assert_eq!(c.to_shell_command(false), "'echo' 'hi'");
    }

    #[test]
    fn cmd_with_pid_wrap() {
        let c = RemoteCommand::from_value(&spec(vec![("argv", argv(&["sleep", "5"]))])).unwrap();
        let s = c.to_shell_command(true);
        assert!(s.contains("ZERO_PID:$$"));
        assert!(s.ends_with("-- 'sleep' '5'"));
    }

    #[test]
    fn cmd_with_env_cwd_stdin_timeout() {
        let c = RemoteCommand::from_value(&spec(vec![
            ("argv", argv(&["pwd"])),
            ("cwd", Value::from("/tmp")),
            (
                "env",
                Value::Array(vec![argv(&["FOO", "bar"]), argv(&["bad"])]),
            ),
            ("stdin", Value::Binary(vec![0xff])),
            ("timeout_ms", Value::from(1500)),
        ]))
        .unwrap();
        assert!(c
            .to_shell_command(false)
            .starts_with("cd '/tmp' && export 'FOO'='bar' && "));
        assert_eq!(c.stdin.as_deref(), Some(&[0xff][..]));
        assert_eq!(c.timeout, Some(Duration::from_millis(1500)));
    }

    #[test]
    fn spec_requires_argv() {
        assert!(RemoteCommand::from_value(&spec(vec![])).is_err());
        assert!(RemoteCommand::from_value(&Value::from("x")).is_err());
    }
}
