-- Guild.Map's packed grid planes.
--
-- A map plane made of a small alphabet wastes most of each byte, so the
-- server packs each plane at its alphabet's real width and base64-encodes the
-- result: terrain at 4 bits/cell (11 glyphs), the east/south passability
-- planes at 1 bit/cell. This is the inverse of
-- `protocol_grid_pack_row()` in the mudlib's secure/protocol/grid_codec_impl.h
-- -- read from that file, not inferred from samples.
--
-- Wire contract, restated because every one of these matters to the decode:
--   * cells are MSB first, zero-padded to a byte boundary;
--   * base64 is standard, with NO "=" padding -- the consumer knows the cell
--     count from the grid width, so trailing bits are simply ignored;
--   * a row that cannot be decoded is refused whole rather than
--     part-decoded. A wrong code draws a wrong map, which is worse than no
--     map (the server applies the same rule when packing).
--
-- The plane's encoding is named per-push by Guild.Map's `enc` key ("glyph",
-- "b4", "b1"), so a plane that failed to pack server-side arrives as glyph
-- rows with `enc` saying so, and no client-side sniffing is involved.
local M = {}

-- Standard base64, matching protocol_grid_b64_alphabet().
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
          .. "abcdefghijklmnopqrstuvwxyz"
          .. "0123456789+/"

local B64_INDEX = {}
for i = 1, #B64 do B64_INDEX[B64:sub(i, i)] = i - 1 end

-- PROTOCOL_GRID_ROW_MAX (secure/protocol/config.h:118). The server refuses to
-- pack a longer row, so a width beyond this cannot be a packed plane.
M.ROW_MAX = 256

-- Terrain meaning -> glyph, for gmcp_map_terrain_table()'s 11 entries.
--
-- Why meanings and not code positions: in "b4" mode the server's `legend`
-- maps DECIMAL CODE -> meaning ("0" -> "unexplored"), never code -> glyph,
-- so a client that wants glyphs -- and this one does, since popups/map.lua
-- colours and labels by glyph -- has to bridge the two somewhere. Keying the
-- bridge on the meaning means a code inserted or reordered server-side still
-- decodes correctly, and a genuinely new terrain type decodes to nil for
-- that code alone (rendered through the renderer's existing unknown-symbol
-- fallback) rather than silently shifting every glyph after it.
local TERRAIN_GLYPH_BY_MEANING = {
  ["unexplored"]              = ".",
  ["plains"]                  = "p",
  ["forest"]                  = "f",
  ["hills"]                   = "h",
  ["mountains"]               = "A",
  ["tundra"]                  = "t",
  ["coast"]                   = "c",
  ["water (fjord/lake)"]      = "W",
  ["bridge"]                  = "=",
  ["river/ford (unbridged)"]  = "r",
  ["road"]                    = "+",
}

-- Glyph substituted for a code the legend does not explain. popups/map.lua
-- resolves an unrecognised glyph through VMAP_COLOR_FALLBACK (magenta) and
-- the generic "Terrain" tooltip, so an unknown code is visibly unknown
-- instead of impersonating a real terrain type.
M.UNKNOWN_GLYPH = "?"

-- Bits per cell for each encoding the server can name in `enc`.
local BITS = { b1 = 1, b4 = 4 }

-- Unpack one base64 row into exactly `cells` numeric codes.
--
-- Arithmetic rather than the `bit` library: plugins run in a sandbox whose
-- whitelist is the basic globals plus table/string/math/coroutine, and the
-- accumulator here never exceeds 9 bits anyway (the inner loop stops as soon
-- as it holds `bits`, so at most bits-1 + 6 bits are ever held at once).
-- Returns an array of codes, or nil plus a reason.
function M.unpack_row(packed, bits, cells)
  if type(packed) ~= "string" then return nil, "row is not a string" end
  if cells < 0 or cells > M.ROW_MAX then return nil, "cell count out of range" end
  local out = {}
  local acc, held, i = 0, 0, 1
  while #out < cells do
    while held < bits and i <= #packed do
      local index = B64_INDEX[packed:sub(i, i)]
      if not index then return nil, "byte " .. i .. " is not base64" end
      acc = acc * 64 + index
      held = held + 6
      i = i + 1
    end
    if held < bits then return nil, "row ends after " .. #out .. " of " .. cells .. " cells" end
    local shift = 2 ^ (held - bits)
    out[#out + 1] = math.floor(acc / shift) % (2 ^ bits)
    held = held - bits
    acc = (held > 0) and (acc % (2 ^ held)) or 0
  end
  return out
end

-- Build code -> glyph for a terrain legend (`{ ["0"] = "unexplored", ... }`).
-- Returns nil when the legend is absent or carries no usable entry: decoding
-- a packed plane against no legend at all would produce a map made entirely
-- of unknown cells, which is worse than declining.
function M.terrain_glyphs(legend)
  if type(legend) ~= "table" then return nil end
  local glyphs, found = {}, false
  for code, meaning in pairs(legend) do
    local n = tonumber(code)
    local glyph = TERRAIN_GLYPH_BY_MEANING[tostring(meaning)]
    if n and glyph then
      glyphs[n] = glyph
      found = true
    end
  end
  if not found then return nil end
  return glyphs
end

-- Edge planes need no legend bridge. The server assigns the passability
-- codes 0 and 1 the glyphs "0" and "1" deliberately, so that `legend_edge`
-- reads identically whether a push ended up packed or fell back to glyphs
-- (see the comment above send_gmcp_map() in the guild's gmcp.h). The decimal
-- code and the glyph are therefore the same character by construction.
function M.edge_glyphs()
  return { [0] = "0", [1] = "1" }
end

-- Decode one plane -- an array of row strings -- into an array of glyph
-- rows, using the per-plane encoding the push declared.
--
-- `glyphs` is a code -> glyph table (nil for "glyph" encoding, where the rows
-- already are glyphs). Returns the rows plus a count of rows that failed to
-- decode; a failed row becomes "" rather than dropping out of the array,
-- because a plane's array index IS its row number and shifting later rows up
-- would silently redraw the whole map one row off.
function M.decode_plane(rows, enc, width, glyphs)
  local out, failed = {}, 0
  if type(rows) ~= "table" then return out, failed end
  if enc == nil or enc == "glyph" then
    for i = 1, #rows do out[i] = tostring(rows[i] or "") end
    return out, failed
  end
  local bits = BITS[enc]
  if not bits or not glyphs then
    for i = 1, #rows do out[i] = "" end
    return out, #rows
  end
  for i = 1, #rows do
    local codes = M.unpack_row(rows[i], bits, width)
    if codes then
      local cells = {}
      for j = 1, #codes do cells[j] = glyphs[codes[j]] or M.UNKNOWN_GLYPH end
      out[i] = table.concat(cells)
    else
      out[i] = ""
      failed = failed + 1
    end
  end
  return out, failed
end

return M
