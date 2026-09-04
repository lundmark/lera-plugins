-- Skills page: every skill's rank/xp/gating (Craft.Skills).
local pagelib = require("pagelib")
local state = require("state")

local C = pagelib.C
local M = {}

local CAN_TRAIN_LABEL = {
  [1] = "ready", [-1] = "maxed", [-2] = "locked",
  [-3] = "need xp", [-4] = "need tokens",
}
local CAN_TRAIN_COLOR = {
  [1] = C.bright_green, [-1] = C.cyan, [-2] = C.dim,
  [-3] = C.yellow, [-4] = C.yellow,
}

function M.lines(width)
  width = width or 80
  local s = state.get()
  local lines = {}
  local function add(text) lines[#lines + 1] = text end

  local names = {}
  for name in pairs(s.skills) do names[#names + 1] = name end
  table.sort(names)

  if #names == 0 then
    add(pagelib.trunc(C.dim .. "No Craft.Skills data received yet." .. pagelib.RESET, width))
    return lines
  end

  add(pagelib.header(width, "Skills"))
  local rows, colors = {}, {}
  for _, name in ipairs(names) do
    local r = s.skills[name]
    local rank_s = tostring(r.rank or 0)
    if (r.rank or 0) ~= (r.trained or 0) then
      rank_s = rank_s .. "/" .. tostring(r.trained or 0)
    end
    local prog = (r.to_next and r.to_next > 0)
      and (pagelib.fmt_num(r.into) .. "/" .. pagelib.fmt_num(r.to_next)) or "max"
    local locked = r.unlocked ~= 1
    local status = locked and "locked" or (CAN_TRAIN_LABEL[r.can_train] or "?")
    -- Token cost to train the next rank (ctrain.c's own cost preview), shown
    -- as "1x dnt" -- short token abbreviation, not the spelled-out realm/tier
    -- -- colored by the token's own realm (same REALM_COLOR every other
    -- realm-tagged row in this plugin uses). 0 means maxed / no cost row.
    local cost = "-"
    if (r.train_cost or 0) > 0 then
      local cost_color = (r.train_realm == "any") and C.white
        or (pagelib.REALM_COLOR[r.train_realm] or C.white)
      cost = cost_color .. pagelib.fmt_num(r.train_cost) .. "x "
        .. (r.train_abbr or "?") .. pagelib.RESET
    end
    rows[#rows + 1] = { pagelib.title(name), rank_s, prog, status, cost }
    colors[#colors + 1] = locked and C.dim or (CAN_TRAIN_COLOR[r.can_train] or C.white)
  end

  local cols = pagelib.columns(width, {
    { title = "Skill", w = "*" },
    { title = "Rank", w = 10 },
    { title = "XP", w = 16 },
    { title = "Status", w = 12 },
    { title = "Train Cost", w = 12 },
  }, rows)
  add(cols[1])
  local i
  for i = 2, #cols do
    add(colors[i - 1] .. cols[i] .. pagelib.RESET)
  end

  return lines
end

return M
