// =============================================================================
// fs.rs — 远程文件系统操作
// =============================================================================
// 所有 handler 通过 session::with_conn 走共享会话，自动应对会话断开后的重连。
// 读文件走 exec 通道（一次往返合并 stat + 读取），其余走 SFTP。

use crate::rpc::map;
use crate::session::{self, exec_shared, shell_quote, with_conn, ConnSession};
use crate::state::{DirCache, DirEntry, LockExt, SharedState, Target};
use rmpv::Value;
use ssh2::{FileStat, OpenFlags, OpenType, RenameFlags, Sftp};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

/// 远程文件读取上限（10 MiB）。超过该大小的文件直接拒绝，避免 RPC 通道被一次
/// 性塞入海量数据导致 Neovim UI 长时间卡死。需要查看大文件请走 ripgrep / less。
const MAX_FETCH_SIZE: u64 = 10 * 1024 * 1024;

/// 文件内容 → msgpack 值：合法 UTF-8 发 String，否则发 Binary（原样字节）。
/// 不做 lossy 转换——U+FFFD 替换会在写回时永久破坏数据。
fn bytes_to_value(bytes: Vec<u8>) -> Value {
    match String::from_utf8(bytes) {
        Ok(s) => Value::String(s.into()),
        Err(e) => Value::Binary(e.into_bytes()),
    }
}

fn too_big(size: impl std::fmt::Display, path: &str) -> anyhow::Error {
    anyhow::anyhow!(
        "文件过大无法打开 ({} 字节，上限 {} 字节): {}",
        size,
        MAX_FETCH_SIZE,
        path
    )
}

/// 在共享会话的 SFTP 通道上执行操作
fn with_sftp<T>(
    state: &SharedState,
    t: &Target,
    mut f: impl FnMut(&Sftp) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    with_conn(state, t, |conn| f(conn.sftp()?))
}

/// 对某连接的目录缓存执行操作
fn with_cache(state: &SharedState, t: &Target, f: impl FnOnce(&mut DirCache)) {
    f(state.lock_ok().caches.entry(t.key()).or_default());
}

// =============================================================================
// fetch_path — 合并 stat 和读取，一次 exec 往返
// =============================================================================
// 返回 ["directory", nil] | ["file", content]

pub fn fetch_path(t: &Target, path: &str, state: &SharedState) -> anyhow::Result<Value> {
    let q = shell_quote(path);
    // 远端先 stat 大小：超出阈值直接返回 TOOBIG，不执行 cat，避免无谓传输。
    let script = format!(
        "if [ -d {0} ]; then printf 'DIR'; elif [ -f {0} ]; then size=$(wc -c < {0} 2>/dev/null | tr -d ' '); if [ \"${{size:-0}}\" -gt {1} ]; then printf 'TOOBIG:%s' \"$size\"; else printf 'FILE'; cat {0}; fi; else printf 'MISSING'; fi",
        q, MAX_FETCH_SIZE
    );
    let mut out = exec_shared(state, t, &script, None, None)?;
    let stdout = &mut out.stdout;

    if stdout.starts_with(b"DIR") {
        Ok(Value::Array(vec![Value::from("directory"), Value::Nil]))
    } else if stdout.starts_with(b"FILE") {
        // 非 UTF-8 内容（Latin-1 / GBK / 二进制）以 Binary 原样返回
        let content = stdout.split_off(4);
        Ok(Value::Array(vec![
            Value::from("file"),
            bytes_to_value(content),
        ]))
    } else if let Some(size) = stdout.strip_prefix(b"TOOBIG:") {
        Err(too_big(String::from_utf8_lossy(size).trim(), path))
    } else if stdout.starts_with(b"MISSING") {
        // Lua 侧按 "路径不存在" 识别新文件
        Err(anyhow::anyhow!("路径不存在: {}", path))
    } else {
        Err(anyhow::anyhow!(
            "未知结果: {} | stderr: {}",
            String::from_utf8_lossy(stdout),
            String::from_utf8_lossy(&out.stderr)
        ))
    }
}

// =============================================================================
// fetch_paths — 批量获取多个文件内容（LSP 跳转等场景降低 RTT）
// =============================================================================
// 返回 { path = content }，不存在的路径直接省略

