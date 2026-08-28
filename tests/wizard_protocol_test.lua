-- wizard path resolution and directory cache. Run from the lera-plugins repo
-- root with LERA_ROOT pointing at a built Lera checkout.
package.path = "3scapes/wizard/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- Recorded rather than swallowed: a test that asserts nothing was sent has to
-- be able to see that nothing was sent.
local sent = {}
gmcp = {
  on = function() return 1 end,
  send = function(pkg, data) sent[#sent + 1] = { pkg = pkg, data = data }; return true end,
  enabled = function() return true end,
}
ui = { dirty = function() end }

local protocol = require("protocol")

-- ---- normalize ------------------------------------------------------------

check("normalize: plain path", protocol.normalize("/players/simon") == "/players/simon")
check("normalize: collapses double slashes",
      protocol.normalize("/players//simon") == "/players/simon")
check("normalize: drops a trailing slash",
      protocol.normalize("/players/simon/") == "/players/simon")
check("normalize: root stays root", protocol.normalize("/") == "/")
check("normalize: removes .", protocol.normalize("/players/./simon") == "/players/simon")
check("normalize: resolves ..", protocol.normalize("/players/simon/..") == "/players")
check("normalize: .. cannot escape root", protocol.normalize("/../..") == "/")

-- ---- resolve --------------------------------------------------------------

local CWD = "/players/simon"
local HOME = "/players/simon"

check("resolve: empty dir is the cwd", protocol.resolve("", CWD, HOME) == CWD)
check("resolve: absolute wins", protocol.resolve("/open/", CWD, HOME) == "/open")
check("resolve: relative joins the cwd",
      protocol.resolve("areas/", CWD, HOME) == "/players/simon/areas")
check("resolve: .. walks up", protocol.resolve("../", CWD, HOME) == "/players")
check("resolve: tilde is home", protocol.resolve("~/areas/", CWD, HOME) == "/players/simon/areas")
check("resolve: bare tilde is home", protocol.resolve("~", CWD, HOME) == HOME)
check("resolve: tilde without a known home is unresolvable",
      protocol.resolve("~/areas/", CWD, nil) == nil,
      "the home directory is learned from the first response of a connection")
check("resolve: no cwd is unresolvable", protocol.resolve("areas/", nil, HOME) == nil)

-- ---- cwd / home / availability -------------------------------------------

protocol.reset()
check("cwd: unset before any response", protocol.cwd() == nil)
check("home: unset before any response", protocol.home() == nil)
check("available: false before Core.Supported", protocol.available() == false)

protocol.set_available(true)
check("available: set true", protocol.available() == true)

protocol.set_cwd("/players/simon")
check("cwd: set from a cd confirmation", protocol.cwd() == "/players/simon")
check("home: the first cwd of a connection is home",
      protocol.home() == "/players/simon",
      "current_path is players/<name> at logon")

protocol.set_cwd("/open")
check("cwd: a later cd moves the cwd", protocol.cwd() == "/open")
check("home: a later cd does not move home", protocol.home() == "/players/simon")

-- ---- cache ---------------------------------------------------------------

check("lookup: unknown path is nil", protocol.lookup("/nowhere") == nil)

protocol.store("/open", { dirs = { "a" }, files = { "b.c" }, complete = true })
do
  local e = protocol.lookup("/open")
  check("lookup: stored entry comes back", e ~= nil and e.complete == true)
  check("lookup: entry carries its listing",
        e ~= nil and e.dirs[1] == "a" and e.files[1] == "b.c")
end

protocol.invalidate("/open")
check("invalidate: drops the entry", protocol.lookup("/open") == nil)

protocol.store("/open", { dirs = {}, files = {}, complete = true })
protocol.reset()
check("reset: clears the cache", protocol.lookup("/open") == nil)
check("reset: clears the cwd", protocol.cwd() == nil)
check("reset: clears home", protocol.home() == nil)
check("reset: clears availability",
      protocol.available() == false,
      "the server drops its state on disconnect, so ours cannot outlive it")

check("no traffic: resolution and caching never touch the wire",
      #sent == 0,
      #sent .. " message(s) sent")

print(failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
