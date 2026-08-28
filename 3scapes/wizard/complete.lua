-- Completion algorithm for wizard paths. Pure: no I/O, no lera globals, no
-- module state. Everything it needs arrives as an argument and everything it
-- decides comes back as a return value, which is what makes the interesting
-- half of Tab completion testable without a MUD.

local M = {}

-- A word beginning with "-" is a flag: cp and grep both take them, and a flag
-- must neither complete nor count as an argument. A LONE "-" is not a flag --
-- `cd -` means the previous directory, so it is a real argument.
function M.is_flag(word)
  return #word > 1 and word:sub(1, 1) == "-"
end

-- Path-shaped words complete in any position, including the first.
function M.is_path_shaped(word)
  if word == "" then return false end
  local first = word:sub(1, 1)
  if first == "/" or first == "~" or first == "." then return true end
  return word:find("/", 1, true) ~= nil
end

-- Every maximal run of non-space bytes in `line`, as { text, start, stop }
-- with 1-based inclusive offsets. The mudlib refuses paths containing a space
-- (daemon/gmcp_files_d.c), so there is no quoting to honour and splitting on
-- spaces is complete.
local function tokenize(line)
  local out = {}
  local pos = 1
  while true do
    local s, e = line:find("[^ ]+", pos)
    if not s then break end
    out[#out + 1] = { text = line:sub(s, e), start = s, stop = e }
    pos = e + 1
  end
  return out
end

-- nil when nothing should complete. Otherwise the word under the cursor, its
-- span, the command that owns the line, and which argument the word is.
function M.context(line, cursor)
  if type(line) ~= "string" then return nil end
  cursor = cursor or (#line + 1)
  if cursor < 1 then return nil end
  if cursor > #line + 1 then cursor = #line + 1 end

  -- Scan back from the cursor to the start of the word. Only text to the LEFT
  -- of the cursor is the word: completing from text the user has already moved
  -- past would rewrite it.
  local word_end = cursor - 1
  local word_start = cursor
  while word_start > 1 and line:sub(word_start - 1, word_start - 1) ~= " " do
    word_start = word_start - 1
  end
  local word = (word_end >= word_start) and line:sub(word_start, word_end) or ""

  if M.is_flag(word) then return nil end

  local tokens = tokenize(line)
  local command = nil
  local arg_index = 0
  if #tokens > 0 and tokens[1].start < word_start then
    command = tokens[1].text
    arg_index = 1
    for i = 2, #tokens do
      local t = tokens[i]
      if t.start >= word_start then break end
      if not M.is_flag(t.text) then arg_index = arg_index + 1 end
    end
  end

  -- A bare word in first position is a command name, not a path. Rewriting a
  -- part-typed `sc` into `scripts/` because the cwd holds one is worse than
  -- doing nothing.
  if arg_index == 0 and not M.is_path_shaped(word) then return nil end

  return {
    word = word,
    word_start = word_start,
    word_end = word_end,
    command = command,
    arg_index = arg_index,
  }
end

-- Split a word at its last "/" into the directory part (slash included) and the
-- prefix being completed.
function M.split(word)
  local slash = nil
  for i = #word, 1, -1 do
    if word:sub(i, i) == "/" then slash = i break end
  end
  if not slash then return "", word end
  return word:sub(1, slash), word:sub(slash + 1)
end

-- Replace the prefix portion of the word with `text`. Returns the new line and
-- the new cursor offset.
function M.apply(line, ctx, prefix, text)
  local pstart = ctx.word_end - #prefix + 1
  local new_line = line:sub(1, pstart - 1) .. text .. line:sub(ctx.word_end + 1)
  return new_line, pstart + #text
end

return M
