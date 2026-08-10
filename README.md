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
| `help` | In-client help system |
| `input_echo` | Display sent commands in output |
| `push_notify` | Push notifications via Pushover |

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
