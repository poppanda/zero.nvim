// =============================================================================
// fs.rs — 远程文件系统操作
// =============================================================================
// 包含所有 SFTP 相关的 RPC 方法:
//   - fetch_file:    读取远程文件
//   - write_file:    写入远程文件
//   - read_dir:      读取目录（带缓存）
//   - stat:          查询路径类型
//   - scan_project:  递归预扫描目录树

use crate::state::{DaemonState, DirEntry};
use rmpv::Value;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

// =============================================================================
// fetch_path — 合并 stat 和 fetch，通过 Exec 通道直接获取，显著降低延迟
// =============================================================================

pub fn handle_fetch_path(
    user: &str,
    host: &str,
    port: u16,
    path: &str,
    state: &Arc<Mutex<DaemonState>>,
) -> Result<Value, anyhow::Error> {
    let key = DaemonState::connection_key(user, host, port);
    let state_lock = state.lock().unwrap();
    let sess = state_lock
        .sessions
        .get(&key)
        .ok_or(anyhow::anyhow!("NOT_CONNECTED: {}", key))?;

    let mut channel = sess
        .channel_session()
        .map_err(|e| anyhow::anyhow!("无法开启 SSH 通道: {}", e))?;

    let escaped_path = format!("'{}'", path.replace('\'', "'\\''"));
    let script = format!(
        "if [ -d {0} ]; then echo -n 'DIR'; elif [ -f {0} ]; then echo -n 'FILE'; cat {0}; else echo -n 'MISSING'; fi",
        escaped_path
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
        let content_str = String::from_utf8_lossy(content_bytes).into_owned();
        Ok(Value::Array(vec![
            Value::String("file".into()),
            Value::String(content_str.into()),
        ]))
    } else if out.starts_with(b"MISSING") {
        Err(anyhow::anyhow!("路径不存在: {}", path))
    } else {
        let out_str = String::from_utf8_lossy(&out);
        Err(anyhow::anyhow!("未知结果: {} | stderr: {}", out_str, err))
    }
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

    let key = DaemonState::connection_key(user, host, port);
    let state_lock = state.lock().unwrap();
    let sess = state_lock
        .sessions
        .get(&key)
        .ok_or(anyhow::anyhow!("NOT_CONNECTED: {}", key))?;

    let mut channel = sess
        .channel_session()
        .map_err(|e| anyhow::anyhow!("无法开启 SSH 通道: {}", e))?;

    // Build a single shell script that echoes boundaries and cats the files
    let mut script = String::new();
    for p in &paths {
        let escaped = p.replace('\'', "'\\''");
        script.push_str(&format!(
            "echo -n '<<<Z_FILE:{p}>>>'; if [ -f '{escaped}' ]; then cat '{escaped}'; fi; echo -n '<<<Z_END>>>'; ",
            p = p,
            escaped = escaped
        ));
    }

    channel
        .exec(&script)
        .map_err(|e| anyhow::anyhow!("批量远程执行失败: {}", e))?;

    let mut out = Vec::new();
    channel
        .read_to_end(&mut out)
        .map_err(|e| anyhow::anyhow!("读取数据失败: {}", e))?;
    channel.wait_close().ok();

    let out_str = String::from_utf8_lossy(&out);
    
    let mut result_map = Vec::new();
    
    // Parse the output based on our boundaries
    // Format: <<<Z_FILE:/path>>>[content]<<<Z_END>>>
    let mut current_pos = 0;
    while let Some(start_idx) = out_str[current_pos..].find("<<<Z_FILE:") {
        let absolute_start = current_pos + start_idx;
        let path_start = absolute_start + "<<<Z_FILE:".len();
        
        if let Some(path_end_relative) = out_str[path_start..].find(">>>") {
            let path_end = path_start + path_end_relative;
            let path = &out_str[path_start..path_end];
            
            let content_start = path_end + ">>>".len();
            if let Some(content_end_relative) = out_str[content_start..].find("<<<Z_END>>>") {
                let content_end = content_start + content_end_relative;
                let content = &out_str[content_start..content_end];
                
                result_map.push((
                    Value::String(path.into()),
                    Value::String(content.into())
                ));
                
                current_pos = content_end + "<<<Z_END>>>".len();
            } else {
                break;
            }
        } else {
            break;
        }
    }

    Ok(Value::Map(result_map))
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
    let key = DaemonState::connection_key(user, host, port);
    let state_lock = state.lock().unwrap();
    let sess = state_lock
        .sessions
        .get(&key)
        .ok_or(anyhow::anyhow!("NOT_CONNECTED: {}", key))?;

    // 使用 SFTP 直接读取，而非 shell exec cat
    // 优势: 无 shell 注入风险、支持任意文件名
    let sftp = sess
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
    let key = DaemonState::connection_key(user, host, port);
    let state_lock = state.lock().unwrap();
    let sess = state_lock
        .sessions
        .get(&key)
        .ok_or(anyhow::anyhow!("NOT_CONNECTED: {}", key))?;

    let sftp = sess
        .sftp()
        .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;

    // CREATE | TRUNCATE | WRITE 模式 — 覆盖写入
    let mut remote_file = sftp
        .create(Path::new(path))
        .map_err(|e| anyhow::anyhow!("无法创建远程文件 {}: {}", path, e))?;
    remote_file
        .write_all(content.as_bytes())
        .map_err(|e| anyhow::anyhow!("写入失败 {}: {}", path, e))?;

    // Drop sftp/lock before invalidation
    drop(remote_file);
    drop(sftp);
    drop(state_lock);

    eprintln!("Daemon: 文件已写入 {} ({} bytes)", path, content.len());

    eprintln!("Daemon: 文件已写入 {} ({} bytes)", path, content.len());

    // Invalidate parent directory cache
    invalidate_parent_cache(state, &key, Path::new(path));

    Ok(Value::Boolean(true))
}

