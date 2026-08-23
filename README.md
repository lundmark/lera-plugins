# Lera Plugins

> **Mirrored into [lundmark/lera](https://github.com/lundmark/lera) at
> `plugins/`** as a git subtree. Day-to-day development happens there and is
> pushed here periodically; PRs against this repository are welcome and get
> pulled back into lera after merge. Both directions preserve history, which
> is why a merged PR here reappears in lera with its original commits.

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

## Image surfaces

Directory plugins can load PNG assets relative to their own root and place
them over cell-aligned rectangles:

```lua
local icon, err = ui.image_load("assets/icon.png")
assert(icon, err)

function M.on_render()
  local rect = ui.rect(4, 2, 6, 3)
  ui.text(rect, "[map]") -- always draw useful fallback cells first
  ui.image(rect, icon, { fit = "contain", filter = "nearest" })
end
```

`contain` preserves aspect ratio; `stretch` fills the rectangle. `nearest`
preserves pixel art; `linear` smooths scaling. Loaded handles are immutable
snapshots owned by the exact plugin load and become stale when it unloads.
Profile code and single-file plugins have no asset root and cannot load images.

There is deliberately no `images_supported()` branch. TTY and other cell-only
frontends keep the fallback cells, while image-capable frontends composite the
optional surface over the same layout.

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
| `guild_viking` | `/vik`, `resetvikxp` | Vikings guild: protocol/state, a 12-page tab-bar pane (`/vik <page>` or `/vik page <key>`), popup board overlays (`/vik map\|sea\|voyage\|cityplan\|war`), detached-page parity (`/vik pop <page>`), map pathfinding with point-of-interest travel and mission/errand dispatch (always available, no setting), and three client-side automations (auto-trade, auto-raid, auto-voyage; see below), which ship off by default |
| `kill_trigger` | `/killers` | Combat automation triggers |
| `mapper` | `/map` | Room graph from GMCP Room.Info, waypoints, name search |
| `mapview` | `/mapview` | Visual map display |
| `mercenary` | *(none)* | Mercenary management |
| `minimap` | `/minimap` | Compact minimap overlay |
| `player_stats` | *(none)* | Player statistics tracking |
| `roominfo` | *(none)* | Room information display |
| `speedwalk` | `/speedwalk`, `.` `..` `.,` `.place` | Speedwalk path management |
| `stats_window` | *(none)* | Statistics window UI |

### Chat sources: MIP and GMCP

`chat_monitor` can take chat from either protocol. 3K sends the same lines over
both, so exactly one source feeds the pane at a time:

| Traffic | MIP | GMCP |
|---------|-----|------|
| Channel lines | `CAA` | `Comm.Channel.Text`, `channel = "wiz"` etc. |
| Tells | `BAB` | `Comm.Channel.Text`, `channel = "tell"` |
| Souls | `BAG` | `Comm.Channel.Text`, `channel = "soul"` |

In the default `auto` mode the pane starts on MIP and switches to GMCP the
first time a real `Comm.Channel.Text` arrives — negotiation alone is not
enough, because a server can negotiate GMCP and never send the package. The
latch then suppresses **all three** MIP handlers, not just `CAA`; anything less
double-prints. Pin it with `/chat source mip|gmcp|auto` or
`chat.set_source(mode)`.

Having seen GMCP chat is **remembered across sessions** (`gmcp_chat_seen` in the
plugin's store). Without that memory the very first line of every session
duplicates: both protocols carry it, MIP arrives first, so it prints before the
latch can flip. A profile that has proved GMCP once starts on GMCP and never
gives MIP the opening. The per-connection latch and the counters still reset on
disconnect; the memory does not, or every reconnect would re-earn its duplicate.

The escape hatch, if a server stops sending GMCP chat, is `/chat source mip` —
which persists, being a pinned mode. `/chat source` distinguishes a latch earned
this session from one remembered, so a silent pane is diagnosable:

```
[chat] source: gmcp (auto; remembered from an earlier session)
[chat] mip: 0 messages    gmcp: 0 mapped, 0 unmapped
```

Both protocols name a channel the same way (`wiz`), so both land on the same
`chat_wiz` line type and its color, label and gags survive a source change.

### The lead-in

MIP text is a finished line (`Simon <Wiz>: hi`), which is why the default chat
prefix is empty. GMCP text is the body alone, with everything else in sibling
fields:

```json
{ "text": "test", "talker": "Simon", "targets": ["Lennart"], "channel": "tell" }
{ "text": "smiles at you.", "talker": "Simon", "channel": "soul" }
```

So a GMCP message needs a lead-in rendered for it. Three sources, in order:

1. A `prefix` **field on the message**, used verbatim. Only the server knows how
   it phrases `You tell X, Y: ` against `X tells you: `.
2. A `prefix` **set through `configure()`**.
3. Otherwise **synthesized**: `talker: ` normally, `talker ` for soul-like
   channels (whose text continues the name), and `talker -> a, b: ` when
   `targets` names recipients other than the talker.

A server-sent prefix outranking a configured one is deliberate, and it is the
one place `configure()` does not win. One setting cannot serve both protocols: an
empty emote prefix is correct for MIP text reading `Simon smiles at you.` and
wrong for a GMCP body of `smiles at you.`. The server knows which it sent; the
setting cannot. Configured prefixes still apply to every MIP line and to any
GMCP line the server sent no prefix for.

Synthesis is guesswork about server-side phrasing and exists only so the pane
reads sensibly before a server sends its own `prefix`.

The lead-in and the body are joined by exactly one space, added only when the
prefix does not already end in whitespace — the built-in defaults do (`[Bob] `),
a server-sent one need not (`Simon tells you:`).

### Two-tone colouring

A line with a lead-in renders the lead-in in the line type's colour and the body
in `text_color` (default `white`):

```
[09:57] Simon tells you: are you there?
        ^^^^^^^^^^^^^^^^ type colour
                         ^^^^^^^^^^^^^^ text_color
```

A line *without* a lead-in stays entirely in its type colour. That is deliberate:
MIP text is itself a formatted line (`Simon <Wiz>: hi`), so greying the body would
throw away the per-channel colour that distinguishes one channel from another.

```lua
chat.set_text_color("bright_black")            -- global; "white" by default
chat.configure("chat_wiz", { text_color = "yellow" })   -- per line type
```

Colour spans are painted after wrapping, so escape codes never enter the width
arithmetic, and each wrapped row re-opens in the colour it continues — a body
that wraps stays in `text_color` on every row rather than reverting.

### Direction

`Comm.Channel.Text` has no direction of its own, and `targets` only reveals it
to a client that knows its own character name. When the server sends
`"direction": "in"` or `"out"`, two channels map onto the built-in directional
types:

| Channel | `direction` | Line type |
|---------|-------------|-----------|
| `tell` | `in` / `out` | `tell_in` / `tell_out` |
| `soul` | `in` / `out` | `emote_in` / `emote_out` |

That is what keeps an incoming tell reaching the `tells` push channel and an
outgoing one silent, whichever protocol delivered it. Without a recognised
`direction` the line stays an ordinary `chat_tell` / `chat_soul` type rather than
being guessed into the wrong one — visible in that it notifies on channel `tell`
instead of `tells`. `direction` on any other channel is ignored.

`/chat source` reports which protocol is live and what each has delivered,
including anything under `Comm` that could not be read:

```
[chat] source: mip (auto; no GMCP chat seen yet)
[chat] mip: 143 messages    gmcp: 0 mapped, 2 unmapped
[chat] last unmapped: Comm.Channel.List (fields: channels)
```

### Vikings guild automation

`guild_viking` ships three client-side automations, each a straight port of the matching
LEGACY behavior: an arbitrage/stock-offload **auto-trader**, an idle-longship **auto-raider**,
and a voyage-chart **auto-voyager**. Every one of them sends commands with no direct action from
the player, so **all three ship OFF and must be turned on deliberately**:

| Automation | Command | Setting |
|------------|---------|---------|
| Auto-trade | `/vik trader [<sub>]` (bare opens the settings menu) | `auto_trade` |
| Auto-raid | `/vik raid [<sub>]` | `auto_raid` |
| Auto-voyage | `/vik voyage auto [<sub>]` | `auto_voyage` |

Auto-raid and auto-voyage tick on a flat interval (20s / 8s) from the guild's regular per-second
update timer. Auto-trade's 30s is a *planning* interval only — once a plan is drawn, its paced
runner sends one command every 2s and waits up to 20s for MIP confirmation before the next, so
auto-trade can send more often than every 30s while working through a multi-command plan. All
three are gated at the very first line of their tick function on the setting above — nothing is
ever sent until a player flips it on with the command or its menu. Every automated send goes
through the normal `mud.send` path, so if `deadmans` is loaded, its idle-detection `on_send`
governance applies to these sends exactly as it would to a manually-typed command. Settings
persist across reconnects via the guild's own store. `/vik status` reports each automation's
on/off state and its last-action/next-check timing; the Stats page shows the on/off and
last-action half of that (not the next-check timing).

**Deadmans and pointer-driven sends.** `deadmans` resets its idle timer only from typed input
(`on_input`), never from pointer input. That has been true since stage 3's popup click-to-send
paths, but stage 4 raises the stakes: the map popup's point-of-interest travel and the People
pane's mission/errand "Run There" button are both pointer-driven and can each dispatch a whole
path of movement commands, not just one. A player who has been reading rather than typing past
`deadmans`' `block_time` can click one of these and have deadmans silently swallow every command
in the path.

### Interop hooks

Two stage-0 hooks let other plugins react to `kill_trigger` and `stats_window` without
depending on their internals.

**`kill_trigger.on_monster_died(cb)` / `remove_kill_listener(id)`** — a cross-plugin kill
feed. `cb(killer, victim)` fires once per killing blow, in registration order, independent of
`kill_trigger`'s own command-execution enable flag (a disabled `/killers` still reports kills to
listeners). A listener's error is pcall-guarded and does not stop the rest. Listeners die with
`kill_trigger`'s unload, so a producer plugin should re-register from `on_setup` rather than
assume a one-time registration survives a reload:

```lua
local kt = plugin.get("kill_trigger")
local id
function M.on_setup()
  kt = plugin.get("kill_trigger")
  if kt then
    id = kt.on_monster_died(function(killer, victim)
      -- react to the kill
    end)
  end
end

function M.on_unload()
  if kt and id then kt.remove_kill_listener(id) end
end
```

**`stats_window.register_guild(name)`** — adds a guild plugin's name to the probe list
`stats_window` uses to find a guild-stats section to render (`guild_druid` is first and
untouched). Registering resets the cached probe so the next render picks up the newcomer:

```lua
local sw = plugin.get("stats_window")
if sw then sw.register_guild("guild_viking") end
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