pub fn fetch_paths(t: &Target, paths: Vec<String>, state: &SharedState) -> anyhow::Result<Value> {
    if paths.is_empty() {
        return Ok(Value::Map(vec![]));
    }
    let out = exec_shared(state, t, &build_fetch_paths_script(&paths), None, None)?;
    let mut result = Vec::new();
    for record in parse_fetch_paths_payload(&out.stdout)? {
        match record {
            FetchPathRecord::File { path, content } => {
                result.push((Value::from(path), bytes_to_value(content)));
            }
            FetchPathRecord::Missing { .. } => {}
            FetchPathRecord::TooBig { path, size } => return Err(too_big(size, &path)),
        }
    }
    Ok(Value::Map(result))
}

/// 生成批量读取脚本。每条记录：`ZP\n<path_len>\n<status>\n<data_len>\n<path><data>`
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
        script.push_str(&format!(
            "printf 'ZP\\n{len}\\n'; \
             if [ -f {q} ] && head -c {limit} {q} > \"$t\" 2>/dev/null; then \
               size=$(wc -c < \"$t\" | tr -d ' '); \
               if [ \"${{size:-0}}\" -gt {max} ]; then \
                 size=$(wc -c < {q} 2>/dev/null | tr -d ' '); \
                 printf 'TOOBIG\\n%s\\n' \"${{size:-0}}\"; \
                 printf %s {q}; \
               else \
                 printf 'OK\\n%s\\n' \"${{size:-0}}\"; \
                 printf %s {q}; \
                 cat \"$t\"; \
               fi; \
             else \
               printf 'MISSING\\n0\\n'; \
               printf %s {q}; \
             fi; ",
            len = path.len(),
            q = shell_quote(path),
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

fn parse_fetch_paths_payload(out: &[u8]) -> anyhow::Result<Vec<FetchPathRecord>> {
    let err = |msg: String| anyhow::anyhow!("批量读取协议错误: {}", msg);
    let parse_len = |s: &str, label: &str| {
        s.parse::<usize>()
            .map_err(|_| err(format!("invalid {}", label)))
    };
    let mut pos = 0;
    let mut records = Vec::new();
    while pos < out.len() {
        let magic = read_line(out, &mut pos)?;
        if magic != "ZP" {
            return Err(err(format!("expected ZP marker, got {:?}", magic)));
        }
        let path_len = parse_len(read_line(out, &mut pos)?, "path length")?;
        let status = read_line(out, &mut pos)?;
        let data_len = parse_len(read_line(out, &mut pos)?, "data length")?;

        let path =
            take(out, &mut pos, path_len).ok_or_else(|| err("path length out of bounds".into()))?;
        let path = String::from_utf8(path.to_vec()).map_err(|_| err("path 非 UTF-8".into()))?;

        records.push(match status {
            "OK" => {
                let content = take(out, &mut pos, data_len)
                    .ok_or_else(|| err(format!("content length out of bounds for {}", path)))?;
                FetchPathRecord::File {
                    path,
                    content: content.to_vec(),
                }
            }
            "MISSING" => FetchPathRecord::Missing { path },
            "TOOBIG" => FetchPathRecord::TooBig {
                path,
                size: data_len as u64,
            },
            other => return Err(err(format!("unknown status {}", other))),
        });
    }
    Ok(records)
}

/// 读到下一个换行（不含换行本身）
fn read_line<'a>(out: &'a [u8], pos: &mut usize) -> anyhow::Result<&'a str> {
    let rest = &out[*pos..];
    let nl = rest
        .iter()
        .position(|b| *b == b'\n')
        .ok_or(anyhow::anyhow!("批量读取协议错误: missing newline"))?;
    *pos += nl + 1;
    std::str::from_utf8(&rest[..nl])
        .map_err(|_| anyhow::anyhow!("批量读取协议错误: header 非 UTF-8"))
}

/// 从 pos 起取 len 字节；越界返回 None
fn take<'a>(out: &'a [u8], pos: &mut usize, len: usize) -> Option<&'a [u8]> {
    let bytes = out.get(*pos..pos.checked_add(len)?)?;
    *pos += len;
    Some(bytes)
}

// =============================================================================
// SFTP 读写
// =============================================================================

