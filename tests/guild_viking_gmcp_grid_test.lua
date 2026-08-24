-- guild_viking Guild.Map packed-plane codec (gmcp_grid.lua) unit tests. Run
-- from the lera-plugins repo root with LERA_ROOT pointing at a built Lera
-- checkout.
package.path = "3scapes/guild_viking/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

local grid = require("gmcp_grid")

-- ---- Hand-computed wire vectors --------------------------------------------
--
-- These two are worked out by hand from protocol_grid_pack_row()'s algorithm
-- (secure/protocol/grid_codec_impl.h), NOT produced by the packer below.
-- The round-trip cases that follow prove the decoder is the packer's inverse;
-- only these prove that the packer being inverted is the server's.
--
-- b1, "10101" (5 cells): bits 10101 -> held 5 -> final octet (0b10101 << 3)
-- = 0b10101000 = 168. One octet -> two base64 chars: (168<<16)>>18 = 42 -> "q",
-- ((168<<16)>>12)&0x3f = 0 -> "A".
check("b1 hand vector decodes to its source row",
  table.concat(grid.unpack_row("qA", 1, 5) or {}) == "10101",
  table.concat(grid.unpack_row("qA", 1, 5) or {}, ","))

-- b4, terrain "pf." with codes p=1, f=2, .=0: nibbles 0001 0010 0000 ->
-- octets 0b00010010 = 18 then (0b0000 << 4) = 0. chunk = 18<<16 = 0x120000 ->
-- "E" (4), "g" (32), "A" (0).
check("b4 hand vector decodes to its source codes",
  table.concat(grid.unpack_row("EgA", 4, 3) or {}, ",") == "1,2,0",
  table.concat(grid.unpack_row("EgA", 4, 3) or {}, ","))

-- ---- Independent packer, transcribed from the mudlib -----------------------
-- protocol_grid_pack_row(), secure/protocol/grid_codec_impl.h:36. Written
-- against that file rather than derived from gmcp_grid.lua, so a shared
-- misreading of the wire format cannot make both halves agree.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
         .. "abcdefghijklmnopqrstuvwxyz"
         .. "0123456789+/"

local function b64_char(n) return B64:sub(n + 1, n + 1) end

