// =============================================================================
// fs.rs — 远程文件系统操作
// =============================================================================
// 包含所有 SFTP 相关的 RPC 方法:
//   - fetch_file:    读取远程文件
//   - write_file:    写入远程文件
//   - read_dir:      读取目录（带缓存）
//   - stat:          查询路径类型
//   - scan_project:  递归预扫描目录树
//
// 所有 handler 通过 DaemonState::with_conn 走，自动应对会话断开后的重连。

use crate::cmd::spec::shell_quote;
use crate::state::{DaemonState, DirEntry};
use rmpv::Value;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

// =============================================================================
// fetch_path — 合并 stat 和 fetch，通过 Exec 通道直接获取，显著降低延迟
// =============================================================================

/// 远程文件读取上限（10 MiB）。超过该大小的文件直接拒绝，避免 RPC 通道被一次
/// 性塞入海量数据导致 Neovim UI 长时间卡死。需要查看大文件请走 ripgrep / less。
const MAX_FETCH_SIZE: u64 = 10 * 1024 * 1024;

pub fn handle_fetch_path(
    user: &str,
    host: &str,
    port: u16,
    path: &str,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    DaemonState::with_conn(state, user, host, port, |conn| {
        let mut channel = conn
            .session
            .channel_session()
            .map_err(|e| anyhow::anyhow!("无法开启 SSH 通道: {}", e))?;

        let escaped_path = format!("'{}'", path.replace('\'', "'\\''"));
        // 远端先 stat 大小：超出阈值直接返回 TOOBIG，不执行 cat，避免无谓传输。
        let script = format!(
            "if [ -d {0} ]; then printf 'DIR'; elif [ -f {0} ]; then size=$(wc -c < {0} 2>/dev/null | tr -d ' '); if [ \"${{size:-0}}\" -gt {1} ]; then printf 'TOOBIG:%s' \"$size\"; else printf 'FILE'; cat {0}; fi; else printf 'MISSING'; fi",
            escaped_path, MAX_FETCH_SIZE
        );

        channel
            .exec(&script)
            .map_err(|e| anyhow::anyhow!("远程执行失败: {}", e))?;

        let mut out = Vec::new();
        channel
            .read_to_end(&mut out)
            .map_err(|e| anyhow::anyhow!("读取数据失败: {}", e))?;

        let mut err = String::new();
        channel.stderr().read_to_string(&mut err).ok();
        channel.wait_close().ok();

        if out.starts_with(b"DIR") {
            Ok(Value::Array(vec![
                Value::String("directory".into()),
                Value::Nil,
            ]))
        } else if out.starts_with(b"FILE") {
            let content_bytes = &out[4..];
            // 严格 UTF-8 校验：lossy 转换会把无效字节静默替换成 U+FFFD，写回时
            // 数据被永久破坏。遇到二进制文件直接拒绝，让用户走专用工具。
            let content_str = std::str::from_utf8(content_bytes).map_err(|_| {
                anyhow::anyhow!(
                    "文件含非 UTF-8 内容（可能是二进制文件），无法在 Neovim 中编辑: {}",
                    path
                )
            })?;
            Ok(Value::Array(vec![
                Value::String("file".into()),
                Value::String(content_str.into()),
            ]))
        } else if out.starts_with(b"TOOBIG:") {
            let size_str = String::from_utf8_lossy(&out[b"TOOBIG:".len()..])
                .trim()
                .to_string();
            Err(anyhow::anyhow!(
                "文件过大无法打开 ({} 字节，上限 {} 字节): {}",
                size_str,
                MAX_FETCH_SIZE,
                path
            ))
        } else if out.starts_with(b"MISSING") {
            Err(anyhow::anyhow!("路径不存在: {}", path))
        } else {
            let out_str = String::from_utf8_lossy(&out);
            Err(anyhow::anyhow!("未知结果: {} | stderr: {}", out_str, err))
        }
    })
}

// =============================================================================
// fetch_paths — 批量获取多个文件内容，极大地降低 LSP 跳转等场景的网络 RTT 延迟
// =============================================================================

