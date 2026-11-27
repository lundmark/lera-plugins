local M = {}

function M.stock(materials)
  local stock = {}
  for _, row in ipairs(materials) do
    if row.name then
      local key = row.name:lower()
      stock[key] = (stock[key] or 0) + (row.qty or 0)
    end
  end
  return stock
end

-- Craft.Recipes sends flat strings such as "2x Mana Crystal, 1x Sunleaf".
function M.parse(text)
  if type(text) ~= "string" or text == "" then return nil end
  local inputs = {}
  for entry in (text .. ","):gmatch("([^,]*),") do
    local qty, name = entry:match("^%s*(%d+)x%s+(.+)$")
    if not qty then return nil end
    inputs[#inputs + 1] = { qty = tonumber(qty), name = name }
  end
  return inputs
end

function M.has_stock(inputs, stock)
  if not inputs then return false end
  local needed = {}
  for _, input in ipairs(inputs) do
    local key = input.name:lower()
    needed[key] = (needed[key] or 0) + input.qty
    if needed[key] > (stock[key] or 0) then return false end
  end
  return true
end

function M.total(inputs, quantity)
  if not inputs then return nil end
  local labels = {}
  for _, input in ipairs(inputs) do
    labels[#labels + 1] = input.qty * quantity .. "x " .. input.name
  end
  return table.concat(labels, ", ")
end

return M
