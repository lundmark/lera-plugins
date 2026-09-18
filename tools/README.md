# tools/ferry-bridge

Runs [ferry](https://github.com/skuggo/ferry) on behalf of the wizard file
pane, so `pull` / `push` / `cc` are a click in Lera rather than a trip to a
terminal.

It exists because a Lera plugin cannot do it directly: the sandbox grants four
`os` functions and no `io`, no `os.execute` (`lera/src/script/plugin.c`). What
it does have is `ipc`, a Unix-domain socket transport -- and this is the
process on the other end of it.

```
Files pane  --ipc-->  ferry-bridge  --exec-->  ferry pull players/x/foo.c
```

## Running it

From your mirror checkout, or pointed at one:

```sh
cd ~/3S && /path/to/ferry-bridge
ferry-bridge --root ~/3S
LERA_FERRY_ROOT=~/3S ferry-bridge
```

Rust rather than a script because ferry is Rust and this sits next to it: one
static binary, no runtime to have installed. It is NOT part of ferry -- ferry
is Simon's, and a socket server for one client does not belong in it.

It uses **your existing ferry setup**: ferry resolves `.ferry.toml` from the
working directory, so the bridge just runs it there. No second config, and no
credentials pass through Lera. With no `--root` it walks up from the working
directory looking for `.ferry.toml`, and refuses to start rather than guess.

Rust, one dependency (serde_json for the wire format). Build it once:

```sh
cd tools/ferry-bridge && cargo build --release
# target/release/ferry-bridge
```

## In the pane

Right-click a file. The ferry rows appear **only when a bridge is listening**
(`ipc.list()` reports the socket); without one the menu is exactly the MUD
commands, so the plugin ships to everyone unchanged. `push` asks first -- it
overwrites what is on the MUD with what is on disk.

## What it will and will not do

* Three verbs: `pull`, `push`, `cc`, each with one path. There is no way to
  pass a command string -- this process holds a shell and the pane does not
  get to use it.
* Every path is resolved and must land inside the mirror root; `..` and
  symlinks pointing out are refused. The path arrives from a GMCP listing by
  way of a mouse click, so the bridge is the thing that must not trust it.
* The socket is `~/.lera/ipc/ferry-bridge.sock`, mode 0600.
* A stale socket from a crash is probed before being replaced, so a live
  bridge is never yanked out from under a running session.