pub fn fetch_file(t: &Target, path: &str, state: &SharedState) -> anyhow::Result<Value> {
    with_sftp(state, t, |sftp| {
        let mut file = sftp
            .open(Path::new(path))
            .map_err(|e| anyhow::anyhow!("无法打开远程文件 {}: {}", path, e))?;
        let mut content = Vec::new();
        file.read_to_end(&mut content)
            .map_err(|e| anyhow::anyhow!("读取失败 {}: {}", path, e))?;
        Ok(bytes_to_value(content))
    })
}

pub fn write_file(
    t: &Target,
    path: &str,
    content: &[u8],
    state: &SharedState,
) -> anyhow::Result<Value> {
    with_conn(state, t, |conn| write_file_atomic(conn, path, content))?;
    debug_log!("Daemon: 文件已写入 {} ({} bytes)", path, content.len());
    with_cache(state, t, |c| c.invalidate_parent(Path::new(path)));
    Ok(Value::Boolean(true))
}

/// 原子写：同目录下写临时文件 → fsync/close（检查错误）→ rename 覆盖目标。
/// 写到一半断线 / 磁盘满时，原文件保持完好，不会留下被截断的半截文件。
///
/// 回退：目标是符号链接 / 非普通文件，或临时文件建不出来（目录不可写）时，
/// 退回"截断后原地写"，保证至少能保存。
fn write_file_atomic(conn: &mut ConnSession, path: &str, content: &[u8]) -> anyhow::Result<()> {
    let target = Path::new(path);
    let write_err = |e: std::io::Error| anyhow::anyhow!("写入失败 {}: {}", path, e);
    let close_err = |e: ssh2::Error| anyhow::anyhow!("关闭文件失败 {}: {}", path, e);

    // lstat：不跟随符号链接——rename 覆盖链接会把链接替换成普通文件
    let existing = match conn.sftp()?.lstat(target) {
        Ok(st) => Some(st),
        // LIBSSH2_FX_NO_SUCH_FILE = 2, LIBSSH2_FX_NO_SUCH_PATH = 10
        Err(e) if matches!(e.code(), ssh2::ErrorCode::SFTP(2 | 10)) => None,
        Err(e) => return Err(anyhow::anyhow!("stat 失败 {}: {}", path, e)),
    };
    if existing.as_ref().is_some_and(|st| !st.is_file()) {
        return write_file_in_place(conn.sftp()?, path, content);
    }
    // perm 里含文件类型位，只保留权限位
    let perm = existing.and_then(|st| st.perm).map(|p| p & 0o7777);

    let tmp = tmp_path_for(target);
    let sftp = conn.sftp()?;
    let flags = OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::EXCLUSIVE | OpenFlags::TRUNCATE;
    let mut file = match sftp.open_mode(&tmp, flags, perm.unwrap_or(0o644) as i32, OpenType::File) {
        Ok(f) => f,
        Err(e) => {
            debug_log!(
                "Daemon: 无法创建临时文件 {} ({})，退回原地写",
                tmp.display(),
                e
            );
            return write_file_in_place(sftp, path, content);
        }
    };
    let written = file.write_all(content).map_err(write_err).and_then(|_| {
        // fsync 需要服务端支持 fsync@openssh.com；不支持时忽略
        let _ = file.fsync();
        close_sftp_file(&mut file).map_err(close_err)
    });
    drop(file);
    if let Err(e) = written {
        let _ = sftp.unlink(&tmp);
        return Err(e);
    }

    // 保留原文件权限（open_mode 的 mode 会被远端 umask 削减）
    if let Some(perm) = perm {
        let st = FileStat {
            size: None,
            uid: None,
            gid: None,
            perm: Some(perm),
            atime: None,
            mtime: None,
        };
        if let Err(e) = sftp.setstat(&tmp, st) {
            debug_log!("Daemon: 无法保留权限 {}: {}", path, e);
        }
    }

    // rename 覆盖：SFTP v3（OpenSSH）不支持 overwrite flag，目标存在时会失败；
    // 依次回退到远端 `mv -f`（同目录 rename(2)，原子）、再到 unlink + rename。
    let overwrite = RenameFlags::OVERWRITE | RenameFlags::ATOMIC | RenameFlags::NATIVE;
    let renamed = sftp.rename(&tmp, target, Some(overwrite)).is_ok() || {
        let mv = format!(
            "mv -f -- {} {}",
            shell_quote(&tmp.to_string_lossy()),
            shell_quote(path)
        );
        session::exec(&conn.session, &mv, None).is_ok_and(|o| o.code == 0)
    };
    // 上面借用了 conn.session，重新拿 sftp 句柄
    let sftp = conn.sftp()?;
    let renamed = renamed || {
        let _ = sftp.unlink(target);
        sftp.rename(&tmp, target, None).is_ok()
    };
    if !renamed {
        let _ = sftp.unlink(&tmp);
        return Err(anyhow::anyhow!(
            "写入失败 {}: 无法将临时文件重命名为目标",
            path
        ));
    }
    Ok(())
}

