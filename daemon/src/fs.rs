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
use crate::state::{ConnSession, DaemonState, DirEntry, LockExt, ProjectCache};
use rmpv::Value;
use ssh2::{FileStat, OpenFlags, OpenType, RenameFlags};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// 文件内容 → msgpack 值：合法 UTF-8 发 String，否则发 Binary（原样字节）。
/// 不做 lossy 转换——U+FFFD 替换会在写回时永久破坏数据。
fn bytes_to_value(bytes: Vec<u8>) -> Value {
    match String::from_utf8(bytes) {
        Ok(s) => Value::String(s.into()),
        Err(e) => Value::Binary(e.into_bytes()),
    }
}

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
            // 非 UTF-8 内容（Latin-1 / GBK / 二进制）以 Binary 原样返回，不做 lossy 转换
            let content = out.split_off(4);
            Ok(Value::Array(vec![
                Value::String("file".into()),
                bytes_to_value(content),
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
                    result_map.push((Value::String(path.into()), bytes_to_value(content)));
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

/// 生成批量读取脚本。
///
/// 长度帧必须与实际发送的字节严格一致：先 `head -c` 把文件快照到临时文件，
/// 再对快照取大小并 cat 快照。直接 `wc -c` 原文件再 cat 原文件，中间文件
/// 被改动就会让帧错位、后续记录全部解析失败。`head -c MAX+1` 同时限制了
/// 超大文件的拷贝量。
fn build_fetch_paths_script(paths: &[String]) -> String {
    let mut script = String::from(
        "t=$(mktemp 2>/dev/null) || t=/tmp/.zero-fetch-$$; trap 'rm -f \"$t\"' EXIT; ",
    );
    for path in paths {
        let path_q = shell_quote(path);
        script.push_str(&format!(
            "printf 'ZP\\n{}\\n'; \
             if [ -f {path_q} ] && head -c {limit} {path_q} > \"$t\" 2>/dev/null; then \
               size=$(wc -c < \"$t\" | tr -d ' '); \
               if [ \"${{size:-0}}\" -gt {max} ]; then \
                 size=$(wc -c < {path_q} 2>/dev/null | tr -d ' '); \
                 printf 'TOOBIG\\n%s\\n' \"${{size:-0}}\"; \
                 printf %s {path_q}; \
               else \
                 printf 'OK\\n%s\\n' \"${{size:-0}}\"; \
                 printf %s {path_q}; \
                 cat \"$t\"; \
               fi; \
             else \
               printf 'MISSING\\n0\\n'; \
               printf %s {path_q}; \
             fi; ",
            path.len(),
            path_q = path_q,
            max = MAX_FETCH_SIZE,
            limit = MAX_FETCH_SIZE + 1
        ));
    }
    script
}

#[derive(Debug, PartialEq, Eq)]
enum FetchPathRecord {
    File { path: String, content: Vec<u8> },
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
                let content = out[pos..pos + data_len].to_vec();
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
        let mut content = Vec::new();
        remote_file
            .read_to_end(&mut content)
            .map_err(|e| anyhow::anyhow!("读取失败 {}: {}", path, e))?;

        Ok(bytes_to_value(content))
    })
}

// =============================================================================
// write_file — SFTP 写入远程文件
// =============================================================================

pub fn handle_write_file(
    user: &str,
    host: &str,
    port: u16,
    path: &str,
    content: &[u8],
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    DaemonState::with_conn(state, user, host, port, |conn| {
        write_file_atomic(conn, path, content)
    })?;

    debug_log!("Daemon: 文件已写入 {} ({} bytes)", path, content.len());

    let key = DaemonState::connection_key(user, host, port);
    with_cache(state, &key, |c| c.invalidate_parent(Path::new(path)));

    Ok(Value::Boolean(true))
}

/// 原子写：同目录下写临时文件 → fsync/close（检查错误）→ rename 覆盖目标。
/// 写到一半断线 / 磁盘满时，原文件保持完好，不会留下被截断的半截文件。
///
/// 回退：目标是符号链接 / 非普通文件，或临时文件建不出来（目录不可写）时，
/// 退回原来的"截断后原地写"，保证至少和以前一样能保存。
fn write_file_atomic(conn: &mut ConnSession, path: &str, content: &[u8]) -> Result<(), anyhow::Error> {
    let target = Path::new(path);
    let sftp_err = |e: ssh2::Error| anyhow::anyhow!("SFTP 初始化失败: {}", e);

    // lstat：不跟随符号链接——rename 覆盖链接会把链接替换成普通文件
    let existing = match conn.sftp().map_err(sftp_err)?.lstat(target) {
        Ok(st) => Some(st),
        Err(e) if is_not_found(&e) => None,
        Err(e) => return Err(anyhow::anyhow!("stat 失败 {}: {}", path, e)),
    };
    let is_regular = existing.as_ref().is_none_or(|st| st.is_file());
    if !is_regular {
        return write_file_in_place(conn, path, content);
    }
    // perm 里含文件类型位，只保留权限位
    let mode = existing
        .as_ref()
        .and_then(|st| st.perm)
        .map(|p| (p & 0o7777) as i32)
        .unwrap_or(0o644);

    let tmp = tmp_path_for(target);
    let sftp = conn.sftp().map_err(sftp_err)?;
    let mut file = match sftp.open_mode(
        &tmp,
        OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::EXCLUSIVE | OpenFlags::TRUNCATE,
        mode,
        OpenType::File,
    ) {
        Ok(f) => f,
        Err(e) => {
            debug_log!(
                "Daemon: 无法创建临时文件 {} ({})，退回原地写",
                tmp.display(),
                e
            );
            return write_file_in_place(conn, path, content);
        }
    };

    let write_res = file
        .write_all(content)
        .map_err(|e| anyhow::anyhow!("写入失败 {}: {}", path, e))
        .and_then(|_| {
            // fsync 需要服务端支持 fsync@openssh.com；不支持时忽略
            let _ = file.fsync();
            close_sftp_file(&mut file).map_err(|e| anyhow::anyhow!("关闭文件失败 {}: {}", path, e))
        });
    drop(file);
    if let Err(e) = write_res {
        let _ = sftp.unlink(&tmp);
        return Err(e);
    }

    // 保留原文件权限（open_mode 的 mode 会被远端 umask 削减）
    if let Some(perm) = existing.as_ref().and_then(|st| st.perm) {
        let st = FileStat {
            size: None,
            uid: None,
            gid: None,
            perm: Some(perm & 0o7777),
            atime: None,
            mtime: None,
        };
        if let Err(e) = sftp.setstat(&tmp, st) {
            debug_log!("Daemon: 无法保留权限 {}: {}", path, e);
        }
    }

    // rename 覆盖：SFTP v3（OpenSSH）不支持 overwrite flag，目标存在时会失败；
    // 依次回退到远端 `mv -f`（同目录 rename(2)，原子）、再到 unlink + rename。
    let renamed = sftp
        .rename(
            &tmp,
            target,
            Some(RenameFlags::OVERWRITE | RenameFlags::ATOMIC | RenameFlags::NATIVE),
        )
        .is_ok();
    let renamed = renamed || {
        let tmp_s = tmp.to_string_lossy().to_string();
        let mv = format!("mv -f -- {} {}", shell_quote(&tmp_s), shell_quote(path));
        matches!(exec_status(&conn.session, &mv), Ok(0))
    };
    // 上面借用了 conn.session，重新拿 sftp 句柄
    let sftp = conn.sftp().map_err(sftp_err)?;
    let renamed = renamed || {
        let _ = sftp.unlink(target);
        sftp.rename(&tmp, target, None).is_ok()
    };
    if !renamed {
        let _ = sftp.unlink(&tmp);
        return Err(anyhow::anyhow!("写入失败 {}: 无法将临时文件重命名为目标", path));
    }
    Ok(())
}

/// 旧路径：截断目标后原地写。仅在原子写不可用时使用。
fn write_file_in_place(conn: &mut ConnSession, path: &str, content: &[u8]) -> Result<(), anyhow::Error> {
    let sftp = conn
        .sftp()
        .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;
    let mut remote_file = sftp
        .create(Path::new(path))
        .map_err(|e| anyhow::anyhow!("无法创建远程文件 {}: {}", path, e))?;
    remote_file
        .write_all(content)
        .map_err(|e| anyhow::anyhow!("写入失败 {}: {}", path, e))?;
    close_sftp_file(&mut remote_file)
        .map_err(|e| anyhow::anyhow!("关闭文件失败 {}: {}", path, e))?;
    Ok(())
}

/// 显式 close 并检查错误（Drop 时的 close 会吞掉错误）；EAGAIN 时重试
fn close_sftp_file(file: &mut ssh2::File) -> Result<(), ssh2::Error> {
    let mut attempts = 0;
    loop {
        match file.close() {
            Err(e) if e.code() == ssh2::ErrorCode::Session(-37) && attempts < 100 => {
                attempts += 1;
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            r => return r,
        }
    }
}

fn is_not_found(e: &ssh2::Error) -> bool {
    // LIBSSH2_FX_NO_SUCH_FILE = 2, LIBSSH2_FX_NO_SUCH_PATH = 10
    matches!(e.code(), ssh2::ErrorCode::SFTP(2) | ssh2::ErrorCode::SFTP(10))
}

/// 同目录的隐藏临时文件名：`.<name>.zero-tmp-<pid>-<nanos>`
fn tmp_path_for(target: &Path) -> PathBuf {
    let name = target
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "file".to_string());
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let tmp_name = format!(".{}.zero-tmp-{}-{}", name, std::process::id(), nanos);
    match target.parent() {
        Some(p) => p.join(tmp_name),
        None => PathBuf::from(tmp_name),
    }
}

/// 在会话上执行一条短命令，返回退出码（blocking 模式，wait_close 后读取）
fn exec_status(session: &ssh2::Session, cmd: &str) -> Result<i32, anyhow::Error> {
    let mut ch = session.channel_session()?;
    ch.exec(cmd)?;
    let mut sink = Vec::new();
    let _ = ch.read_to_end(&mut sink);
    ch.wait_close()?;
    Ok(ch.exit_status()?)
}

/// 对某连接的目录缓存执行操作（缓存不存在时 no-op）
fn with_cache(state: &Arc<Mutex<DaemonState>>, key: &str, f: impl FnOnce(&mut ProjectCache)) {
    let mut state_lock = state.lock_ok();
    if let Some(cache) = state_lock.caches.get_mut(key) {
        f(cache);
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
        let state_lock = state.lock_ok();
        if let Some(cache) = state_lock.caches.get(&key) {
            if let Some(entries) = cache.get(&path_buf) {
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

    with_cache(state, &key, |c| c.insert(path_buf, dir_entries));

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

    with_cache(state, &key, |cache| {
        let count = scanned.len();
        for (path, entries) in scanned {
            cache.insert(path, entries);
        }
        debug_log!("Daemon: scan_project 完成，缓存了 {} 个目录", count);
    });

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
    with_cache(state, &key, |c| c.invalidate_tree(Path::new(path)));

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
    with_cache(state, &key, |c| c.invalidate_parent(Path::new(path)));

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
    with_cache(state, &key, |c| c.invalidate_tree(Path::new(path)));

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

    // src 子树整体搬走；dst 若是被覆盖的目录，其旧子树缓存同样作废
    let key = DaemonState::connection_key(user, host, port);
    with_cache(state, &key, |c| {
        c.invalidate_tree(Path::new(src));
        c.invalidate_tree(Path::new(dst));
    });

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

#[cfg(test)]
mod tests {
    use super::*;

    fn record(path: &str, status: &str, len: usize, content: &[u8]) -> Vec<u8> {
        let mut out = format!("ZP\n{}\n{}\n{}\n", path.len(), status, len).into_bytes();
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
                assert_eq!(content, b"hello <<<Z_END>>> still content\n");
            }
            other => panic!("unexpected record: {:?}", other),
        }
    }

    #[test]
    fn parse_fetch_paths_payload_keeps_non_utf8_bytes() {
        let mut payload = record("/tmp/bin", "OK", 2, &[0xff, 0xfe]);
        payload.extend(record("/tmp/gone", "MISSING", 0, b""));

        let records = parse_fetch_paths_payload(&payload).expect("payload parses");

        assert_eq!(
            records,
            vec![
                FetchPathRecord::File {
                    path: "/tmp/bin".into(),
                    content: vec![0xff, 0xfe]
                },
                FetchPathRecord::Missing {
                    path: "/tmp/gone".into()
                },
            ]
        );
    }

    #[test]
    fn bytes_to_value_picks_string_or_binary() {
        assert_eq!(bytes_to_value(b"hi".to_vec()), Value::String("hi".into()));
        assert_eq!(
            bytes_to_value(vec![0xff, 0x00]),
            Value::Binary(vec![0xff, 0x00])
        );
    }

    #[test]
    fn fetch_paths_script_frames_from_snapshot() {
        let script = build_fetch_paths_script(&["/a b".to_string()]);
        assert!(script.contains("mktemp"));
        assert!(script.contains("head -c"));
        assert!(script.contains("printf 'ZP\\n4\\n'"));
        assert!(script.contains("cat \"$t\""));
    }

    #[test]
    fn tmp_path_is_hidden_sibling() {
        let t = tmp_path_for(Path::new("/srv/app/main.rs"));
        assert_eq!(t.parent(), Some(Path::new("/srv/app")));
        let name = t.file_name().unwrap().to_str().unwrap();
        assert!(name.starts_with(".main.rs.zero-tmp-"), "{}", name);
    }
}
