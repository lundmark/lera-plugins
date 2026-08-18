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

## Commands

Every plugin command here is registered through the command registry, so it
appears in `/help` and the `/` palette and is owned by the plugin that declared
it:

```lua
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

function M.on_load()
  if not command then return end
  local id, err = command.register({
    name = "/thing",
    usage = "/thing [status|set <value>]",
    summary = "One line for /help and the palette",
    accepts_args = true,
    handler = dispatch,        -- receives everything after "/thing"
  })
  ...
end
```

The registry installs `^/name(?:\s+(.*))?$` and hands the handler the
remainder, so a plugin splits its own subcommands and validates its own
arguments rather than declaring one alias pattern per form.

`chat_monitor` is the one conditional registration: it claims `/chat` only when
`command.get("/chat")` is nil, so a profile that registered its own `/chat`
before plugins loaded keeps it — a plugin cannot replace a profile-owned
command. Hosted mode used to be that case; it no longer registers one.

Two plugins keep raw `alias.add` alongside their command, for input that cannot
be spelled as a slash token: `speedwalk`'s `.`, `..`, `.,`, `.place` and
`.from-to`, and `autostepper`'s `-`, `-.`, `->` and `-!`. Those are movement
syntax; everything word-shaped lives under `/speedwalk` and `/step`.

## Generic Plugins

| Plugin | Commands | Description |
|--------|----------|-------------|
| `autologin` | `/autologin` | Automatic login on connect |
| `deadmans` | `/deadmans` | Idle detection with warnings and auto-disconnect |
| `gmcp_state` | `/gmcp` | Subscribes to GMCP packages, tracks state, formats vitals bars |
| `help` | *(none)* | Help content library; commands come from `require('commands')` |
| `input_echo` | *(none)* | Display sent commands in output |
| `mxp_links` | `/link` | Makes MXP `<send>`/`<a>` links usable via a popup picker |
| `push_notify` | `/pushn` | Push notifications via Pushover |

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

| Plugin | Commands | Description |
|--------|----------|-------------|
| `autostepper` | `/step`, `-` `-.` `->` `-!` | Automatic speedwalk execution |
| `chat_monitor` | `/chat` | Chat channel monitoring and logging (MIP or GMCP) |
| `guild_druid` | `/dauto`, `/resetgxp` | Druid guild utilities |
| `kill_trigger` | `/killers` | Combat automation triggers |
| `mapper` | `/map` | Room mapping and pathfinding |
| `mapview` | `/mapview` | Visual map display |
| `mercenary` | *(none)* | Mercenary management |
| `minimap` | `/minimap` | Compact minimap overlay |
| `player_stats` | *(none)* | Player statistics tracking |
| `roominfo` | *(none)* | Room information display |
| `speedwalk` | `/speedwalk`, `.` `..` `.,` `.place` | Speedwalk path management |
| `stats_window` | *(none)* | Statistics window UI |

### Chat sources: MIP and GMCP

`chat_monitor` can take channel lines from either protocol. 3K sends the same
line over both, so only one feeds the pane at a time:

| Traffic | Source |
|---------|--------|
| Channel lines | MIP `CAA`, or GMCP `Comm.Channel.Text` once it arrives |
| Tells | MIP `BAB` always |
| Emotes | MIP `BAG` always |

In the default `auto` mode the pane starts on MIP and switches to GMCP the
first time a real `Comm.Channel.Text` arrives — negotiation alone is not
enough, because a server can negotiate GMCP and never send the package. The
latch resets on disconnect. Pin it with `/chat source mip|gmcp|auto` or
`chat.set_source(mode)`.

The latch covers channels only. `Comm.Channel.Text` carries no direction field,
so it cannot distinguish an incoming tell from one of your own the way MIP
`BAB` can; suppressing MIP tells would silence them outright.

Both protocols name a channel the same way (`wiz`), so both land on the same
`chat_wiz` line type and its color, label and gags survive a source change. The
payload shapes differ, though — MIP `CAA` text is a pre-formatted line
(`Simon <Wiz>: hi`) while GMCP carries `{channel, talker, text}` with a bare
body — so a GMCP message renders its own `talker: ` prefix unless the line type
has a prefix set through `configure()`.

`/chat source` reports which protocol is live and what each has delivered,
including anything under `Comm` that could not be read:

```
[chat] source: mip (auto; no GMCP chat seen yet)
[chat] mip: 143 messages    gmcp: 0 mapped, 2 unmapped
[chat] last unmapped: Comm.Channel.List (fields: channels)
```

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
