# Lera Plugins

Plugin collection for the Lera MUD client.

## Legacy parity validation

The repeatable validation workflow, its public/private trust boundary, and safe
operating rules are documented in
[validation/README.md](validation/README.md). Public CI verifies committed
artifact consistency only; it cannot authenticate private approval or private
legacy-source parity.

## Structure

```
lera-plugins/
├── generic/      # Plugins that work with any MUD
├── 3scapes/      # Plugins specific to 3scapes MUD
└── examples/     # Example/test plugins for learning
```

## Installation

Copy plugins to your profile's plugin directory or load them directly:

```lua
plugin.load("/path/to/lera-plugins/generic/deadmans")
```

## Generic Plugins

| Plugin | Description |
|--------|-------------|
| `autologin` | Automatic login on connect |
| `deadmans` | Idle detection with warnings and auto-disconnect |
| `gmcp_state` | Subscribes to GMCP packages, tracks state, formats vitals bars (`/gmcp`) |
| `help` | In-client help system |
| `input_echo` | Display sent commands in output |
| `mxp_links` | Makes MXP `<send>`/`<a>` links usable via a popup picker (`/link`) |
| `push_notify` | Push notifications via Pushover |

### Protocol plugins

`gmcp_state` and `mxp_links` turn a Lera protocol API into features, the way
`chat_monitor` consumes `mip.*`. Both are MUD-agnostic; neither owns layout or
keys, because pane placement and `bind.*` are composition-level and `bind` is
not in the plugin sandbox. A profile composes them:

```lua
local gs = plugin.load("gmcp_state")
local links = plugin.load("mxp_links")

-- Vitals bars in a pane the profile owns.
for _, row in ipairs(gs.vitals_lines(width, height)) do ... end

-- Keys belong to the profile, not the plugin.
bind.add("ctrl+l", function() links.open() end)

-- Plugins have no io, so a profile writes the observation itself.
local f = io.open(path, "w"); f:write(gs.report()); f:close()
```

There is deliberately **no MCCP plugin**: MCCP2 decompression is transparent in
C and its entire Lua surface is one boolean, `mud.mccp_active()`. There are no
events or payloads for a plugin to consume.

## 3scapes Plugins

| Plugin | Description |
|--------|-------------|
| `autostepper` | Automatic speedwalk execution |
| `chat_monitor` | Chat channel monitoring and logging |
| `guild_druid` | Druid guild utilities |
| `kill_trigger` | Combat automation triggers |
| `mapper` | Room mapping and pathfinding |
| `mapview` | Visual map display |
| `mercenary` | Mercenary management |
| `minimap` | Compact minimap overlay |
| `player_stats` | Player statistics tracking |
| `roominfo` | Room information display |
| `speedwalk` | Speedwalk path management |
| `stats_window` | Statistics window UI |

## Example Plugins

| Plugin | Description |
|--------|-------------|
| `test_plugin` | Minimal plugin demonstrating hooks |
| `store_test` | Example of persistent storage |
| `mip_example` | MIP protocol integration example |

## Writing Plugins

See `examples/test_plugin.lua` for a minimal template. Plugins export a table with optional hooks:

```lua
local M = {}

M.name = "my_plugin"
M.version = "1.0"

function M.on_load() end
function M.on_unload() end
function M.on_line(line) return line end
function M.on_send(text) return text end
function M.on_connect() end
function M.on_disconnect() end

return M
```
