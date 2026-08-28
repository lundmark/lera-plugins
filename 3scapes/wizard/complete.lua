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

-- ---- the command table ----------------------------------------------------
--
-- The first word of a line selects what Tab offers. Four things this table has
-- to do, each because a real command breaks without it:
--
--   * "dir" excludes files entirely (cd).
--   * "lpc" offers only .c files -- load/update/ul/cc take object paths. The
--     extension is KEPT: cmds/secure/load.c:28 appends ".c" only when absent,
--     so both forms reach the same object and showing what is on disk is the
--     less surprising of the two.
--   * from_arg exists for grep alone, whose first argument is a search term
--     and whose files start at argument 2.
--   * "none" suppresses: cmds/secure/lpc.c takes inline LPC code, not a path.
--
-- Directories are offered under every kind except "none", or a files-only
-- command could never descend into a subdirectory -- `more sub<Tab>` has to be
-- able to reach `more sub/thing.c`.
--
-- An unlisted command falls back to "any", so a new mudlib command works with
-- no client change. This table only ever narrows or corrects; it is not a gate.
--
-- `less` is not a mudlib command -- nothing in cmds/ provides it. It is here on
-- the assumption it is a personal alias, and an entry for a command that does
-- not exist costs nothing.
M.RULES = {
  cd = "dir", rmdir = "dir", mkdir = "dir",

  more = "file", less = "file", cat = "file", head = "file",
  tail = "file", ed = "file", rm = "file",

  cp = "any", mv = "any", diff = "any", ls = "any",

  load = "lpc", update = "lpc", ul = "lpc", cc = "lpc",

  lpc = "none",
}

M.FROM_ARG = { grep = 2 }

M.DEFAULT_KIND = "any"

function M.rule(command)
  local kind = command and M.RULES[command] or M.DEFAULT_KIND
  local from_arg = (command and M.FROM_ARG[command]) or 1
  return { kind = kind, from_arg = from_arg }
end

local function starts_with(s, prefix)
  return prefix == "" or s:sub(1, #prefix) == prefix
end

local function is_lpc_file(name)
  return name:sub(-2) == ".c"
end

function M.candidates(dirs, files, prefix, kind)
  local out = {}
  if kind == "none" then return out end

  for i = 1, #dirs do
    if starts_with(dirs[i], prefix) then
      out[#out + 1] = { name = dirs[i], is_dir = true }
    end
  end

  if kind ~= "dir" then
    for i = 1, #files do
      local name = files[i]
      if starts_with(name, prefix) and (kind ~= "lpc" or is_lpc_file(name)) then
        out[#out + 1] = { name = name, is_dir = false }
      end
    end
  end

  return out
end

function M.common_prefix(names)
  if #names == 0 then return "" end
  local shortest = names[1]
  for i = 2, #names do
    if #names[i] < #shortest then shortest = names[i] end
  end
  for cut = #shortest, 1, -1 do
    local candidate = shortest:sub(1, cut)
    local all = true
    for i = 1, #names do
      if names[i]:sub(1, cut) ~= candidate then all = false break end
    end
    if all then return candidate end
  end
  return ""
end

local function insertion(cand)
  return cand.is_dir and (cand.name .. "/") or cand.name
end

function M.decide(cands, prefix)
  if #cands == 0 then return nil end
  if #cands == 1 then
    return { action = "insert", text = insertion(cands[1]) }
  end

  local names = {}
  for i = 1, #cands do names[i] = cands[i].name end
  local shared = M.common_prefix(names)
  if #shared > #prefix then
    return { action = "insert", text = shared }
  end

  local items = {}
  for i = 1, #cands do
    local text = insertion(cands[i])
    items[i] = { label = text, value = text }
  end
  return { action = "menu", items = items }
end

return M