/// 截断目标后原地写。仅在原子写不可用时使用。
fn write_file_in_place(sftp: &Sftp, path: &str, content: &[u8]) -> anyhow::Result<()> {
    let mut file = sftp
        .create(Path::new(path))
        .map_err(|e| anyhow::anyhow!("无法创建远程文件 {}: {}", path, e))?;
    file.write_all(content)
        .map_err(|e| anyhow::anyhow!("写入失败 {}: {}", path, e))?;
    close_sftp_file(&mut file).map_err(|e| anyhow::anyhow!("关闭文件失败 {}: {}", path, e))
}

/// 显式 close 并检查错误（Drop 时的 close 会吞掉错误）；EAGAIN 时重试
fn close_sftp_file(file: &mut ssh2::File) -> Result<(), ssh2::Error> {
    for _ in 0..100 {
        match file.close() {
            Err(e) if e.code() == ssh2::ErrorCode::Session(-37) => {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            r => return r,
        }
    }
    file.close()
}

/// 同目录的隐藏临时文件名：`.<name>.zero-tmp-<pid>-<nanos>`
fn tmp_path_for(target: &Path) -> PathBuf {
    let name = target
        .file_name()
        .map_or_else(|| "file".into(), |n| n.to_string_lossy());
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    let tmp_name = format!(".{}.zero-tmp-{}-{}", name, std::process::id(), nanos);
    target.with_file_name(tmp_name)
}

// =============================================================================
// 目录
// =============================================================================

/// SFTP readdir → DirEntry 列表（去掉 . / ..）
fn list_dir(sftp: &Sftp, path: &Path) -> Result<Vec<DirEntry>, ssh2::Error> {
    Ok(sftp
        .readdir(path)?
        .into_iter()
        .filter_map(|(p, stat)| {
            let name = p.file_name()?.to_str()?.to_string();
            (name != "." && name != "..").then(|| DirEntry {
                name,
                is_dir: stat.is_dir(),
            })
        })
        .collect())
}

/// 返回 [{ name, type = "directory" | "file" }]
fn entries_to_value(entries: &[DirEntry]) -> Value {
    Value::Array(
        entries
            .iter()
            .map(|e| {
                map([
                    ("name", Value::from(e.name.as_str())),
                    ("type", Value::from(file_type(e.is_dir))),
                ])
            })
            .collect(),
    )
}

fn file_type(is_dir: bool) -> &'static str {
    if is_dir {
        "directory"
    } else {
        "file"
    }
}

pub fn read_dir(t: &Target, path: &str, state: &SharedState) -> anyhow::Result<Value> {
    let path_buf = PathBuf::from(path);
    if let Some(entries) = state
        .lock_ok()
        .caches
        .get(&t.key())
        .and_then(|c| c.get(&path_buf))
    {
        return Ok(entries_to_value(entries));
    }
    let entries = with_sftp(state, t, |sftp| {
        list_dir(sftp, &path_buf).map_err(|e| anyhow::anyhow!("读目录失败 {}: {}", path, e))
    })?;
    let result = entries_to_value(&entries);
    with_cache(state, t, |c| c.insert(path_buf, entries));
    Ok(result)
}

/// 返回 "directory" | "file"
pub fn stat(t: &Target, path: &str, state: &SharedState) -> anyhow::Result<Value> {
    with_sftp(state, t, |sftp| {
        let st = sftp
            .stat(Path::new(path))
            .map_err(|e| anyhow::anyhow!("stat 失败 {}: {}", path, e))?;
        Ok(Value::from(file_type(st.is_dir())))
    })
}

