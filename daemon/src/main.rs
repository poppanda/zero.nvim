use rmpv::{Value, decode, encode};
use std::io::{Write, Read};
use std::sync::{Arc, Mutex};
use std::net::TcpStream;
use ssh2::Session;
use std::collections::HashMap;

struct DaemonState {
    sessions: HashMap<String, Session>,
}

impl DaemonState {
    fn new() -> Self {
        Self { sessions: HashMap::new() }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Minimal startup log
    // eprintln!("Daemon: Starting up..."); 
    let state = Arc::new(Mutex::new(DaemonState::new()));

    let stdin = std::io::stdin();
    let mut reader = stdin.lock();
    let mut stdout = std::io::stdout();

    loop {
        let msg = match decode::read_value(&mut reader) {
            Ok(v) => v,
            Err(_) => break, // EOF or error (silent exit)
        };

        if let Value::Array(ref args) = msg {
            if args.len() == 4 {
                let msg_type = args[0].as_u64();
                let msg_id = args[1].as_u64();
                let method_val = &args[2];
                let params = &args[3];

                if let (Some(0), Some(id)) = (msg_type, msg_id) {
                    if let Some(method) = method_val.as_str() {
                        // eprintln!("Daemon: Processing method '{}'", method);
                        let response_res = handle_request(method, params, state.clone());
                        
                        let (err, res) = match response_res {
                            Ok(val) => (Value::Nil, val),
                            Err(e) => {
                                eprintln!("Daemon: Error in '{}': {}", method, e);
                                (Value::String(format!("{}", e).into()), Value::Nil)
                            },
                        };
                        
                        let response = Value::Array(vec![
                            Value::Integer(1.into()),
                            Value::Integer(id.into()),
                            err,
                            res,
                        ]);

                        encode::write_value(&mut stdout, &response)?;
                        stdout.flush()?;
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
            
            // Check if already connected (Robustness check)
            {
                let state_lock = state.lock().unwrap();
                if state_lock.sessions.contains_key(&key) {
                     return Ok(Value::Boolean(true));
                }
            }

            eprintln!("Daemon: Connecting to {}", key);
            
            // 1. TCP Connect
            let tcp = TcpStream::connect(format!("{}:{}", host, port))?;
            
            // High Performance: Disable Nagle's algorithm
            tcp.set_nodelay(true)?; 
            
            // 2. SSH Session Init
            let mut sess = Session::new().map_err(|e| anyhow::anyhow!("Session init failed: {}", e))?;
            sess.set_tcp_stream(tcp);
            
            // Set reasonable timeout (10s) to avoid hanging indefinitely
            sess.set_timeout(10000); 

            // 3. Handshake
            sess.handshake().map_err(|e| anyhow::anyhow!("Handshake failed: {}", e))?;

            let mut authenticated = false;

            // 4. Auth: Agent (Priority)
            if let Ok(mut agent) = sess.agent() {
                if agent.connect().is_ok() {
                    if agent.list_identities().is_ok() {
                         if let Ok(identities) = agent.identities() {
                            for identity in identities {
                                if agent.userauth(user, &identity).is_ok() {
                                    authenticated = true;
                                    break;
                                }
                            }
                         }
                    }
                }
            }

            // 5. Auth: Pubkey File
            if !authenticated {
                if let Some(home) = dirs::home_dir() {
                    let ssh_dir = home.join(".ssh");
                    let keys = vec!["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"]; 
                    
                    for key_name in keys {
                        let priv_key_path = ssh_dir.join(key_name);
                        
                        if priv_key_path.exists() {
                            if sess.userauth_pubkey_file(user, None, &priv_key_path, None).is_ok() {
                                authenticated = true;
                                break;
                            }
                        }
                    }
                }
            }

            // 6. Auth: Password
            if !authenticated {
                if let Some(pwd) = password {
                    if sess.userauth_password(user, pwd).is_ok() {
                        authenticated = true;
                    }
                }
            }

            if !authenticated {
                 return Err(anyhow::anyhow!("Authentication failed."));
            }

            let mut state_lock = state.lock().unwrap();
            state_lock.sessions.insert(key.clone(), sess);
            eprintln!("Daemon: Connected to {}", key);

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
                channel.exec(&format!("cat {}", path))?;
                
                let mut s = String::new();
                channel.read_to_string(&mut s)?;
                channel.wait_close()?;
                
                if channel.exit_status()? != 0 {
                    return Err(anyhow::anyhow!("Remote command failed"));
                }
                
                Ok(Value::String(s.into()))
            } else {
                Err(anyhow::anyhow!("Not connected to {}", key))
            }
        },
        _ => Err(anyhow::anyhow!("Unknown method: {}", method)),
    }
}
