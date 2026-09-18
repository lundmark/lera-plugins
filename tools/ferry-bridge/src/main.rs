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
use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

/// IPC_MSG_MAX_SIZE in lera's ipc.c.
const MAX_MSG: u32 = 64 * 1024;
/// A push of a large tree is slow, but not endless.
const TIMEOUT: Duration = Duration::from_secs(120);
const DEFAULT_NAME: &str = "ferry-bridge";
/// Exit code for "a live bridge already holds this socket" -- not a failure of
/// this process so much as a statement that it is not needed.
const EXIT_ALREADY_RUNNING: i32 = 3;

/// The whole of what this process will run. A verb not in here is refused, and
/// nothing is ever handed to a shell -- every call below is an argv list, so
/// there is no way to pass a command string from the pane.
const VERBS: [&str; 3] = ["pull", "push", "cc"];

fn log(msg: &str) {
    println!("[ferry-bridge] {msg}");
}

/// The command a connection currently has running, if any.
///
/// A cancel has to reach the child while it is still going, which means the
/// frame that carries it must be READ while it is still going -- so the
/// command runs on a worker thread and the connection keeps listening. This is
/// what the two share.
#[derive(Default)]
struct Job {
    child: Mutex<Option<Arc<Mutex<std::process::Child>>>>,
    cancelled: AtomicBool,
}

impl Job {
    fn set(&self, child: Arc<Mutex<std::process::Child>>) {
        *self.child.lock().unwrap() = Some(child);
    }

    fn clear(&self) {
        *self.child.lock().unwrap() = None;
    }

    /// Kill whatever is running. Returns what to tell the client.
    fn cancel(&self) -> &'static str {
        let guard = self.child.lock().unwrap();
        match guard.as_ref() {
            Some(child) => {
                self.cancelled.store(true, Ordering::SeqCst);
                let _ = child.lock().unwrap().kill();
                "cancelled"
            }
            None => "nothing running",
        }
    }
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

/// A directory operation only ever touches SOURCE.
///
/// Two reasons, and the second is the serious one:
///
///  * A mirror directory holds more than source -- .pyc, editor backups,
///    generated files -- and `ferry push <dir>` would carry all of it up.
///  * `.o` files in this tree are SAVE FILES. players/<guild>/data/*.o is live
///    game state, and help/*.o is generated help data. Pushing a stale local
///    copy of either over the running MUD is not something a click should be
///    able to do.
///
/// A single file clicked in the pane is still transferred as asked -- the pane
/// is showing it, so it was chosen deliberately. This is about what "and
/// everything under it" is allowed to mean.
const SOURCE_EXTS: [&str; 2] = ["c", "h"];

/// `ferry cc` compile-checks FILES; handed a directory it looks for
/// "<dir>.c" and fails. The documented way round it is the one the mirror's
/// own notes give: `find <area> -name '*.c' | xargs ferry cc`. Do that here, so
/// "cc this folder" means what it says.
///
/// Capped, because a cc -- or a push -- of /players is not a thing anyone
/// meant to ask for.
const CC_FILE_MAX: usize = 200;

/// Every file under `dir` whose extension is in `exts`, relative to `root`.
/// Symlinks are not followed, here or anywhere else in this process.
fn collect_files(dir: &Path, root: &Path, exts: &[&str], out: &mut Vec<String>) {
    if out.len() >= CC_FILE_MAX {
        return;
    }
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    let mut paths: Vec<PathBuf> = entries.filter_map(|e| e.ok()).map(|e| e.path()).collect();
    paths.sort();
    for path in paths {
        if out.len() >= CC_FILE_MAX {
            return;
        }
        // Do not follow a symlink out of the mirror, here or anywhere else.
        let meta = match fs::symlink_metadata(&path) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if meta.file_type().is_symlink() {
            continue;
        }
        if meta.is_dir() {
            collect_files(&path, root, exts, out);
        } else {
            let ext = path
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| e.to_ascii_lowercase());
            let wanted = ext.map(|e| exts.contains(&e.as_str())).unwrap_or(false);
            if wanted {
                if let Ok(rel) = path.strip_prefix(root) {
                    out.push(rel.to_string_lossy().into_owned());
                }
            }
        }
    }
}

