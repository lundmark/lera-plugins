-- Minimal formatting helpers for guild_shaman's pages.
--
-- Deliberately a LOCAL copy rather than a require of guild_viking's pagelib:
-- that module lives inside the guild_viking plugin directory and is not on
-- this plugin's package.path, and reaching across plugin boundaries would make
-- guild_shaman fail to load whenever guild_viking is absent or disabled. The
-- subset here is only what these three pages actually draw.
local P = {}

P.RESET = "\27[0m"

P.C = {
  green        = "\27[32m",
  bright_green = "\27[92m",
  yellow       = "\27[33m",
  red          = "\27[31m",
  bright_red   = "\27[91m",
  cyan         = "\27[36m",
  bright_cyan  = "\27[96m",
  white        = "\27[37m",
  dim          = "\27[90m",
  magenta      = "\27[35m",
}

-- Width as the terminal sees it: SGR escapes occupy no columns, so they must
-- come out before measuring or every padded column drifts by the escape length.
function P.visible_width(s)
  if type(s) ~= "string" then return 0 end
  return #(s:gsub("\27%[[%d;]*m", ""))
end

-- Pad to `width` visible columns (never truncates -- callers size their own
-- content; this only makes short cells line up).
function P.pad(s, width)
  local n = width - P.visible_width(s)
  if n <= 0 then return s end
  return s .. string.rep(" ", n)
end

function P.header(width, text)
  local body = text .. " "
  local fill = width - P.visible_width(body)
  if fill < 0 then fill = 0 end
  return P.C.yellow .. body .. string.rep("-", fill) .. P.RESET
end

-- Ratio colour, used for the Vis pools and for discord severity. Thresholds
-- match guild_viking's pct_color so the two guilds' panels read alike.
function P.pct_color(val, max)
  if not max or max <= 0 then return P.C.dim end
  local pct = val * 100 / max
  if pct >= 80 then return P.C.bright_green end
  if pct >= 60 then return P.C.green end
  if pct >= 40 then return P.C.yellow end
  if pct >= 20 then return P.C.red end
  return P.C.bright_red
end

function P.bar(width, val, max, color)
  local inner = width - 2
  if inner < 0 then inner = 0 end
  val, max = val or 0, max or 0
  local filled
  if max <= 0 then
    filled = 0
  elseif val >= max then
    filled = inner
  else
    filled = math.floor(inner * val / max + 0.5)
    if filled < 0 then filled = 0 end
    if filled > inner then filled = inner end
  end
  local body
  if filled > 0 and color then
    body = color .. string.rep("#", filled) .. P.RESET .. string.rep("-", inner - filled)
  else
    body = string.rep("#", filled) .. string.rep("-", inner - filled)
  end
  return "[" .. body .. "]"
end

function P.kv(label, value, value_color)
  return P.C.dim .. label .. P.RESET .. " " ..
         (value_color or "") .. tostring(value) .. P.RESET
end

return P