fn invalidate_parent_cache(state: &Arc<Mutex<DaemonState>>, key: &str, path: &Path) {
    if let Some(parent) = path.parent() {
        let mut state_lock = state.lock().unwrap();
        if let Some(cache) = state_lock.caches.get_mut(key) {
            // Remove parent from cache to force refresh on next read_dir
            // We use to_path_buf() because map keys are PathBuf
            cache.directories.remove(&parent.to_path_buf());
            eprintln!("Daemon: Invalidate cache for {:?}", parent);
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

    // 缓存未命中 → 通过 SFTP 读取
    let mut state_lock = state.lock().unwrap();
    let sess = state_lock
        .sessions
        .get(&key)
        .ok_or(anyhow::anyhow!("NOT_CONNECTED: {}", key))?;

    let sftp = sess
        .sftp()
        .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;
    let sftp_entries = sftp.readdir(Path::new(path))?;

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
        let file_type = if stat.is_dir() { "directory" } else { "file" };
        dir_entries.push(DirEntry {
            name,
            file_type: file_type.to_string(),
        });
    }

    let result = entries_to_msgpack(&dir_entries);

    // 存入缓存
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
    let key = DaemonState::connection_key(user, host, port);
    let state_lock = state.lock().unwrap();
    let sess = state_lock
        .sessions
        .get(&key)
        .ok_or(anyhow::anyhow!("NOT_CONNECTED: {}", key))?;

    let sftp = sess
        .sftp()
        .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;
    let stat = sftp.stat(Path::new(path))?;
    let file_type = if stat.is_dir() { "directory" } else { "file" };
    Ok(Value::String(file_type.into()))
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

    let state_lock = state.lock().unwrap();
    let sess = state_lock
        .sessions
        .get(&key)
        .ok_or(anyhow::anyhow!("NOT_CONNECTED: {}", key))?;
    let sftp = sess
        .sftp()
        .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;

    // 用临时 HashMap 收集结果，最后一次性写入缓存
    let mut scanned: HashMap<PathBuf, Vec<DirEntry>> = HashMap::new();

    // 栈: (路径, 当前深度)
    let mut stack: Vec<(PathBuf, usize)> = vec![(PathBuf::from(root_path), 0)];

    while let Some((current_path, depth)) = stack.pop() {
        if depth > max_depth {
            continue;
        }
        if scanned.contains_key(&current_path) {
            continue;
        }

        let sftp_entries = match sftp.readdir(&current_path) {
            Ok(entries) => entries,
            Err(_) => continue, // 权限不足等错误，跳过
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
            // 子目录入队（跳过隐藏目录）
            if is_dir && !name.starts_with('.') {
                stack.push((current_path.join(&name), depth + 1));
            }
        }

        scanned.insert(current_path, dir_entries);
    }

    // 释放读锁，获取写锁，写入缓存
    drop(state_lock);
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
    let key = DaemonState::connection_key(user, host, port);
    let state_lock = state.lock().unwrap();
    let sess = state_lock
        .sessions
        .get(&key)
        .ok_or(anyhow::anyhow!("NOT_CONNECTED: {}", key))?;

    let sftp = sess
        .sftp()
        .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;

    // mode 0o755 = rwxr-xr-x
    sftp.mkdir(Path::new(path), 0o755)
        .map_err(|e| anyhow::anyhow!("创建目录失败 {}: {}", path, e))?;

    // Drop sftp/session/lock explicitly or by scope if necessary.
    // Here we can just call invalidate after letting them drop at end of function?
    // No, sftp borrows from state_lock. We must drop state_lock before invalidate acquires it mutably.
    // So we must scope the SFTP part.
    // However, since we are rewriting the function body significantly, simpler to just wrap existing body in block?
    // Actually, `state_lock` is defined at top of function.
    // Let's rewrite the whole function body to be safe or use drop.
    drop(sftp); // Drop sftp first
    drop(state_lock); // Drop lock

    // Invalidate parent cache
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
    let key = DaemonState::connection_key(user, host, port);
    let state_lock = state.lock().unwrap();
    let sess = state_lock
        .sessions
        .get(&key)
        .ok_or(anyhow::anyhow!("NOT_CONNECTED: {}", key))?;

    let sftp = sess
        .sftp()
        .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;

    sftp.unlink(Path::new(path))
        .map_err(|e| anyhow::anyhow!("删除文件失败 {}: {}", path, e))?;

    drop(sftp);
    drop(state_lock);

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
    let key = DaemonState::connection_key(user, host, port);
    let state_lock = state.lock().unwrap();
    let sess = state_lock
        .sessions
        .get(&key)
        .ok_or(anyhow::anyhow!("NOT_CONNECTED: {}", key))?;

    let sftp = sess
        .sftp()
        .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;

    sftp.rmdir(Path::new(path))
        .map_err(|e| anyhow::anyhow!("删除目录失败 {}: {}", path, e))?;

    drop(sftp);
    drop(state_lock);

    invalidate_parent_cache(state, &key, Path::new(path));
    // Also remove the dir itself from cache if present
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
    let key = DaemonState::connection_key(user, host, port);
    let state_lock = state.lock().unwrap();
    let sess = state_lock
        .sessions
        .get(&key)
        .ok_or(anyhow::anyhow!("NOT_CONNECTED: {}", key))?;

    let sftp = sess
        .sftp()
        .map_err(|e| anyhow::anyhow!("SFTP 初始化失败: {}", e))?;

    // SFTP rename flags (atomic logic differs by server version, standard rename is usually sufficient)
    sftp.rename(Path::new(src), Path::new(dst), None)
        .map_err(|e| anyhow::anyhow!("重命名失败 {} -> {}: {}", src, dst, e))?;

    drop(sftp);
    drop(state_lock);

    invalidate_parent_cache(state, &key, Path::new(src));
    invalidate_parent_cache(state, &key, Path::new(dst));
    // Also if src was a cached dir, move it? Too complex. Just remove src from cache.
    {
        let mut state_lock = state.lock().unwrap();
        if let Some(cache) = state_lock.caches.get_mut(&key) {
            cache.directories.remove(&PathBuf::from(src));
            // We don't populate dst because we don't know its contents and scanning is distinct.
        }
    }

    Ok(Value::Boolean(true))
}

// =============================================================================
// 辅助函数
// =============================================================================

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
    let key = DaemonState::connection_key(user, host, port);
    let state_lock = state.lock().unwrap();
    let sess = state_lock
        .sessions
        .get(&key)
        .ok_or(anyhow::anyhow!("NOT_CONNECTED: {}", key))?;

    let mut channel = sess
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
}

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