/// Run ferry, handing every line of its stdout to `on_line` as it arrives.
///
/// Streaming rather than collecting, because ferry reports one line per file
/// and on a directory those lines ARE the progress: waiting for the process to
/// end means silence for as long as the transfer takes, then everything at
/// once.
fn run_ferry_many(
    root: &Path,
    verb: &str,
    relatives: &[String],
    job: &Job,
    on_line: &mut dyn FnMut(&str),
) -> (bool, String, i32) {
    let spawned = Command::new("ferry")
        .arg(verb)
        .args(relatives)
        .current_dir(root)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();

    let mut child = match spawned {
        Ok(c) => c,
        Err(e) if e.kind() == ErrorKind::NotFound => {
            return (false, "ferry is not on PATH".into(), -1)
        }
        Err(e) => return (false, format!("could not run ferry: {e}"), -1),
    };

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let child = Arc::new(Mutex::new(child));
    job.set(Arc::clone(&child));

    // std has no wait-with-timeout, so a watchdog kills the child instead.
    // Without it a hung FTP connection would hold this thread forever.
    let timed_out = Arc::new(Mutex::new(false));
    {
        let child = Arc::clone(&child);
        let timed_out = Arc::clone(&timed_out);
        thread::spawn(move || {
            let deadline = std::time::Instant::now() + TIMEOUT;
            loop {
                thread::sleep(Duration::from_millis(200));
                let mut guard = match child.lock() {
                    Ok(g) => g,
                    Err(_) => return,
                };
                match guard.try_wait() {
                    Ok(Some(_)) => return,
                    Ok(None) => {}
                    Err(_) => return,
                }
                if std::time::Instant::now() >= deadline {
                    *timed_out.lock().unwrap() = true;
                    let _ = guard.kill();
                    return;
                }
            }
        });
    }

    // stderr on its own thread: ferry writes diagnostics there, and a full
    // pipe with nobody reading it would block the child.
    let stderr_thread = thread::spawn(move || {
        let mut text = String::new();
        if let Some(mut handle) = stderr {
            let _ = handle.read_to_string(&mut text);
        }
        text
    });

    let mut collected = String::new();
    if let Some(handle) = stdout {
        for line in BufReader::new(handle).lines() {
            let line = match line {
                Ok(l) => l,
                Err(_) => break,
            };
            on_line(&line);
            collected.push_str(&line);
            collected.push('\n');
        }
    }

    let status = match child.lock().unwrap().wait() {
        Ok(s) => s,
        Err(e) => return (false, format!("ferry failed: {e}"), -1),
    };
    let errors = stderr_thread.join().unwrap_or_default();
    collected.push_str(&errors);

    job.clear();

    if job.cancelled.load(Ordering::SeqCst) {
        return (false, format!("ferry {verb} cancelled"), -1);
    }
    if *timed_out.lock().unwrap() {
        return (
            false,
            format!("ferry {verb} timed out after {}s", TIMEOUT.as_secs()),
            -1,
        );
    }
    (
        status.success(),
        collected.trim().to_string(),
        status.code().unwrap_or(-1),
    )
}

/// How many files a pull or push is about to touch.
///
/// ferry's own --dry-run answers it: one line per file it would move. Only
/// worth asking for a DIRECTORY -- a single file is one of one -- and only so
/// the client can show a percentage rather than a rising count with no end in
/// sight.
fn count_work(root: &Path, verb: &str, relative: &str, job: &Job) -> Option<usize> {
    let args = vec!["--dry-run".to_string(), relative.to_string()];
    let mut lines = 0usize;
    let (_ok, _out, _status) = run_ferry_many(root, verb, &args, job, &mut |line| {
        if line.starts_with("would ") {
            lines += 1;
        }
    });
    if lines > 0 {
        Some(lines)
    } else {
        None
    }
}

