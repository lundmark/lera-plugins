-- ferry, from the file pane, through a bridge process.
--
-- The sandbox has no disk and no shell -- four os functions and nothing else
-- (lera/src/script/plugin.c), and plugins are Lua only: the loader resolves
-- <name>.lua and there is no native ABI, so this cannot be pushed down into a
-- compiled plugin either. It can open a Unix socket, though, and
-- tools/ferry-bridge in this repo is the process on the other end: a small
-- Rust binary that runs ferry in the mirror checkout and sends back what
-- happened.
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
local peer_idx = nil
local started = false
local next_id = 1
local waiting = {}      -- id -> callback

local function note(text)
  print("[ferry] " .. text)
end

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
local on_message
on_message = function(peer, message)
  if peer ~= BRIDGE or type(message) ~= "table" then return end
  local id = message.id
  local cb = id and waiting[id]
  if id then waiting[id] = nil end

  local line = (message.op or "ferry") .. " " .. (message.path or "")
  if message.ok then
    note(line .. ": " .. ((message.output ~= "" and message.output) or "done"))
  else
    note(line .. " FAILED: " .. tostring(message.output or "no reason given"))
  end
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

-- Send one verb for one path. Returns false when there is no bridge to send
-- it to, so a caller can say so rather than appearing to have done something.
function M.run(op, path, cb)
  if type(op) ~= "string" or type(path) ~= "string" or path == "" then return false end
  if not ensure_connected() then
    note("no bridge is running. Start tools/ferry-bridge (cargo build --release) "
         .. "in your mirror checkout.")
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
  note(op .. " " .. path .. " ...")
  return true
end

-- A disconnect of the MUD session says nothing about the bridge, but a plugin
-- reload does: drop the peer so the next call reconnects.
function M.reset()
  if peer_idx then pcall(ipc.disconnect, peer_idx) end
  peer_idx = nil
  waiting = {}
end

return M