local function pack_row(codes, bits)
  local octets = {}
  local acc, held = 0, 0
  for i = 1, #codes do
    acc = (acc * (2 ^ bits) + codes[i]) % 0x80000000
    held = held + bits
    if held >= 8 then
      octets[#octets + 1] = math.floor(acc / 2 ^ (held - 8)) % 256
      held = held - 8
      acc = (held > 0) and (acc % 2 ^ held) or 0
    end
  end
  if held > 0 then octets[#octets + 1] = (acc * 2 ^ (8 - held)) % 256 end

  local out = {}
  for i = 1, #octets, 3 do
    local chunk = octets[i] * 65536
    if octets[i + 1] then chunk = chunk + octets[i + 1] * 256 end
    if octets[i + 2] then chunk = chunk + octets[i + 2] end
    out[#out + 1] = b64_char(math.floor(chunk / 262144) % 64)
    out[#out + 1] = b64_char(math.floor(chunk / 4096) % 64)
    if octets[i + 1] then out[#out + 1] = b64_char(math.floor(chunk / 64) % 64) end
    if octets[i + 2] then out[#out + 1] = b64_char(chunk % 64) end
  end
  return table.concat(out)
end

check("the independent packer reproduces the b1 hand vector",
  pack_row({ 1, 0, 1, 0, 1 }, 1) == "qA", pack_row({ 1, 0, 1, 0, 1 }, 1))
check("the independent packer reproduces the b4 hand vector",
  pack_row({ 1, 2, 0 }, 4) == "EgA", pack_row({ 1, 2, 0 }, 4))

-- ---- Round-trip over every width up to a full-width row --------------------
-- Widths 1..64 at both bit depths, so every "held" phase of the accumulator
-- and every base64 chunk remainder (1, 2 and 3 octets) is exercised. Codes
-- vary with the position so a decoder that returned a constant, or lost
-- ordering, cannot pass.
local rt_ok, rt_detail = true, nil
for _, bits in ipairs({ 1, 4 }) do
  local limit = (bits == 1) and 2 or 11
  for width = 1, 64 do
    local codes = {}
    for i = 1, width do codes[i] = (i * 7 + bits) % limit end
    local back = grid.unpack_row(pack_row(codes, bits), bits, width)
    for i = 1, width do
      if not back or back[i] ~= codes[i] then
        rt_ok = false
        rt_detail = "bits=" .. bits .. " width=" .. width .. " cell=" .. i
        break
      end
    end
    if not rt_ok then break end
  end
end
check("pack/unpack round-trips at both bit depths for widths 1..64", rt_ok, rt_detail)

-- A 256-cell row is exactly PROTOCOL_GRID_ROW_MAX, the widest the server will
-- pack; one cell wider is not a packed row at all.
local wide = {}
for i = 1, grid.ROW_MAX do wide[i] = i % 11 end
check("a row at PROTOCOL_GRID_ROW_MAX round-trips",
  table.concat(grid.unpack_row(pack_row(wide, 4), 4, grid.ROW_MAX) or {}, ",")
    == table.concat(wide, ","))
check("a cell count past PROTOCOL_GRID_ROW_MAX is refused",
  grid.unpack_row(pack_row(wide, 4), 4, grid.ROW_MAX + 1) == nil)

-- ---- Refusals --------------------------------------------------------------
-- A wrong code draws a wrong map, so a row that cannot be read whole is
-- refused whole rather than part-decoded.
check("a non-base64 byte inside the decoded span refuses the row",
  grid.unpack_row("!qA", 1, 5) == nil)
-- The server pads each row to a byte boundary and states that a consumer,
-- knowing the cell count from the grid width, simply ignores trailing bits.
-- So decoding stops at `cells` and never reaches a later byte -- including a
-- malformed one, which is why the case above has to put it first.
check("bytes past the last needed cell are not read",
  table.concat(grid.unpack_row("qA!", 1, 5) or {}) == "10101")
check("a row that runs out of bits refuses rather than short-returning",
  grid.unpack_row("qA", 1, 64) == nil)
check("a non-string row refuses", grid.unpack_row(nil, 4, 4) == nil)
check("zero cells decodes to an empty row, not a refusal",
  #(grid.unpack_row("", 4, 0) or { "x" }) == 0)

-- ---- Terrain legend bridge -------------------------------------------------
-- In "b4" mode the server's legend maps DECIMAL CODE -> MEANING; the glyphs
-- popups/map.lua colours by are recovered through the meaning.
local LEGEND = {
  ["0"] = "unexplored", ["1"] = "plains", ["2"] = "forest", ["3"] = "hills",
  ["4"] = "mountains", ["5"] = "tundra", ["6"] = "coast",
  ["7"] = "water (fjord/lake)", ["8"] = "bridge",
  ["9"] = "river/ford (unbridged)", ["10"] = "road",
}

local glyphs = grid.terrain_glyphs(LEGEND)
check("every terrain code resolves to its glyph",
  glyphs and glyphs[0] == "." and glyphs[1] == "p" and glyphs[2] == "f"
    and glyphs[3] == "h" and glyphs[4] == "A" and glyphs[5] == "t"
    and glyphs[6] == "c" and glyphs[7] == "W" and glyphs[8] == "="
    and glyphs[9] == "r" and glyphs[10] == "+")

-- The bridge is keyed on the meaning precisely so this holds: the mudlib's
-- own comment reserves the right to grow the terrain table, and a client that
-- assumed code order would then decode every later glyph one position off.
local SHUFFLED = { ["0"] = "plains", ["1"] = "unexplored" }
local shuffled_glyphs = grid.terrain_glyphs(SHUFFLED)
check("a reordered legend still resolves each code to the right glyph",
  shuffled_glyphs and shuffled_glyphs[0] == "p" and shuffled_glyphs[1] == ".")

local WITH_NEW = { ["0"] = "unexplored", ["1"] = "plains", ["2"] = "volcano" }
local new_glyphs = grid.terrain_glyphs(WITH_NEW)
check("an unrecognised meaning leaves only its own code unresolved",
  new_glyphs and new_glyphs[0] == "." and new_glyphs[1] == "p"
    and new_glyphs[2] == nil)

check("no legend at all declines rather than yielding an all-unknown map",
  grid.terrain_glyphs(nil) == nil and grid.terrain_glyphs({}) == nil
    and grid.terrain_glyphs({ ["0"] = "volcano" }) == nil)

-- Edge planes need no bridge: the server assigns codes 0/1 the glyphs "0"/"1"
-- so that legend_edge reads the same packed or not.
local edges = grid.edge_glyphs()
check("edge codes are their own glyphs", edges[0] == "0" and edges[1] == "1")

-- ---- Plane decoding --------------------------------------------------------
check("a glyph plane passes through verbatim",
  table.concat(grid.decode_plane({ "pp.", "ffA" }, "glyph", 3, nil), "/") == "pp./ffA")
check("a plane with no declared encoding is treated as glyphs",
  table.concat(grid.decode_plane({ "pp." }, nil, 3, nil), "/") == "pp.")

local terrain_plane = { pack_row({ 1, 1, 0 }, 4), pack_row({ 2, 2, 4 }, 4) }
check("a b4 plane decodes to glyph rows",
  table.concat(grid.decode_plane(terrain_plane, "b4", 3, glyphs), "/") == "pp./ffA")

local edge_plane = { pack_row({ 1, 0, 1 }, 1), pack_row({ 0, 0, 1 }, 1) }
check("a b1 plane decodes to passability rows",
  table.concat(grid.decode_plane(edge_plane, "b1", 3, edges), "/") == "101/001")

-- A row's array index IS its row number, so a row that fails to decode must
-- hold its position. Dropping it would slide every later row up one and
-- redraw the whole map off by a row, which looks like real terrain.
local broken = { pack_row({ 1, 1, 1 }, 4), "!!bad!!", pack_row({ 2, 2, 2 }, 4) }
local decoded, failed = grid.decode_plane(broken, "b4", 3, glyphs)
check("a row that fails to decode keeps its position and is counted",
  #decoded == 3 and decoded[1] == "ppp" and decoded[2] == "" and decoded[3] == "fff"
    and failed == 1, tostring(failed) .. " " .. table.concat(decoded, "/"))

local unknown_enc, unknown_failed = grid.decode_plane({ "abc" }, "b7", 3, glyphs)
check("an encoding this client cannot read empties the plane and counts it",
  #unknown_enc == 1 and unknown_enc[1] == "" and unknown_failed == 1)

local no_legend, no_legend_failed = grid.decode_plane(terrain_plane, "b4", 3, nil)
check("a packed plane with no legend empties rather than guessing glyphs",
  #no_legend == 2 and no_legend[1] == "" and no_legend_failed == 2)

-- A code the legend did not explain renders through the renderer's existing
-- unknown-symbol fallback rather than impersonating a neighbouring terrain.
local with_gap = grid.decode_plane({ pack_row({ 1, 2, 0 }, 4) }, "b4", 3,
  { [1] = "p", [0] = "." })
check("an unexplained code becomes the unknown glyph",
  with_gap[1] == "p" .. grid.UNKNOWN_GLYPH .. ".")

if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
end
print("ALL PASS")