fn run_ferry(
    root: &Path,
    verb: &str,
    relative: &str,
    job: &Job,
    on_progress: &mut dyn FnMut(usize, Option<usize>, &str),
) -> (bool, String, i32) {
    let full = root.join(relative);

    // cc takes files, and a push of a directory is restricted to source (see
    // SOURCE_EXTS). Both come down to the same thing: build the list here and
    // hand ferry explicit paths.
    if full.is_dir() && (verb == "cc" || verb == "push") {
        let exts: &[&str] = if verb == "cc" { &["c"] } else { &SOURCE_EXTS };
        let mut files = Vec::new();
        collect_files(&full, root, exts, &mut files);
        if files.is_empty() {
            return (
                false,
                format!("no {} files under {relative}", exts.join("/.")),
                -1,
            );
        }
        let capped = files.len() >= CC_FILE_MAX;
        // The total is known exactly here: it is the list just built. No
        // --dry-run pre-pass needed.
        let total = Some(files.len());
        let mut done = 0usize;
        let (ok, mut output, status) = run_ferry_many(root, verb, &files, job, &mut |line| {
            done += 1;
            on_progress(done, total, line);
        });
        if capped {
            output.push_str(&format!(
                "\n(stopped at {CC_FILE_MAX} files -- narrow the directory for the rest)"
            ));
        }
        return (ok, output, status);
    }

    // What is left is a pull, or a single file. A directory pull stays ferry's
    // own recursion: the files worth having may not exist locally yet, which
    // is the whole point, so there is no local list to filter. It writes only
    // into the mirror, so the stakes are the other way round from a push.
    let total = if full.is_dir() {
        count_work(root, verb, relative, job)
    } else {
        Some(1)
    };

    let mut done = 0usize;
    let args = [relative.to_string()];
    run_ferry_many(root, verb, &args, job, &mut |line| {
        done += 1;
        on_progress(done, total, line);
    })
}

