-- Files.List transport: path resolution, the directory cache, and (Task 5)
-- request/response with page accumulation.
--
-- Cache keys are absolute and resolved client-side. A request may carry a
-- relative path, but the same relative string means different directories from
-- different cwds, so it cannot be a key. The response echoes the path the
-- server resolved, which is reconciled against the key when the reply lands.

local M = {}

local cache = {}
local current = nil     -- tracked cwd, absolute
local home_dir = nil    -- learned from the first cwd of a connection
local is_available = false

-- ---- path arithmetic ------------------------------------------------------

function M.normalize(path)
  if type(path) ~= "string" or path == "" then return nil end
  local absolute = path:sub(1, 1) == "/"
  local parts = {}
  for piece in path:gmatch("[^/]+") do
    if piece == ".." then
      -- ".." cannot escape root. The daemon rejects any path containing ".."
      -- outright, so it must never reach the wire; collapsing here is what
      -- keeps that true.
      if #parts > 0 then parts[#parts] = nil end
    elseif piece ~= "." then
      parts[#parts + 1] = piece
    end
  end
  local joined = table.concat(parts, "/")
  if absolute then return "/" .. joined end
  return joined
end

-- Absolute path for a word's directory part, or nil when it cannot be resolved
-- yet (no cwd, or a "~" before home is known).
function M.resolve(dir, cwd, home)
  if type(dir) ~= "string" then return nil end

  if dir:sub(1, 1) == "~" then
    if not home then return nil end
    local rest = dir:sub(2)
    if rest == "" then return home end
    return M.normalize(home .. "/" .. rest)
  end

  if dir:sub(1, 1) == "/" then return M.normalize(dir) end

  if not cwd then return nil end
  if dir == "" then return M.normalize(cwd) end
  return M.normalize(cwd .. "/" .. dir)
end

-- ---- session state --------------------------------------------------------

function M.reset()
  cache = {}
  current = nil
  home_dir = nil
  is_available = false
end

function M.set_cwd(path)
  local resolved = M.normalize(path)
  if not resolved then return end
  current = resolved
  -- current_path is "players/<name>" at logon (secure/pinc/logon.h:1637), so
  -- the first directory seen in a connection is the wizard's home.
  if not home_dir then home_dir = resolved end
end

function M.cwd() return current end
function M.home() return home_dir end

function M.set_available(value) is_available = value and true or false end
function M.available() return is_available end

-- ---- cache ----------------------------------------------------------------

function M.lookup(path) return cache[path] end
function M.store(path, entry) cache[path] = entry end
function M.invalidate(path) cache[path] = nil end

return M