pub fn handle_fetch_paths(
    user: &str,
    host: &str,
    port: u16,
    paths: Vec<String>,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    if paths.is_empty() {
        return Ok(Value::Map(vec![]));
    }

    DaemonState::with_conn(state, user, host, port, |conn| {
        let mut channel = conn
            .session
            .channel_session()
            .map_err(|e| anyhow::anyhow!("无法开启 SSH 通道: {}", e))?;

        let script = build_fetch_paths_script(&paths);

        channel
            .exec(&script)
            .map_err(|e| anyhow::anyhow!("批量远程执行失败: {}", e))?;

        let mut out = Vec::new();
        channel
            .read_to_end(&mut out)
            .map_err(|e| anyhow::anyhow!("读取数据失败: {}", e))?;
        channel.wait_close().ok();

        let records = parse_fetch_paths_payload(&out)?;
        let mut result_map = Vec::new();
        for record in records {
            match record {
                FetchPathRecord::File { path, content } => {
                    result_map.push((Value::String(path.into()), Value::String(content.into())));
                }
                FetchPathRecord::Missing { .. } => {}
                FetchPathRecord::TooBig { path, size } => {
                    return Err(anyhow::anyhow!(
                        "文件过大无法打开 ({} 字节，上限 {} 字节): {}",
                        size,
                        MAX_FETCH_SIZE,
                        path
                    ));
                }
            }
        }

        Ok(Value::Map(result_map))
    })
}

fn build_fetch_paths_script(paths: &[String]) -> String {
    let mut script = String::new();
    for path in paths {
        let path_q = shell_quote(path);
        script.push_str(&format!(
            "printf 'ZP\\n{}\\n'; \
             if [ -f {path_q} ]; then \
               size=$(wc -c < {path_q} 2>/dev/null | tr -d ' '); \
               if [ \"${{size:-0}}\" -gt {max} ]; then \
                 printf 'TOOBIG\\n%s\\n' \"$size\"; \
                 printf %s {path_q}; \
               else \
                 printf 'OK\\n%s\\n' \"$size\"; \
                 printf %s {path_q}; \
                 cat {path_q}; \
               fi; \
             else \
               printf 'MISSING\\n0\\n'; \
               printf %s {path_q}; \
             fi; ",
            path.as_bytes().len(),
            path_q = path_q,
            max = MAX_FETCH_SIZE
        ));
    }
    script
}

#[derive(Debug, PartialEq, Eq)]
enum FetchPathRecord {
    File { path: String, content: String },
    Missing { path: String },
    TooBig { path: String, size: u64 },
}

fn parse_fetch_paths_payload(out: &[u8]) -> Result<Vec<FetchPathRecord>, anyhow::Error> {
    let mut pos = 0;
    let mut records = Vec::new();
    while pos < out.len() {
        let magic = read_payload_line(out, &mut pos)?;
        if magic != b"ZP" {
            return Err(anyhow::anyhow!(
                "批量读取协议错误: expected ZP marker, got {:?}",
                String::from_utf8_lossy(magic)
            ));
        }

        let path_len = parse_usize_line(read_payload_line(out, &mut pos)?, "path length")?;
        let status = std::str::from_utf8(read_payload_line(out, &mut pos)?)
            .map_err(|_| anyhow::anyhow!("批量读取协议错误: status 非 UTF-8"))?;
        let data_len = parse_usize_line(read_payload_line(out, &mut pos)?, "data length")?;

        if pos + path_len > out.len() {
            return Err(anyhow::anyhow!(
                "批量读取协议错误: path length out of bounds"
            ));
        }
        let path = std::str::from_utf8(&out[pos..pos + path_len])
            .map_err(|_| anyhow::anyhow!("批量读取协议错误: path 非 UTF-8"))?
            .to_string();
        pos += path_len;

        match status {
            "OK" => {
                if pos + data_len > out.len() {
                    return Err(anyhow::anyhow!(
                        "批量读取协议错误: content length out of bounds for {}",
                        path
                    ));
                }
                let content = std::str::from_utf8(&out[pos..pos + data_len])
                    .map_err(|_| {
                        anyhow::anyhow!(
                            "文件含非 UTF-8 内容（可能是二进制文件），无法在 Neovim 中编辑: {}",
                            path
                        )
                    })?
                    .to_string();
                pos += data_len;
                records.push(FetchPathRecord::File { path, content });
            }
            "MISSING" => records.push(FetchPathRecord::Missing { path }),
            "TOOBIG" => records.push(FetchPathRecord::TooBig {
                path,
                size: data_len as u64,
            }),
            other => {
                return Err(anyhow::anyhow!(
                    "批量读取协议错误: unknown status {}",
                    other
                ));
            }
        }
    }
    Ok(records)
}

