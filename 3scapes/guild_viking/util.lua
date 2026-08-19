-- Portal string.split parity: pattern separator, empty fields preserved,
-- a trailing separator yields a trailing empty field.
local util = {}

function util.split(s, sep)
  local out = {}
  local pos = 1
  while true do
    local a, b = string.find(s, sep, pos)
    if not a then
      out[#out + 1] = string.sub(s, pos)
      return out
    end
    out[#out + 1] = string.sub(s, pos, a - 1)
    pos = b + 1
  end
end

return util
