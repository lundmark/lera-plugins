#!/bin/sh
# Runs lera-plugins Lua tests against the sibling lera checkout's LuaJIT.
set -eu
cd "$(dirname "$0")"
LUAJIT=../lera/external/luajit/src/luajit
[ -x "$LUAJIT" ] || { echo "missing $LUAJIT - build lera first"; exit 1; }
"$LUAJIT" tests/chat_monitor_test.lua
