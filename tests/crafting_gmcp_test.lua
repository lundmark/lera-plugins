package.path = "3scapes/crafting/?.lua;" .. package.path
lera = { time = function() return 1000 end }

local protocol = require("protocol")
local applied = { Info = 0, State = 0 }
protocol.on_apply(function(sub) applied[sub] = applied[sub] + 1 end)

local function check_feed(info, state, other_info, other_state)
  protocol.reset_connection()
  applied.Info, applied.State = 0, 0

  local standing = { full = 1, realms = { Fantasy = { level = 3 } } }
  assert(protocol.on_gmcp(info, standing))
  assert(protocol.on_gmcp(other_info, standing))
  assert(protocol.mirror("Info").realms.Fantasy.level == 3)
  assert(applied.Info == 1, "both Info wire names applied the same frame")

  local summary = { full = 1, souls = 9 }
  local chunk = { full = 1, materials_g12c0 = { { name = "Mana Crystal", qty = 2 } } }
  local close = { full = 1, materials_chunks_g12 = 1 }
  assert(protocol.on_gmcp(state, summary))
  assert(protocol.on_gmcp(other_state, summary))
  assert(protocol.on_gmcp(other_state, chunk))
  assert(protocol.materials_stage_debug().have == 0, "the alternate feed staged a chunk")
  assert(protocol.on_gmcp(state, chunk))
  assert(protocol.on_gmcp(state, close))
  assert(protocol.on_gmcp(other_state, close))
  assert(protocol.mirror("State").souls == 9)
  assert(protocol.mirror("State").materials[1].name == "Mana Crystal")
  assert(applied.State == 3, "the alternate State feed applied an update")
  assert(protocol.counters().applied == 4 and protocol.counters().bad_package == 0)
end

check_feed("Craft.Info", "Craft.State", "Craft.Infodata", "Craft.Statedata")
check_feed("Craft.Infodata", "Craft.Statedata", "Craft.Info", "Craft.State")
print("Crafting GMCP wire names and material chunks: PASS")
