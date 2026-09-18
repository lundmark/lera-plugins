//! ferry-bridge -- run ferry on behalf of Lera's wizard file pane.
//!
//! A Lera plugin cannot reach the disk or the network: its sandbox grants four
//! `os` functions and no `io`, no `os.execute` (lera/src/script/plugin.c), and
//! plugins are Lua only -- the loader resolves `<name>.lua` and there is no
//! native ABI. What the sandbox does have is `ipc`, a Unix-domain socket
//! transport, and this is the process on the other end of it: the one thing
//! with a shell.
//!
//!     Files pane  --ipc-->  ferry-bridge  --exec-->  ferry pull players/x/foo.c
//!
//! Run it from your mirror checkout, or point it at one:
//!
//!     cd ~/3S && ferry-bridge
//!     ferry-bridge --root ~/3S
//!     LERA_FERRY_ROOT=~/3S ferry-bridge
//!
//! It reads YOUR existing ferry setup rather than having one of its own: ferry
//! resolves .ferry.toml from the working directory, so the bridge runs it
//! there. No second config, and no credentials pass through Lera.
//!
//! Protocol (lera/src/ipc/ipc.c): each message is a 4-byte big-endian length
//! followed by JSON. A connecting peer introduces itself with `_ipc_name`.
//!
//!     -> {"id": 7, "op": "pull", "path": "/players/shaman/cmd/shgather.c"}
//!     <- {"id": 7, "ok": true, "op": "pull", "output": "pulled ...", "status": 0}

use serde_json::{json, Value};
use std::env;
use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

/// IPC_MSG_MAX_SIZE in lera's ipc.c.
const MAX_MSG: u32 = 64 * 1024;
/// A push of a large tree is slow, but not endless.
const TIMEOUT: Duration = Duration::from_secs(120);
const DEFAULT_NAME: &str = "ferry-bridge";

/// The whole of what this process will run. A verb not in here is refused, and
/// nothing is ever handed to a shell -- every call below is an argv list, so
/// there is no way to pass a command string from the pane.
const VERBS: [&str; 3] = ["pull", "push", "cc"];

fn log(msg: &str) {
    println!("[ferry-bridge] {msg}");
}

// ---- the mirror -------------------------------------------------------------

/// The mirror checkout: an explicit path, the env var, or the first ancestor of
/// the working directory holding a `.ferry.toml` -- the same file ferry itself
/// resolves.
fn find_root(explicit: Option<String>) -> Result<PathBuf, String> {
    // Told where to look: that place or nothing. Guessing past an explicit
    // answer would be worse than refusing.
    if let Some(candidate) = explicit
        .or_else(|| env::var("LERA_FERRY_ROOT").ok())
        .map(PathBuf::from)
    {
        if candidate.join(".ferry.toml").is_file() {
            return candidate
                .canonicalize()
                .map_err(|e| format!("{}: {e}", candidate.display()));
        }
        return Err(format!("no .ferry.toml in {}", candidate.display()));
    }

    let here = env::current_dir().map_err(|e| e.to_string())?;
    for dir in here.ancestors() {
        if dir.join(".ferry.toml").is_file() {
            return dir.canonicalize().map_err(|e| e.to_string());
        }
    }
    Err("no .ferry.toml here or above. Run this from your mirror checkout, \
         or pass --root / set LERA_FERRY_ROOT."
        .into())
}

