#!/bin/sh
# Install ferry-bridge as a systemd user service, so it is up whenever you are
# logged in and the pane's ferry rows are simply always there.
#
#   ./install-service.sh [--root <mirror>]
#
# Writes ~/.config/systemd/user/ferry-bridge.service with absolute paths
# resolved -- a unit file cannot expand ~ or $PATH -- then enables and starts
# it. Undo with: systemctl --user disable --now ferry-bridge
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$here/target/release/ferry-bridge"
root=""

while [ $# -gt 0 ]; do
    case "$1" in
        --root) root=${2:?--root needs a path}; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ ! -x "$binary" ]; then
    echo "no binary at $binary" >&2
    echo "build it first:  cd $here && cargo build --release" >&2
    exit 1
fi

# The mirror: given, or wherever .ferry.toml is found walking up from here.
if [ -z "$root" ]; then
    dir=$here
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/.ferry.toml" ]; then root=$dir; break; fi
        dir=$(dirname "$dir")
    done
fi
if [ -z "$root" ] || [ ! -f "$root/.ferry.toml" ]; then
    echo "no .ferry.toml found. Pass --root <your mirror checkout>." >&2
    exit 1
fi
root=$(CDPATH= cd -- "$root" && pwd)

unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$unit_dir"
cat > "$unit_dir/ferry-bridge.service" <<UNIT
[Unit]
Description=ferry bridge for Lera's wizard file pane
Documentation=file://$here/README.md

[Service]
Type=simple
ExecStart=$binary --root $root
# It holds no state: if it dies, a fresh one is as good as the old one.
Restart=on-failure
RestartSec=2
# Exit 3 is "a live bridge already holds the socket" -- someone started one by
# hand. Retrying cannot help, and a unit flapping every two seconds hides the
# reason, so stop and report instead.
RestartPreventExitStatus=3

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now ferry-bridge.service

echo
echo "installed $unit_dir/ferry-bridge.service"
echo "  mirror : $root"
echo "  binary : $binary"
echo
systemctl --user --no-pager status ferry-bridge.service | head -6 || true
echo
echo "logs:   journalctl --user -u ferry-bridge -f"
echo "remove: systemctl --user disable --now ferry-bridge"
