# Session buttons

A strip of rounded tabs, one per session. The active session is bright and
bold; the others are dim. Click a tab to switch to that session, as Ctrl+1/2
does.

The plugin draws the strip; your profile decides where it goes. Load it in
each session's profile and give it a slot in a sized, collapsing split:

```lua
local wm = require("wm")
local tabs = plugin.load("session_buttons")
wm.set_layout({
  split = "v", size = 3, collapse = true,
  top = "sessions",
  bottom = my_layout,   -- the layout you already had
})
wm.assign("sessions", tabs)
```

`size = 3` gives the strip exactly three rows. `collapse = true` folds it
away, returning the rows to the rest of the layout, whenever the plugin's
`visible()` says there is nothing to show: a single session, or `/tabs off`.
It also folds away when the area is too short to spare the rows.

Use `/tabs off` to hide the strip, `/tabs on` to show it, or `/tabs` to toggle.
The setting applies to the session where you run the command. Unloading the
plugin removes the command; the slot then collapses.

Requires Lera's `session.active()` / `session.switch()` and sized, collapsing
splits in `wm`. Older builds report the missing API when loading the plugin.