/// A MUD path as the pane knows it -> a path inside the mirror.
///
/// The mirror mirrors the MUD tree (remote_root = "/"), so this is mostly just
/// the leading slash. The checking is the point: the path arrives from a GMCP
/// listing by way of a mouse click, and this process is the one that must not
/// trust it.
///
/// `canonicalize` alone will not do, because a pull targets a file that may not
/// exist yet. So: reject `..` outright, then canonicalize the nearest ancestor
/// that DOES exist and require that to be inside the root -- which is what
/// catches a directory symlinked out of the mirror.
fn local_path(root: &Path, mud_path: &str) -> Result<String, String> {
    if !mud_path.starts_with('/') {
        return Err("path must be absolute".into());
    }
    if mud_path.contains('\0') {
        return Err("path contains a null".into());
    }

    let relative = mud_path.trim_start_matches('/');
    if relative.is_empty() {
        return Err("path is the root".into());
    }

    let candidate = Path::new(relative);
    for component in candidate.components() {
        match component {
            Component::Normal(_) => {}
            Component::CurDir => {}
            _ => return Err("path resolves outside the mirror".into()),
        }
    }

    let mut probe = root.join(candidate);
    while !probe.exists() {
        match probe.parent() {
            Some(parent) => probe = parent.to_path_buf(),
            None => return Err("path resolves outside the mirror".into()),
        }
    }
    let real = probe
        .canonicalize()
        .map_err(|_| "path resolves outside the mirror".to_string())?;
    if real != root && !real.starts_with(root) {
        return Err("path resolves outside the mirror".into());
    }

    Ok(relative.to_string())
}

// ---- running ferry ----------------------------------------------------------

fn run_ferry(root: &Path, verb: &str, relative: &str) -> (bool, String, i32) {
    let child = Command::new("ferry")
        .arg(verb)
        .arg(relative)
        .current_dir(root)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();

    let child = match child {
        Ok(c) => c,
        Err(e) if e.kind() == ErrorKind::NotFound => {
            return (false, "ferry is not on PATH".into(), -1)
        }
        Err(e) => return (false, format!("could not run ferry: {e}"), -1),
    };

    // std has no wait-with-timeout, so the wait happens on its own thread and
    // this one gives up after TIMEOUT and kills the child. Without it a hung
    // FTP connection would hold the whole bridge thread forever.
    let (tx, rx) = mpsc::channel();
    let handle = thread::spawn(move || {
        let out = child.wait_with_output();
        let _ = tx.send(out);
    });

    match rx.recv_timeout(TIMEOUT) {
        Ok(Ok(out)) => {
            let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
            text.push_str(&String::from_utf8_lossy(&out.stderr));
            let status = out.status.code().unwrap_or(-1);
            let _ = handle.join();
            (out.status.success(), text.trim().to_string(), status)
        }
        Ok(Err(e)) => (false, format!("ferry failed: {e}"), -1),
        Err(_) => (
            false,
            format!("ferry {verb} timed out after {}s", TIMEOUT.as_secs()),
            -1,
        ),
    }
}

fn handle(root: &Path, request: &Value) -> Value {
    let op = request.get("op").and_then(Value::as_str).unwrap_or("");
    if !VERBS.contains(&op) {
        return json!({ "ok": false, "output": format!("unknown op '{op}'") });
    }

    let path = request.get("path").and_then(Value::as_str).unwrap_or("");
    let relative = match local_path(root, path) {
        Ok(r) => r,
        Err(why) => return json!({ "ok": false, "op": op, "output": why }),
    };

    let (ok, output, status) = run_ferry(root, op, &relative);
    log(&format!(
        "{op} {relative} -> {}",
        if ok { "ok" } else { "FAILED" }
    ));
    json!({ "ok": ok, "op": op, "path": path, "output": output, "status": status })
}

// ---- the wire ---------------------------------------------------------------

fn read_exactly(stream: &mut UnixStream, count: usize) -> Option<Vec<u8>> {
    let mut buf = vec![0u8; count];
    match stream.read_exact(&mut buf) {
        Ok(()) => Some(buf),
        Err(_) => None,
    }
}

fn send(stream: &mut UnixStream, payload: &Value) -> bool {
    let body = payload.to_string();
    let len = (body.len() as u32).to_be_bytes();
    stream.write_all(&len).is_ok() && stream.write_all(body.as_bytes()).is_ok()
}

