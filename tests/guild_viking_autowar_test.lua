-- Focused Auto-War adapter tests. Run from the lera plugins directory.
package.path = "3scapes/guild_viking/?.lua;" .. package.path

ui = { dirty = function() end }
buffer = { color_print = function() end }
local sent = {}
mud = { connected = function() return true end,
        send = function(command) sent[#sent + 1] = command end }
store = { load = function() end, get = function() return nil end,
          set = function() end, save = function() end }

local opts = require("page_opts")
local S = require("state").S
local aw = require("autowar")

assert(opts.get("auto_battle") == false)
aw.tick()
assert(#sent == 0, "disabled Auto-War sent a command")

opts.set("auto_battle", true)
S.battle = {
  phase = "deploy", mode = "field", budget = 10, spent = 0,
  width = 8, height = 8, dz = 2, units = {},
  reserve = {{ label = "Shieldwall", size = 20, uid = 7, cost = 3 }},
}
aw.tick()
assert(sent[1] == "vbattle deploy 7 D2", "unexpected deploy: " .. tostring(sent[1]))

opts.set("auto_battle", false)
S.battle = nil

-- ---------------------------------------------------------------------------
-- Order sequence. The server now steps your companies in the order the orders
-- arrive, with an enemy company moving between each of yours, so which order
-- autowar emits its moves in is a tactical choice rather than bookkeeping.
-- The engine must lead (its positioning is the whole plan in an assault) and
-- the ranged company, which is only repositioning, must come last.
-- ---------------------------------------------------------------------------
local real_time = os.time
local fake_now = real_time()
os.time = function() return fake_now end

opts.set("auto_battle", true)
S.battle = {
  phase = "battle", mode = "siege_attack", turn = 3,
  width = 8, height = 8, dz = 2,
  terrain_rows = {}, works_rows = {},
  -- Deliberately seeded in the WRONG sequence -- archers first, engine last --
  -- so that only the priority sort can produce the expected order. Seeding
  -- them already-correct would pass just as well with no sorting at all.
  units = {
    { side = "you", label = "Bowmen",   size = 12, coord = "A1", morale = 90,
      utype = "bogmenn",  bid = 3 },
    { side = "you", label = "Huscarls", size = 20, coord = "D4", morale = 90,
      utype = "huscarls", bid = 2 },
    { side = "you", label = "Engine",   size = 4,  coord = "H8", morale = 90,
      utype = "siege",    bid = 1 },
    { side = "foe", label = "Raiders",  size = 18, coord = "D6", morale = 80,
      utype = "foe_raiders", bid = 10 },
  },
  reserve = {},
}
-- Jump past the state machine's pacing gate so this tick actually plans.
fake_now = fake_now + 1000
sent = {}
aw.tick()

local function order_pos(bid)
  for i, c in ipairs(sent) do
    if c:find("^vbattle order " .. bid .. " ") then return i end
  end
  return nil
end
local p_siege, p_line, p_ranged = order_pos(1), order_pos(2), order_pos(3)
assert(p_siege, "the siege engine was given no order at all: " ..
  table.concat(sent, " | "))
assert(p_ranged, "the ranged company was given no order at all: " ..
  table.concat(sent, " | "))
assert(p_siege < p_ranged,
  "engine must be ordered before the repositioning archers, got: " ..
  table.concat(sent, " | "))
if p_line then
  assert(p_siege < p_line, "engine must be ordered before the line company: " ..
    table.concat(sent, " | "))
  assert(p_line < p_ranged,
    "the company closing to contact must be ordered before the archers: " ..
    table.concat(sent, " | "))
end

os.time = real_time
opts.set("auto_battle", false)
S.battle = nil
print("guild_viking_autowar_test: PASS")
