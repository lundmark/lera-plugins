-- ferry, from the file pane, through a bridge process.
--
-- The sandbox has no disk and no shell -- four os functions and nothing else
-- (lera/src/script/plugin.c), and plugins are Lua only: the loader resolves
-- <name>.lua and there is no native ABI, so this cannot be pushed down into a
-- compiled plugin either. It can open a Unix socket, though, and the process
-- on the other end is ferry-bridge -- a small Rust binary that runs ferry in
-- a mirror checkout and sends back what happened:
--
--     https://github.com/skuggo/ferry-bridge
--
-- It lives in its own repository rather than here: it is a daemon that runs
-- shell commands, which is a different kind of thing from a client plugin,
-- and nobody should have to take it to get the rest of this.
--
-- Everything here is best-effort and optional. A wizard with no bridge running
-- sees no ferry entries at all (see available()), which is what lets this ship
-- to everyone rather than only to people who set it up.

local M = {}

-- The bridge's IPC name; its socket is ~/.lera/ipc/<name>.sock.
local BRIDGE = "ferry-bridge"

-- Our own name on the wire. ipc.init() is a one-per-session call, so a profile
-- that already named the session keeps its name and this is only a fallback.
local SELF = "lera-wizard"

-- ipc.send() and ipc.disconnect() take the peer INDEX that ipc.connect()
-- returned, not its name (lera/src/lua/api_ipc.c: luaL_checkinteger), so the
-- index is what gets kept.
-- Lines already shown as progress, so the closing summary does not repeat
-- them. Cleared when a command finishes.
local seen_lines = {}
-- What is in flight, so the pane can offer to abort it and refuse to start a
-- second one on top.
local running = nil
local peer_idx = nil
local started = false
local next_id = 1
local waiting = {}      -- id -> callback

local function note(text)
  print("[ferry] " .. text)
end

-- Declared before start(), which registers it. A `local` is not in scope
-- above its own declaration, so with the definition further down start() was
-- registering the GLOBAL `on_message` -- nil. ipc accepted it, no callback was
-- ever installed, and every reply from the bridge was dropped: commands ran,
-- and the client never said they had finished.
local on_message

-- Our own IPC endpoint. ipc.list() raises unless IPC has been initialised
-- ("IPC not initialized"), so this has to happen before anything can even ask
-- whether a bridge exists.
local function start()
  if started then return true end
  if not ipc or not ipc.init then return false end
  local ok = pcall(ipc.init, SELF)
  if not ok then return false end
  pcall(ipc.on_message, on_message)
  started = true
  return true
end

-- Is a bridge listening? ipc.list() enumerates the sockets in ~/.lera/ipc,
-- which is exactly "has someone started one", and costs nothing to ask.
function M.available()
  if not start() then return false end
  local ok, names = pcall(ipc.list)
  if not ok or type(names) ~= "table" then return false end
  for _, name in ipairs(names) do
    if name == BRIDGE then return true end
  end
  return false
end

-- Replies arrive as ordinary IPC messages; each carries back the id it was
-- asked with, so two commands in flight cannot be confused for one another.
-- "12/57 (21%) pushed players/x/foo.c", or "12 pushed ..." when the total is
-- not known. One line per file: on a directory that IS the progress, and a
-- count with no end in sight is not much better than silence.
local function progress_line(message)
  local done = tonumber(message.done) or 0
  local total = tonumber(message.total)
  local where = tostring(message.line or "")
  if total and total > 0 then
    local pct = math.floor((done / total) * 100 + 0.5)
    return string.format("%d/%d (%d%%) %s", done, total, pct, where)
  end
  return string.format("%d %s", done, where)
end

on_message = function(peer, message)
  if peer ~= BRIDGE or type(message) ~= "table" then return end

  if message.op == "cancel" then
    note("cancel: " .. tostring(message.output or ""))
    return
  end

  -- A file went by while the command is still running.
  if message.progress then
    if message.line then seen_lines[message.line] = true end
    note(progress_line(message))
    return
  end

  local id = message.id
  local cb = id and waiting[id]
  if id then waiting[id] = nil end

  running = nil
  local line = (message.op or "ferry") .. " " .. (message.path or "")
  if message.ok then
    note(line .. " done")
  else
    note(line .. " FAILED")
  end
  -- Anything ferry said that was NOT a per-file line -- an error, a summary,
  -- a refusal. The per-file lines already went by as progress, so repeating
  -- them here would print the whole transfer twice.
  local output = message.output
  if type(output) == "string" and output ~= "" then
    for row in (output .. "\n"):gmatch("([^\n]*)\n") do
      if row ~= "" and not seen_lines[row] then note("  " .. row) end
    end
  end
  seen_lines = {}
  if cb then pcall(cb, message) end
end

local function ensure_connected()
  if peer_idx then return true end
  if not M.available() then return false end

  local ok, idx = pcall(ipc.connect, BRIDGE)
  -- connect() answers with the peer index, or -1 when it could not.
  if not ok or type(idx) ~= "number" or idx < 0 then return false end
  peer_idx = idx
  return true
end

-- A line for the session log, the way a plugin reports itself on load. The
-- bridge is a process the wizard starts by hand, so "it isn't running" is a
-- normal state that should be VISIBLE rather than silently expressed as a
-- shorter menu -- which is indistinguishable from a bug.
function M.status_line()
  if not ipc or not ipc.init then
    return "ferry: unavailable (this build has no ipc)"
  end
  if M.available() then
    return "ferry: bridge ready -- pull/push/cc are on the file menu"
  end
  return "ferry: no bridge (github.com/skuggo/ferry-bridge) -- no pull/push/cc"
end

-- Send one verb for one path. Returns false when there is no bridge to send
-- it to, so a caller can say so rather than appearing to have done something.
function M.run(op, path, cb)
  if type(op) ~= "string" or type(path) ~= "string" or path == "" then return false end
  if not ensure_connected() then
    note("no bridge is running -- see github.com/skuggo/ferry-bridge")
    return false
  end

  local id = next_id
  next_id = next_id + 1
  if cb then waiting[id] = cb end

  local ok = pcall(ipc.send, peer_idx, { id = id, op = op, path = path })
  if not ok then
    waiting[id] = nil
    peer_idx = nil              -- the bridge went away; reconnect next time
    note("could not reach the bridge")
    return false
  end
  running = { op = op, path = path }
  note(op .. " " .. path .. " ... (right-click the pane to abort)")
  return true
end

-- What is in flight, or nil. The pane asks before treating a right-click as
-- an abort rather than as a menu.
function M.running()
  return running and (running.op .. " " .. running.path) or nil
end

-- Stop the command the bridge is running. The bridge answers this on its
-- reading thread, so it lands while ferry is still going.
function M.cancel()
  if not running then return false end
  if not peer_idx then
    running = nil
    return false
  end
  local ok = pcall(ipc.send, peer_idx, { id = next_id, op = "cancel" })
  next_id = next_id + 1
  if not ok then
    peer_idx = nil
    return false
  end
  note("aborting " .. running.op .. " " .. running.path .. " ...")
  running = nil
  return true
end

-- A disconnect of the MUD session says nothing about the bridge, but a plugin
-- reload does: drop the peer so the next call reconnects.
function M.reset()
  if peer_idx then pcall(ipc.disconnect, peer_idx) end
  peer_idx = nil
  waiting = {}
  running = nil
  seen_lines = {}
end

return M