fn serve_peer(root: PathBuf, mut stream: UnixStream) {
    let mut peer = String::from("?");
    while let Some(header) = read_exactly(&mut stream, 4) {
        let length = u32::from_be_bytes([header[0], header[1], header[2], header[3]]);
        if length == 0 || length > MAX_MSG {
            log(&format!("refusing a {length}-byte frame from {peer}"));
            break;
        }
        let body = match read_exactly(&mut stream, length as usize) {
            Some(b) => b,
            None => break,
        };

        let request: Value = match serde_json::from_slice(&body) {
            Ok(v) => v,
            Err(_) => {
                log(&format!("unparseable frame from {peer}"));
                continue;
            }
        };
        if !request.is_object() {
            continue;
        }

        // The introduction lera sends on connect, not a request.
        if let Some(name) = request.get("_ipc_name").and_then(Value::as_str) {
            peer = name.chars().take(64).collect();
            log(&format!("{peer} connected"));
            continue;
        }

        let mut reply = handle(&root, &request);
        if let Some(id) = request.get("id") {
            reply["id"] = id.clone();
        }
        if !send(&mut stream, &reply) {
            break;
        }
    }
    log(&format!("{peer} disconnected"));
}

// ---- startup ----------------------------------------------------------------

struct Args {
    root: Option<String>,
    name: String,
}

fn parse_args() -> Result<Args, String> {
    let mut args = Args {
        root: None,
        name: DEFAULT_NAME.to_string(),
    };
    let mut argv = env::args().skip(1);
    while let Some(arg) = argv.next() {
        match arg.as_str() {
            "--root" => {
                args.root = Some(argv.next().ok_or("--root needs a path")?);
            }
            "--name" => {
                args.name = argv.next().ok_or("--name needs a name")?;
            }
            "-h" | "--help" => {
                println!(
                    "ferry-bridge [--root <mirror>] [--name <ipc name>]\n\n\
                     Runs ferry for Lera's wizard file pane. Start it in your\n\
                     mirror checkout; the socket is ~/.lera/ipc/<name>.sock."
                );
                std::process::exit(0);
            }
            other => return Err(format!("unknown argument {other}")),
        }
    }
    Ok(args)
}

fn socket_path(name: &str) -> Result<PathBuf, String> {
    let home = env::var("HOME").map_err(|_| "HOME is not set".to_string())?;
    Ok(PathBuf::from(home)
        .join(".lera")
        .join("ipc")
        .join(format!("{name}.sock")))
}

fn main() {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("[ferry-bridge] {e}");
            std::process::exit(2);
        }
    };

    let root = match find_root(args.root) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[ferry-bridge] {e}");
            std::process::exit(2);
        }
    };

    let path = match socket_path(&args.name) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("[ferry-bridge] {e}");
            std::process::exit(2);
        }
    };
    if let Some(dir) = path.parent() {
        let _ = fs::create_dir_all(dir);
    }

    // A socket left behind by a crash would otherwise make the plugin think a
    // bridge is listening. Probe before removing, so a live one is never
    // yanked out from under a running session.
    if path.exists() {
        match UnixStream::connect(&path) {
            Ok(_) => {
                eprintln!(
                    "[ferry-bridge] a bridge is already listening on {}",
                    path.display()
                );
                std::process::exit(1);
            }
            Err(_) => {
                let _ = fs::remove_file(&path);
            }
        }
    }

    let listener = match UnixListener::bind(&path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("[ferry-bridge] cannot bind {}: {e}", path.display());
            std::process::exit(1);
        }
    };
    // This process runs commands; keep its socket to its owner.
    let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));

    log(&format!("mirror: {}", root.display()));
    log(&format!(
        "listening on {} (verbs: {})",
        path.display(),
        VERBS.join(", ")
    ));

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let root = root.clone();
                thread::spawn(move || serve_peer(root, stream));
            }
            Err(e) => log(&format!("accept failed: {e}")),
        }
    }
}