/// 预扫描目录树（最多 3 层，跳过隐藏目录）并填充缓存
pub fn scan_project(t: &Target, root: &str, state: &SharedState) -> anyhow::Result<Value> {
    const MAX_DEPTH: usize = 3;
    let scanned = with_sftp(state, t, |sftp| {
        let mut scanned: HashMap<PathBuf, Vec<DirEntry>> = HashMap::new();
        let mut stack = vec![(PathBuf::from(root), 0)];
        while let Some((dir, depth)) = stack.pop() {
            if depth > MAX_DEPTH || scanned.contains_key(&dir) {
                continue;
            }
            // 权限不足等错误跳过；连接断开会在下次操作时由 with_conn 捕获
            let Ok(entries) = list_dir(sftp, &dir) else {
                continue;
            };
            for e in entries
                .iter()
                .filter(|e| e.is_dir && !e.name.starts_with('.'))
            {
                stack.push((dir.join(&e.name), depth + 1));
            }
            scanned.insert(dir, entries);
        }
        Ok(scanned)
    })?;

    debug_log!("Daemon: scan_project 完成，缓存了 {} 个目录", scanned.len());
    with_cache(state, t, |cache| {
        for (path, entries) in scanned {
            cache.insert(path, entries);
        }
    });
    Ok(Value::Boolean(true))
}

// =============================================================================
// 增删改
// =============================================================================

/// 执行一个 SFTP 修改操作，成功后按 invalidate 失效缓存
fn sftp_mutate(
    t: &Target,
    state: &SharedState,
    op: impl Fn(&Sftp) -> Result<(), ssh2::Error>,
    describe: impl Fn(ssh2::Error) -> anyhow::Error,
    invalidate: impl FnOnce(&mut DirCache),
) -> anyhow::Result<Value> {
    with_sftp(state, t, |sftp| op(sftp).map_err(&describe))?;
    with_cache(state, t, invalidate);
    Ok(Value::Boolean(true))
}

pub fn mkdir(t: &Target, path: &str, state: &SharedState) -> anyhow::Result<Value> {
    let p = Path::new(path);
    sftp_mutate(
        t,
        state,
        |sftp| sftp.mkdir(p, 0o755),
        |e| anyhow::anyhow!("创建目录失败 {}: {}", path, e),
        |c| c.invalidate_tree(p),
    )
}

pub fn remove_file(t: &Target, path: &str, state: &SharedState) -> anyhow::Result<Value> {
    let p = Path::new(path);
    sftp_mutate(
        t,
        state,
        |sftp| sftp.unlink(p),
        |e| anyhow::anyhow!("删除文件失败 {}: {}", path, e),
        |c| c.invalidate_parent(p),
    )
}

pub fn remove_dir(t: &Target, path: &str, state: &SharedState) -> anyhow::Result<Value> {
    let p = Path::new(path);
    sftp_mutate(
        t,
        state,
        |sftp| sftp.rmdir(p),
        |e| anyhow::anyhow!("删除目录失败 {}: {}", path, e),
        |c| c.invalidate_tree(p),
    )
}

pub fn rename(t: &Target, src: &str, dst: &str, state: &SharedState) -> anyhow::Result<Value> {
    let (s, d) = (Path::new(src), Path::new(dst));
    sftp_mutate(
        t,
        state,
        |sftp| sftp.rename(s, d, None),
        |e| anyhow::anyhow!("重命名失败 {} -> {}: {}", src, dst, e),
        // src 子树整体搬走；dst 若是被覆盖的目录，其旧子树缓存同样作废
        |c| {
            c.invalidate_tree(s);
            c.invalidate_tree(d);
        },
    )
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
        assert_eq!(
            records,
            vec![FetchPathRecord::File {
                path: "/tmp/a.py".into(),
                content: content.to_vec()
            }]
        );
    }

    #[test]
    fn parse_fetch_paths_payload_keeps_non_utf8_bytes() {
        let mut payload = record("/tmp/bin", "OK", 2, &[0xff, 0xfe]);
        payload.extend(record("/tmp/gone", "MISSING", 0, b""));
        payload.extend(record("/tmp/big", "TOOBIG", 99, b""));

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
                FetchPathRecord::TooBig {
                    path: "/tmp/big".into(),
                    size: 99
                },
            ]
        );
    }

    #[test]
    fn parse_fetch_paths_payload_rejects_truncated_frames() {
        let mut payload = record("/tmp/a", "OK", 10, b"short");
        assert!(parse_fetch_paths_payload(&payload).is_err());
        payload.truncate(3);
        assert!(parse_fetch_paths_payload(&payload).is_err());
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
