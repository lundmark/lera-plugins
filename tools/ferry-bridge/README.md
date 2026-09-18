# ferry-bridge

Runs [ferry](https://github.com/lundmark/ferry) for Lera's wizard file pane, so
`pull` / `push` / `cc` on the file you are looking at is a click instead of a
trip to a terminal.

It exists because a Lera plugin cannot do any of that itself. The plugin
sandbox grants four `os` functions and no `io`, no `os.execute`
(`lera/src/script/plugin.c`), and plugins are Lua only — the loader resolves
`<name>.lua` and there is no native ABI, so it cannot be pushed down into a
compiled plugin either. What the sandbox *does* have is `ipc`, a Unix-domain
socket transport. This is the process on the other end of it.

```
Files pane  --ipc-->  ferry-bridge  --exec-->  ferry pull players/x/foo.c
```

It is **not** part of ferry, and deliberately so: ferry is its own tool, and a
socket server for one client does not belong in it.

## Build

```sh
cd tools/ferry-bridge
cargo build --release          # target/release/ferry-bridge
```

Rust, one dependency (`serde_json`, for the wire format).

## Run

```sh
ferry-bridge --root ~/3S                  # from anywhere
cd ~/3S && ferry-bridge                   # or from the mirror itself
LERA_FERRY_ROOT=~/3S ferry-bridge         # or by environment
```

It stays in the foreground and logs what it does; Ctrl-C stops it and removes
its socket. Lera does not need restarting afterwards — the pane checks for a
bridge each time a file menu opens.

It uses **the ferry setup you already have**: ferry resolves `.ferry.toml` from
its working directory, so the bridge simply runs it in the mirror. There is no
second config and no credential ever passes through Lera. Given no `--root` it
walks up from the working directory looking for `.ferry.toml`, and refuses to
start rather than guess.

## Autostart (systemd user service)

```sh
./install-service.sh              # writes, enables and starts the unit
./install-service.sh --root ~/3S  # if your mirror is elsewhere
```

That installs `~/.config/systemd/user/ferry-bridge.service` with absolute paths
resolved, then `systemctl --user enable --now ferry-bridge`.

```sh
systemctl --user status ferry-bridge     # is it up?
journalctl --user -u ferry-bridge -f     # what has it run?
systemctl --user disable --now ferry-bridge   # stop and forget it
```

A user service runs from login to logout. If you want it up while you are not
logged in (a headless box you ssh into), enable lingering once:
`loginctl enable-linger $USER`.

## In the pane

Right-click a file. The ferry rows are appended **only when a bridge is
listening** — without one the menu is exactly the MUD commands, so the plugin
ships to everyone unchanged. The plugin also says which it is, on load and from
`/wiz`:

```
[wizard] ferry: bridge ready -- pull/push/cc are on the file menu
[wizard] ferry: no bridge (start tools/ferry-bridge to get pull/push/cc)
```

`push` asks first: it overwrites what is on the MUD with what is on disk.

## What it will and will not do

This process holds a shell and the pane does not get to use it.

* **Three verbs**: `pull`, `push`, `cc`, each with exactly one path. There is no
  way to pass a command string; every call is an argv list.
* **Paths must land inside the mirror.** `..` is refused outright, and since a
  `pull` targets a file that may not exist yet, the nearest *existing* ancestor
  is canonicalised and required to be inside the root — which is what catches a
  directory symlinked out of the mirror.
* **Socket** at `~/.lera/ipc/<name>.sock`, mode 0600. A stale socket left by a
  crash is probed before being replaced, so a live bridge is never yanked out
  from under a running session.
* **ferry is given 120 seconds** per command, waited for on its own thread, so a
  hung FTP connection cannot hold a bridge thread forever.

## Protocol

Lera's IPC framing (`lera/src/ipc/ipc.c`): each message is a 4-byte big-endian
length followed by JSON, and a connecting peer introduces itself with
`{"_ipc_name": "..."}`.

```
-> {"id": 7, "op": "pull", "path": "/players/shaman/cmd/shgather.c"}
<- {"id": 7, "ok": true, "op": "pull", "output": "pulled ...", "status": 0}
```

`id` is echoed back so two commands in flight cannot be confused for one
another. Anything the bridge refuses comes back as `{"ok": false, "output":
"<why>"}` rather than as silence.
