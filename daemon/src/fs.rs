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
// fetch_file — SFTP 读取远程文件
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

    eprintln!("Daemon: 文件已写入 {} ({} bytes)", path, content.len());
    Ok(Value::Boolean(true))
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
