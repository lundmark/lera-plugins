-- guild_viking livestock page builder tests. Run from the lera-plugins repo
-- root with LERA_ROOT pointing at a built Lera checkout.
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

ui = { dirty = function() end }
lera = { time = function() return 1000 end }
buffer = { color_print = function() end }

local S = require("state").S
local page_opts = require("page_opts")
local page = require("pages.livestock")

local function joined(width)
  return table.concat(page.lines(width or 80), "\n")
end

-- Empty state: the page must still build, and must offer the discoverability
-- hint rather than LEGACY's obsolete "enable vtoggle mip_livestock" (GMCP
-- always sends these keys, so that hint would be a lie).
S.herds, S.lmarket, S.lneeds = {}, {}, {}
S.bqueue, S.lpending = {}, {}
S.lfind = { posts = {}, offers = {}, auctions = {} }
S.lfeed = { grain = 0, water = 0, head = 0 }
local empty = joined(80)
check("empty page builds", type(page.lines(80)) == "table")
check("empty page hints at vlivestock market",
      empty:find("vlivestock market", 1, true) ~= nil)
check("empty page does not mention mip_livestock",
      empty:find("mip_livestock", 1, true) == nil)

-- With a herd, the species label appears and head/cap is rendered.
S.buildings = { sheepfold = 2 }   -- tier 2 -> cap 14
S.herds = {
  sheepfold = { bldg = "sheepfold", head = 9, quality = 61, gen = 3,
                sterile = 0, hard = 40, fert = 55, yield = 70, vigor = 66,
                con = 50, breed = "nordic", hv = 1, trait = "prolific",
                age_ticks = 12 },
}
local withherd = joined(80)
check("herd shows its species label", withherd:find("Sheep", 1, true) ~= nil)
check("herd shows head against cap", withherd:find("9", 1, true) ~= nil
      and withherd:find("14", 1, true) ~= nil)
check("herd trait is named, not printed raw",
      withherd:find("Prolific", 1, true) ~= nil)

-- A section toggled off must vanish entirely.
page_opts.show_stock_herds = false
check("herds section respects its toggle",
      joined(80):find("Sheep", 1, true) == nil)
page_opts.show_stock_herds = true

-- Narrow width must not error and must not exceed the width.
local narrow = page.lines(40)
check("narrow width builds", type(narrow) == "table" and #narrow > 0)
local overlong = false
for _, l in ipairs(narrow) do
  if #(l:gsub("\027%[[%d;]*m", "")) > 40 then overlong = true end
end
check("no visible line exceeds the width", not overlong)

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("all livestock page cases passed")