fn handle(
    root: &Path,
    request: &Value,
    job: &Job,
    on_progress: &mut dyn FnMut(usize, Option<usize>, &str),
) -> Value {
    let op = request.get("op").and_then(Value::as_str).unwrap_or("");
    if !VERBS.contains(&op) {
        return json!({ "ok": false, "output": format!("unknown op '{op}'") });
    }

    let path = request.get("path").and_then(Value::as_str).unwrap_or("");
    let relative = match local_path(root, path) {
        Ok(r) => r,
        Err(why) => return json!({ "ok": false, "op": op, "output": why }),
    };

    let (ok, output, status) = run_ferry(root, op, &relative, job, on_progress);
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

/// One frame at a time, on the CONNECTION thread. Work runs on a worker
/// thread so this one stays free to read -- which is the only way a cancel can
/// arrive while a command is still running.
///
/// One job at a time per connection: two overlapping transfers would interleave
/// their progress and make "cancel" ambiguous.
fn serve_peer(root: PathBuf, stream: UnixStream) {
    let reader = stream;
    let writer = match reader.try_clone() {
        Ok(w) => Arc::new(Mutex::new(w)),
        Err(_) => return,
    };
    let job = Arc::new(Job::default());
    let busy = Arc::new(AtomicBool::new(false));
    let mut peer = String::from("?");
    let mut reader = reader;

    while let Some(header) = read_exactly(&mut reader, 4) {
        let length = u32::from_be_bytes([header[0], header[1], header[2], header[3]]);
        if length == 0 || length > MAX_MSG {
            log(&format!("refusing a {length}-byte frame from {peer}"));
            break;
        }
        let body = match read_exactly(&mut reader, length as usize) {
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

        let op = request
            .get("op")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let id = request.get("id").cloned();

        // Cancel is answered HERE, on the reading thread, while the worker is
        // still inside ferry.
        if op == "cancel" {
            let what = job.cancel();
            log(&format!("{peer} cancel -> {what}"));
            let mut reply = json!({ "ok": true, "op": "cancel", "output": what });
            if let Some(id) = id {
                reply["id"] = id;
            }
            let mut w = writer.lock().unwrap();
            if !send(&mut w, &reply) {
                break;
            }
            continue;
        }

        if busy.swap(true, Ordering::SeqCst) {
            let mut reply = json!({
                "ok": false, "op": op,
                "output": "another ferry command is still running"
            });
            if let Some(id) = id {
                reply["id"] = id;
            }
            let mut w = writer.lock().unwrap();
            if !send(&mut w, &reply) {
                break;
            }
            continue;
        }

        let root = root.clone();
        let writer = Arc::clone(&writer);
        let job = Arc::clone(&job);
        let busy = Arc::clone(&busy);
        thread::spawn(move || {
            job.cancelled.store(false, Ordering::SeqCst);

            // Progress goes out on the same socket, one frame per file, while
            // the command is still running.
            let mut reply = {
                let writer = Arc::clone(&writer);
                let id = id.clone();
                let op = op.clone();
                handle(&root, &request, &job, &mut |done, total, line| {
                    let mut frame = json!({
                        "progress": true, "op": op, "done": done, "line": line,
                    });
                    if let Some(total) = total {
                        frame["total"] = json!(total);
                    }
                    if let Some(id) = &id {
                        frame["id"] = id.clone();
                    }
                    let mut w = writer.lock().unwrap();
                    let _ = send(&mut w, &frame);
                })
            };

            if let Some(id) = id {
                reply["id"] = id;
            }
            {
                let mut w = writer.lock().unwrap();
                let _ = send(&mut w, &reply);
            }
            job.clear();
            busy.store(false, Ordering::SeqCst);
        });
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
                // Its own exit code, so a supervisor can tell "someone else is
                // already doing this job" apart from "this failed". The
                // systemd unit maps it to RestartPreventExitStatus: retrying
                // cannot help, and a flapping unit hides the reason.
                std::process::exit(EXIT_ALREADY_RUNNING);
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

// ---- tests -----------------------------------------------------------------
//
// The two functions worth testing are the two that decide what this process is
// allowed to touch. Everything else is plumbing around a subprocess.

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("ferry-bridge-test-{name}"));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir.canonicalize().unwrap()
    }

    #[test]
    fn rejects_paths_that_leave_the_mirror() {
        let root = scratch("escape");
        assert!(local_path(&root, "/../etc/passwd").is_err());
        assert!(local_path(&root, "/players/../../etc/passwd").is_err());
        assert!(local_path(&root, "players/x.c").is_err(), "must be absolute");
        assert!(local_path(&root, "/").is_err(), "the root is not a file");
        assert!(local_path(&root, "/x\0y.c").is_err(), "no nulls");
    }

    #[test]
    fn accepts_a_path_that_does_not_exist_yet() {
        // A pull targets a file the mirror has never seen; refusing it because
        // it is missing would make pull useless for exactly the case it is for.
        let root = scratch("missing");
        fs::create_dir_all(root.join("players/shaman/cmd")).unwrap();
        assert_eq!(
            local_path(&root, "/players/shaman/cmd/brand_new.c").unwrap(),
            "players/shaman/cmd/brand_new.c"
        );
    }

    #[test]
    fn refuses_a_directory_symlinked_out_of_the_mirror() {
        let root = scratch("symlink");
        let outside = scratch("symlink-outside");
        fs::write(outside.join("secret.c"), "x").unwrap();
        std::os::unix::fs::symlink(&outside, root.join("escape")).unwrap();
        assert!(local_path(&root, "/escape/secret.c").is_err());
    }

    #[test]
    fn a_directory_push_takes_source_and_nothing_else() {
        let root = scratch("collect");
        let area = root.join("players/shaman");
        fs::create_dir_all(area.join("data")).unwrap();
        fs::create_dir_all(area.join("__pycache__")).unwrap();
        for (path, _) in [
            ("shgather.c", ()),
            ("herbs.h", ()),
            ("notes.txt", ()),
            ("shgather.c.bak", ()),
        ] {
            fs::write(area.join(path), "x").unwrap();
        }
        // The dangerous ones: .o here is live save data, not build output.
        fs::write(area.join("data/gather_daemon.o"), "x").unwrap();
        fs::write(area.join("__pycache__/t.pyc"), "x").unwrap();

        let mut found = Vec::new();
        collect_files(&area, &root, &SOURCE_EXTS, &mut found);
        found.sort();
        assert_eq!(
            found,
            vec![
                "players/shaman/herbs.h".to_string(),
                "players/shaman/shgather.c".to_string(),
            ],
            "a directory push must not carry .o save files, .pyc or backups"
        );
    }

    #[test]
    fn a_directory_cc_takes_only_c_files() {
        let root = scratch("cc");
        let area = root.join("area");
        fs::create_dir_all(&area).unwrap();
        fs::write(area.join("room.c"), "x").unwrap();
        fs::write(area.join("defs.h"), "x").unwrap();

        let mut found = Vec::new();
        collect_files(&area, &root, &["c"], &mut found);
        assert_eq!(found, vec!["area/room.c".to_string()]);
    }

    #[test]
    fn collection_does_not_follow_symlinks() {
        let root = scratch("nofollow");
        let area = root.join("area");
        let outside = scratch("nofollow-outside");
        fs::create_dir_all(&area).unwrap();
        fs::write(outside.join("elsewhere.c"), "x").unwrap();
        std::os::unix::fs::symlink(&outside, area.join("link")).unwrap();

        let mut found = Vec::new();
        collect_files(&area, &root, &SOURCE_EXTS, &mut found);
        assert!(found.is_empty(), "walked through a symlink: {found:?}");
    }
}