fn read_payload_line<'a>(out: &'a [u8], pos: &mut usize) -> Result<&'a [u8], anyhow::Error> {
    let start = *pos;
    let rel_end = out[start..]
        .iter()
        .position(|b| *b == b'\n')
        .ok_or(anyhow::anyhow!("批量读取协议错误: missing newline"))?;
    let end = start + rel_end;
    *pos = end + 1;
    Ok(&out[start..end])
}

fn parse_usize_line(line: &[u8], label: &str) -> Result<usize, anyhow::Error> {
    let s = std::str::from_utf8(line)
        .map_err(|_| anyhow::anyhow!("批量读取协议错误: {} 非 UTF-8", label))?;
    s.parse::<usize>()
        .map_err(|_| anyhow::anyhow!("批量读取协议错误: invalid {}", label))
}

// =============================================================================
// fetch_file — SFTP 读取远程文件 (保留做备用或特定场景)
// =============================================================================

pub fn handle_fetch_file(
    user: &str,
    host: &str,
    port: u16,
    path: &str,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    DaemonState::with_conn(state, user, host, port, |conn| {
        let sftp = conn
            .sftp()
            .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;
        let mut remote_file = sftp
            .open(Path::new(path))
            .map_err(|e| anyhow::anyhow!("无法打开远程文件 {}: {}", path, e))?;
        let mut content = String::new();
        remote_file
            .read_to_string(&mut content)
            .map_err(|e| anyhow::anyhow!("读取失败 {}: {}", path, e))?;

        Ok(Value::String(content.into()))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(path: &str, status: &str, len: usize, content: &[u8]) -> Vec<u8> {
        let mut out = format!("ZP\n{}\n{}\n{}\n", path.as_bytes().len(), status, len).into_bytes();
        out.extend_from_slice(path.as_bytes());
        out.extend_from_slice(content);
        out
    }

    #[test]
    fn parse_fetch_paths_payload_preserves_marker_like_content() {
        let content = b"hello <<<Z_END>>> still content\n";
        let payload = record("/tmp/a.py", "OK", content.len(), content);

        let records = parse_fetch_paths_payload(&payload).expect("payload parses");

        assert_eq!(records.len(), 1);
        match &records[0] {
            FetchPathRecord::File { path, content } => {
                assert_eq!(path, "/tmp/a.py");
                assert_eq!(content, "hello <<<Z_END>>> still content\n");
            }
            other => panic!("unexpected record: {:?}", other),
        }
    }

    #[test]
    fn parse_fetch_paths_payload_rejects_non_utf8_content() {
        let payload = record("/tmp/bin", "OK", 2, &[0xff, 0xfe]);

        let err = parse_fetch_paths_payload(&payload).expect_err("binary content must fail");

        assert!(err.to_string().contains("非 UTF-8"));
    }
}

// =============================================================================
// write_file — SFTP 写入远程文件
// =============================================================================

pub fn handle_write_file(
    user: &str,
    host: &str,
    port: u16,
    path: &str,
    content: &str,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    DaemonState::with_conn(state, user, host, port, |conn| {
        let sftp = conn
            .sftp()
            .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;

        let mut remote_file = sftp
            .create(Path::new(path))
            .map_err(|e| anyhow::anyhow!("无法创建远程文件 {}: {}", path, e))?;
        remote_file
            .write_all(content.as_bytes())
            .map_err(|e| anyhow::anyhow!("写入失败 {}: {}", path, e))?;

        Ok(())
    })?;

    eprintln!("Daemon: 文件已写入 {} ({} bytes)", path, content.len());

    let key = DaemonState::connection_key(user, host, port);
    invalidate_parent_cache(state, &key, Path::new(path));

    Ok(Value::Boolean(true))
}

fn invalidate_parent_cache(state: &Arc<Mutex<DaemonState>>, key: &str, path: &Path) {
    if let Some(parent) = path.parent() {
        let mut state_lock = state.lock().unwrap();
        if let Some(cache) = state_lock.caches.get_mut(key) {
            cache.directories.remove(&parent.to_path_buf());
        }
    }
}

// =============================================================================
// read_dir — SFTP 读目录（带缓存）
// =============================================================================

pub fn handle_read_dir(
    user: &str,
    host: &str,
    port: u16,
    path: &str,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    let key = DaemonState::connection_key(user, host, port);
    let path_buf = PathBuf::from(path);

    // 先检查缓存，命中则直接返回
    {
        let state_lock = state.lock().unwrap();
        if let Some(cache) = state_lock.caches.get(&key) {
            if let Some(entries) = cache.directories.get(&path_buf) {
                return Ok(entries_to_msgpack(entries));
            }
        }
    }

    let dir_entries = DaemonState::with_conn(state, user, host, port, |conn| {
        let sftp = conn
            .sftp()
            .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;
        let sftp_entries = sftp
            .readdir(Path::new(path))
            .map_err(|e| anyhow::anyhow!("读目录失败 {}: {}", path, e))?;

        let mut entries = Vec::new();
        for (p, stat) in sftp_entries {
            let name = p
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string();
            if name == "." || name == ".." {
                continue;
            }
            let file_type = if stat.is_dir() { "directory" } else { "file" };
            entries.push(DirEntry {
                name,
                file_type: file_type.to_string(),
            });
        }
        Ok(entries)
    })?;

    let result = entries_to_msgpack(&dir_entries);

    let mut state_lock = state.lock().unwrap();
    if let Some(cache) = state_lock.caches.get_mut(&key) {
        cache.directories.insert(path_buf, dir_entries);
    }

    Ok(result)
}

// =============================================================================
// stat — 查询远程路径类型 (file / directory)
// =============================================================================

pub fn handle_stat(
    user: &str,
    host: &str,
    port: u16,
    path: &str,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    DaemonState::with_conn(state, user, host, port, |conn| {
        let sftp = conn
            .sftp()
            .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;
        let stat = sftp
            .stat(Path::new(path))
            .map_err(|e| anyhow::anyhow!("stat 失败 {}: {}", path, e))?;
        let file_type = if stat.is_dir() { "directory" } else { "file" };
        Ok(Value::String(file_type.into()))
    })
}

// =============================================================================
// scan_project — 递归预扫描目录树并填充缓存
// =============================================================================
// 使用栈实现广度优先扫描，限制最大递归深度为 3 层，
// 跳过隐藏目录（.git, .cache 等）防止不必要的扫描。

pub fn handle_scan_project(
    user: &str,
    host: &str,
    port: u16,
    root_path: &str,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    let key = DaemonState::connection_key(user, host, port);
    let max_depth = 3;
    let root_path = root_path.to_string();

    let scanned: HashMap<PathBuf, Vec<DirEntry>> =
        DaemonState::with_conn(state, user, host, port, |conn| {
            let sftp = conn
                .sftp()
                .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;

            let mut scanned: HashMap<PathBuf, Vec<DirEntry>> = HashMap::new();
            let mut stack: Vec<(PathBuf, usize)> = vec![(PathBuf::from(&root_path), 0)];

            while let Some((current_path, depth)) = stack.pop() {
                if depth > max_depth {
                    continue;
                }
                if scanned.contains_key(&current_path) {
                    continue;
                }

                let sftp_entries = match sftp.readdir(&current_path) {
                    Ok(entries) => entries,
                    Err(_) => continue, // 权限不足等错误跳过；连接断开会在下次 sftp() 时由 with_conn 捕获
                };

                let mut dir_entries = Vec::new();
                for (p, stat) in sftp_entries {
                    let name = p
                        .file_name()
                        .and_then(|s| s.to_str())
                        .unwrap_or("")
                        .to_string();
                    if name == "." || name == ".." {
                        continue;
                    }
                    let is_dir = stat.is_dir();
                    let file_type = if is_dir { "directory" } else { "file" };
                    dir_entries.push(DirEntry {
                        name: name.clone(),
                        file_type: file_type.to_string(),
                    });
                    if is_dir && !name.starts_with('.') {
                        stack.push((current_path.join(&name), depth + 1));
                    }
                }

                scanned.insert(current_path, dir_entries);
            }

            Ok(scanned)
        })?;

    let mut state_lock = state.lock().unwrap();
    if let Some(cache) = state_lock.caches.get_mut(&key) {
        let count = scanned.len();
        for (path, entries) in scanned {
            cache.directories.insert(path, entries);
        }
        eprintln!("Daemon: scan_project 完成，缓存了 {} 个目录", count);
    }

    Ok(Value::Boolean(true))
}

// =============================================================================
// mkdir — 创建远程目录
// =============================================================================

pub fn handle_mkdir(
    user: &str,
    host: &str,
    port: u16,
    path: &str,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    DaemonState::with_conn(state, user, host, port, |conn| {
        let sftp = conn
            .sftp()
            .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;
        sftp.mkdir(Path::new(path), 0o755)
            .map_err(|e| anyhow::anyhow!("创建目录失败 {}: {}", path, e))?;
        Ok(())
    })?;

    let key = DaemonState::connection_key(user, host, port);
    invalidate_parent_cache(state, &key, Path::new(path));

    Ok(Value::Boolean(true))
}

// =============================================================================
// remove_file — 删除远程文件
// =============================================================================

pub fn handle_remove_file(
    user: &str,
    host: &str,
    port: u16,
    path: &str,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    DaemonState::with_conn(state, user, host, port, |conn| {
        let sftp = conn
            .sftp()
            .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;
        sftp.unlink(Path::new(path))
            .map_err(|e| anyhow::anyhow!("删除文件失败 {}: {}", path, e))?;
        Ok(())
    })?;

    let key = DaemonState::connection_key(user, host, port);
    invalidate_parent_cache(state, &key, Path::new(path));

    Ok(Value::Boolean(true))
}

// =============================================================================
// remove_dir — 删除远程目录
// =============================================================================

pub fn handle_remove_dir(
    user: &str,
    host: &str,
    port: u16,
    path: &str,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    DaemonState::with_conn(state, user, host, port, |conn| {
        let sftp = conn
            .sftp()
            .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;
        sftp.rmdir(Path::new(path))
            .map_err(|e| anyhow::anyhow!("删除目录失败 {}: {}", path, e))?;
        Ok(())
    })?;

    let key = DaemonState::connection_key(user, host, port);
    invalidate_parent_cache(state, &key, Path::new(path));
    {
        let mut state_lock = state.lock().unwrap();
        if let Some(cache) = state_lock.caches.get_mut(&key) {
            cache.directories.remove(&PathBuf::from(path));
        }
    }

    Ok(Value::Boolean(true))
}

// =============================================================================
// rename — 重命名/移动远程路径
// =============================================================================

pub fn handle_rename(
    user: &str,
    host: &str,
    port: u16,
    src: &str,
    dst: &str,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    DaemonState::with_conn(state, user, host, port, |conn| {
        let sftp = conn
            .sftp()
            .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;
        sftp.rename(Path::new(src), Path::new(dst), None)
            .map_err(|e| anyhow::anyhow!("重命名失败 {} -> {}: {}", src, dst, e))?;
        Ok(())
    })?;

    let key = DaemonState::connection_key(user, host, port);
    invalidate_parent_cache(state, &key, Path::new(src));
    invalidate_parent_cache(state, &key, Path::new(dst));
    {
        let mut state_lock = state.lock().unwrap();
        if let Some(cache) = state_lock.caches.get_mut(&key) {
            cache.directories.remove(&PathBuf::from(src));
        }
    }

    Ok(Value::Boolean(true))
}

// =============================================================================
// exec_remote — 在远端执行命令并返回 stdout
// =============================================================================
// 用于轻量级探测，如 `which python3`。
// 注意：复用同一个 libssh2 Session，与 SFTP 操作通过 Mutex 互斥。

pub fn handle_exec_remote(
    user: &str,
    host: &str,
    port: u16,
    cmd: &str,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    DaemonState::with_conn(state, user, host, port, |conn| {
        let mut channel = conn
            .session
            .channel_session()
            .map_err(|e| anyhow::anyhow!("channel_session 失败: {}", e))?;
        channel
            .exec(cmd)
            .map_err(|e| anyhow::anyhow!("exec 失败: {}", e))?;

        let mut stdout = String::new();
        channel
            .read_to_string(&mut stdout)
            .map_err(|e| anyhow::anyhow!("读取 stdout 失败: {}", e))?;
        channel.wait_close().ok();

        Ok(Value::String(stdout.trim().to_string().into()))
    })
}

// =============================================================================
// 辅助函数
// =============================================================================

/// 将 DirEntry 列表转换为 Msgpack 数组格式
pub fn entries_to_msgpack(entries: &[DirEntry]) -> Value {
    let mut result = Vec::new();
    for entry in entries {
        let map = vec![
            (
                Value::String("name".into()),
                Value::String(entry.name.clone().into()),
            ),
            (
                Value::String("type".into()),
                Value::String(entry.file_type.clone().into()),
            ),
        ];
        result.push(Value::Map(map));
    }
    Value::Array(result)
}
