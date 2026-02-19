use rmpv::{Value, decode, encode};
use std::io::{Write, Read};
use std::sync::{Arc, Mutex};
use std::net::TcpStream;
use ssh2::Session;
use std::collections::HashMap;

struct ProjectCache {
    directories: HashMap<std::path::PathBuf, Vec<DirEntry>>,
}

#[derive(Clone, Debug)]
struct DirEntry {
    name: String,
    file_type: String,
}

struct DaemonState {
    sessions: HashMap<String, Session>,
    caches: HashMap<String, ProjectCache>,
}

impl DaemonState {
    fn new() -> Self {
        Self { 
            sessions: HashMap::new(),
            caches: HashMap::new(),
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let state = Arc::new(Mutex::new(DaemonState::new()));
    let stdin = std::io::stdin();
    let mut reader = stdin.lock();
    let mut stdout = std::io::stdout();

    loop {
        let msg = match decode::read_value(&mut reader) {
            Ok(v) => v,
            Err(_) => break,
        };

        if let Value::Array(ref args) = msg {
            if args.len() == 4 {
                let msg_type = args[0].as_u64();
                let msg_id = args[1].as_u64();
                let method_val = &args[2];
                let params = &args[3];

                if let (Some(0), Some(id)) = (msg_type, msg_id) {
                    if let Some(method) = method_val.as_str() {
                        let response_res = handle_request(method, params, state.clone());
                        let (err, res) = match response_res {
                            Ok(val) => (Value::Nil, val),
                            Err(e) => (Value::String(format!("{}", e).into()), Value::Nil),
                        };
                        let response = Value::Array(vec![
                            Value::Integer(1.into()),
                            Value::Integer(id.into()),
                            err,
                            res,
                        ]);
                        if encode::write_value(&mut stdout, &response).is_ok() {
                            let _ = stdout.flush();
                        }
                        continue;
                    }
                }
            }
        }
    }
    Ok(())
}

fn handle_request(method: &str, params: &Value, state: Arc<Mutex<DaemonState>>) -> Result<Value, anyhow::Error> {
    match method {
        "connect" => {
            let args = params.as_array().ok_or(anyhow::anyhow!("Invalid params"))?;
            let user = args.get(0).and_then(|v| v.as_str()).ok_or(anyhow::anyhow!("Missing user"))?;
            let host = args.get(1).and_then(|v| v.as_str()).ok_or(anyhow::anyhow!("Missing host"))?;
            let port = args.get(2).and_then(|v| v.as_u64()).unwrap_or(22) as u16;
            let password = args.get(3).and_then(|v| v.as_str());
            let key = format!("{}@{}:{}", user, host, port);

            // 检查现有 Session 是否仍然有效
            {
                let state_lock = state.lock().unwrap();
                if let Some(sess) = state_lock.sessions.get(&key) {
                    if sess.authenticated() {
                        return Ok(Value::Boolean(true));
                    }
                }
            }

            eprintln!("Daemon: Connecting to {}", key);
            let tcp = TcpStream::connect(format!("{}:{}", host, port))?;
            tcp.set_nodelay(true)?; 
            let mut sess = Session::new()?;
            sess.set_tcp_stream(tcp);
            sess.set_timeout(10000); 
            sess.handshake().map_err(|e| anyhow::anyhow!("Handshake failed: {}", e))?;

            let mut authenticated = false;

            // 1. Try Agent
            if let Ok(mut agent) = sess.agent() {
                if let Err(e) = agent.connect() {
                    eprintln!("Daemon: SSH Agent connect failed: {}", e);
                } else {
                    if agent.list_identities().is_ok() {
                         if let Ok(identities) = agent.identities() {
                            for identity in identities {
                                if agent.userauth(user, &identity).is_ok() {
                                    eprintln!("Daemon: SSH Agent auth successful");
                                    authenticated = true;
                                    break;
                                }
                            }
                         }
                    }
                }
            }

            // 2. Try Pubkey File
            if !authenticated {
                if let Some(home) = dirs::home_dir() {
                    let ssh_dir = home.join(".ssh");
                    // 按照 OpenSSH 默认顺序尝试
                    let keys = vec!["id_ed25519", "id_rsa", "id_ecdsa", "id_dsa"]; 
                    for key_name in keys {
                        let priv_key_path = ssh_dir.join(key_name);
                        if priv_key_path.exists() {
                            eprintln!("Daemon: Trying pubkey file: {}", priv_key_path.display());
                            if sess.userauth_pubkey_file(user, None, &priv_key_path, None).is_ok() {
                                eprintln!("Daemon: Pubkey auth successful: {}", key_name);
                                authenticated = true;
                                break;
                            }
                        }
                    }
                }
            }

            // 3. Try Password
            if !authenticated {
                if let Some(pwd) = password {
                    if sess.userauth_password(user, pwd).is_ok() {
                        authenticated = true;
                    }
                }
            }

            if !authenticated {
                 return Err(anyhow::anyhow!("AUTH_FAILED: Authentication failed for {}", key));
            }

            let mut state_lock = state.lock().unwrap();
            state_lock.sessions.insert(key.clone(), sess);
            state_lock.caches.insert(key.clone(), ProjectCache { directories: HashMap::new() });
            eprintln!("Daemon: Session established for {}", key);
            Ok(Value::Boolean(true))
        },
        "fetch_file" => {
            let args = params.as_array().ok_or(anyhow::anyhow!("Invalid params"))?;
            let user = args.get(0).and_then(|v| v.as_str()).ok_or(anyhow::anyhow!("Missing user"))?;
            let host = args.get(1).and_then(|v| v.as_str()).ok_or(anyhow::anyhow!("Missing host"))?;
            let port = args.get(2).and_then(|v| v.as_u64()).unwrap_or(22) as u16;
            let path = args.get(3).and_then(|v| v.as_str()).ok_or(anyhow::anyhow!("Missing path"))?;
            let key = format!("{}@{}:{}", user, host, port);
            let state_lock = state.lock().unwrap();
            if let Some(sess) = state_lock.sessions.get(&key) {
                let mut channel = sess.channel_session()?;
                channel.exec(&format!("cat '{}'", path))?; // 加引号以支持带空格的路径
                let mut s = String::new();
                channel.read_to_string(&mut s)?;
                channel.wait_close()?;
                if channel.exit_status()? != 0 {
                    return Err(anyhow::anyhow!("Remote command failed"));
                }
                Ok(Value::String(s.into()))
            } else {
                Err(anyhow::anyhow!("NOT_CONNECTED: {}", key))
            }
        },
        "read_dir" => {
            let args = params.as_array().ok_or(anyhow::anyhow!("Invalid params"))?;
            let user = args.get(0).and_then(|v| v.as_str()).ok_or(anyhow::anyhow!("Missing user"))?;
            let host = args.get(1).and_then(|v| v.as_str()).ok_or(anyhow::anyhow!("Missing host"))?;
            let port = args.get(2).and_then(|v| v.as_u64()).unwrap_or(22) as u16;
            let path_str = args.get(3).and_then(|v| v.as_str()).ok_or(anyhow::anyhow!("Missing path"))?;
            let key = format!("{}@{}:{}", user, host, port);

            // 检查缓存
            {
                let state_lock = state.lock().unwrap();
                if let Some(cache) = state_lock.caches.get(&key) {
                    if let Some(entries) = cache.directories.get(&std::path::PathBuf::from(path_str)) {
                        let mut result = Vec::new();
                        for entry in entries {
                            let mut map = Vec::new();
                            map.push((Value::String("name".into()), Value::String(entry.name.clone().into())));
                            map.push((Value::String("type".into()), Value::String(entry.file_type.clone().into())));
                            result.push(Value::Map(map));
                        }
                        return Ok(Value::Array(result));
                    }
                }
            }

            let mut state_lock = state.lock().unwrap();
            if let Some(sess) = state_lock.sessions.get(&key) {
                let sftp = sess.sftp().map_err(|e| anyhow::anyhow!("SFTP Init failed: {}. Check if sftp-server is enabled on remote.", e))?;
                let entries = sftp.readdir(std::path::Path::new(path_str))?;
                let mut result_entries = Vec::new();
                let mut result_msgpack = Vec::new();
                for (p, stat) in entries {
                    let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("").to_string();
                    if name == "." || name == ".." { continue; }
                    let file_type = if stat.is_dir() { "directory" } else { "file" };
                    result_entries.push(DirEntry { name: name.clone(), file_type: file_type.to_string() });
                    let mut entry_map = Vec::new();
                    entry_map.push((Value::String("name".into()), Value::String(name.into())));
                    entry_map.push((Value::String("type".into()), Value::String(file_type.into())));
                    result_msgpack.push(Value::Map(entry_map));
                }
                if let Some(cache) = state_lock.caches.get_mut(&key) {
                    cache.directories.insert(std::path::PathBuf::from(path_str), result_entries);
                }
                Ok(Value::Array(result_msgpack))
            } else {
                Err(anyhow::anyhow!("NOT_CONNECTED: {}", key))
            }
        },
        "stat" => {
            let args = params.as_array().ok_or(anyhow::anyhow!("Invalid params"))?;
            let user = args.get(0).and_then(|v| v.as_str()).ok_or(anyhow::anyhow!("Missing user"))?;
            let host = args.get(1).and_then(|v| v.as_str()).ok_or(anyhow::anyhow!("Missing host"))?;
            let port = args.get(2).and_then(|v| v.as_u64()).unwrap_or(22) as u16;
            let path = args.get(3).and_then(|v| v.as_str()).ok_or(anyhow::anyhow!("Missing path"))?;
            let key = format!("{}@{}:{}", user, host, port);
            let state_lock = state.lock().unwrap();
            if let Some(sess) = state_lock.sessions.get(&key) {
                let sftp = sess.sftp().map_err(|e| anyhow::anyhow!("SFTP Init failed: {}", e))?;
                let stat = sftp.stat(std::path::Path::new(path))?;
                let file_type = if stat.is_dir() { "directory" } else { "file" };
                Ok(Value::String(file_type.into()))
            } else {
                Err(anyhow::anyhow!("NOT_CONNECTED: {}", key))
            }
        },
        _ => Err(anyhow::anyhow!("Unknown method: {}", method)),
    }
}
