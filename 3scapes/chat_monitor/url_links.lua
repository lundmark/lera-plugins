-- Shared URL metadata and render-only affordances; stored text stays unchanged.
local M = {}

-- Lera's cell renderer uses one cell per UTF-8 codepoint (not wcwidth).
-- Keep raw byte positions as well, for consumers with word-wrapped rows.
function M.cells(text)
  local cells, plain, map, i, col = {}, {}, {}, 1, 0
  while i <= #text do
    local escape = text:byte(i) == 27 and text:sub(i):match("^\27%[[0-9;]*.")
    if escape then
      i = i + #escape
    else
      local b = text:byte(i)
      local n = 1
      if b >= 194 and b <= 244 then
        local candidate = b < 224 and 2 or (b < 240 and 3 or 4)
        local valid = i + candidate - 1 <= #text
        for j = 1, candidate - 1 do
          local c = text:byte(i+j) or 0
          valid = valid and c >= 128 and c <= 191
        end
        local second = text:byte(i+1) or 0
        if b == 224 then valid = valid and second >= 160 end
        if b == 237 then valid = valid and second <= 159 end
        if b == 240 then valid = valid and second >= 144 end
        if b == 244 then valid = valid and second <= 143 end
        if valid then n = candidate end
      end
      local cell = { first = i, last = i+n-1, col = col }
      -- Controls delimit candidates but occupy no rendered cells.
      plain[#plain+1] = text:sub(i, i+n-1)
      for j = 1, n do map[#map+1] = cell end
      if b >= 32 and b ~= 127 then
        cells[#cells+1] = cell
        col = col + 1
      end
      i = i + n
    end
  end
  return cells, table.concat(plain), map
end

function M.find(text)
  local _, plain, map = M.cells(text)
  local lower, links, pos = plain:lower(), {}, 1
  while pos <= #plain do
    local start
    for _, prefix in ipairs({"http://", "https://", "www."}) do
      local at = lower:find(prefix, pos, true)
      if at and (not start or at < start) then start = at end
    end
    if not start then break end
    local finish = start
    while finish <= #plain and not plain:sub(finish, finish):match('[%s<>"\'`]') do
      finish = finish + 1
    end
    local value = plain:sub(start, finish-1)
    local prev = plain:sub(start-1, start-1)
    local valid = start == 1 or not prev:match('[%w_/@.:%-]')
    valid = valid and not value:find('[%c\\]')
    -- Sentence punctuation is not part of a URL; balanced path brackets are.
    while #value > 0 do
      local last = value:sub(-1)
      local opener = ({ [")"] = "(", ["]"] = "[", ["}"] = "{" })[last]
      local trim = last:match('[.,;:!?]') ~= nil
      if opener then
        local opens, closes = 0, 0
        for c in value:gmatch('.') do
          if c == opener then opens = opens + 1 end
          if c == last then closes = closes + 1 end
        end
        trim = closes > opens
      end
      if not trim then break end
      value = value:sub(1, -2)
    end
    local normalized = value:lower():sub(1,4) == 'www.' and ('https://' .. value) or value
    local host = normalized:match('^[Hh][Tt][Tt][Pp][Ss]?://([^/?#]+)')
    valid = valid and host and host ~= '' and not host:find('@', 1, true)
    if value:lower():sub(1,4) == 'www.' then
      valid = valid and #host > 4 and host:sub(-1) ~= '.'
    end
    if valid then
      local a, b = map[start], map[start+#value-1]
      links[#links+1] = {kind='url', value=normalized, col_start=a.col,
        col_end=b.col+1, byte_start=a.first, byte_end=b.last}
    end
    pos = math.max(start+1, finish)
  end
  return links
end
-- Match api_ui.c's SGR style semantics, including its all-style reset for
-- selective style-off codes. Extended colour operands are not style codes.
local style_bits = { [1]=1, [2]=2, [3]=4, [4]=8, [5]=16, [7]=32 }
local function sgr_styles(params, styles)
  local codes = {}
  if params == '' then codes[1] = 0 end
  local pos = 1
  while pos <= #params do
    local stop = params:find(';', pos, true) or (#params+1)
    codes[#codes+1] = tonumber(params:sub(pos, stop-1)) or 0
    pos = stop+1
  end
  local i = 1
  while i <= #codes do
    local code = codes[i]
    if code == 0 or code == 22 or code == 23 or code == 24 or code == 25 or code == 27 then
      styles = {}
    elseif style_bits[code] then
      styles[code] = true
    elseif code == 38 or code == 48 then
      local mode = codes[i+1]
      i = i + (mode == 2 and 4 or (mode == 5 and 2 or 1))
    end
    i = i + 1
  end
  return styles
end

-- Spans use visible cell columns, so callers can reuse wrapped click metadata.
-- Never replay source escapes: only underline and style restoration are added.
function M.highlight(text, state, spans, excluded)
  spans = spans or M.find(text)
  local ranges = {}
  for _, span in ipairs(spans) do
    local overlap = false
    for _, anchor in ipairs(excluded or {}) do
      if span.col_start < anchor.col_end and span.col_end > anchor.col_start then
        overlap = true
        break
      end
    end
    if not overlap then ranges[#ranges+1] = span end
  end
  if #ranges == 0 then return text end
  local styles = {}
  for code, bit in pairs(style_bits) do
    if math.floor(((state and state.style) or 0) / bit) % 2 == 1 then styles[code] = true end
  end
  local actual = {}
  for code in pairs(styles) do actual[code] = true end
  local out, cursor, range = {}, 1, 1
  local function restore()
    out[#out+1] = '\27[24m'
    for _, code in ipairs({1,2,3,4,5,7}) do
      if styles[code] then out[#out+1] = '\27[' .. code .. 'm' end
    end
    actual = {}
    for code in pairs(styles) do actual[code] = true end
  end
  local function escapes(fragment)
    out[#out+1] = fragment
    for params in fragment:gmatch('\27%[([0-9;]*)m') do
      styles = sgr_styles(params, styles)
      actual = sgr_styles(params, actual)
    end
  end
  for _, cell in ipairs(M.cells(text)) do
    escapes(text:sub(cursor, cell.first-1))
    while ranges[range] and ranges[range].col_end <= cell.col do range = range + 1 end
    local span = ranges[range]
    local linked = span and cell.col >= span.col_start and cell.col < span.col_end
    if linked then
      if not actual[4] then out[#out+1] = '\27[4m'; actual[4] = true end
    elseif actual[4] and not styles[4] then
      restore()
    end
    out[#out+1] = text:sub(cell.first, cell.last)
    cursor = cell.last+1
  end
  if actual[4] and not styles[4] then restore() end
  out[#out+1] = text:sub(cursor)
  return table.concat(out)
end
return M
