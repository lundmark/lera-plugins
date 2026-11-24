# Session buttons

In each connection's profile, wrap your existing layout in a collapsing split
and assign the plugin to its first slot:

```lua
local wm = require("wm")
local tabs = assert(plugin.load("/path/to/lera-plugins/generic/session_buttons.lua"))
wm.set_layout({ split = "v", size = 3, collapse = true,
                top = "sessions", bottom = my_layout })
wm.assign("sessions", tabs)
```

It shows the same rounded, three-row button strip above your existing layout.
The active connection is bright and bold; the others are dim. Click a button
to switch connections. Your layout tree and input/status bars stay as configured.
The strip appears only with multiple sessions and enough space to show it.

Use `/tabs off` to hide the strip, `/tabs on` to show it, or `/tabs` to toggle.
The setting applies to the connection where you run the command. Unloading the
plugin hides the strip and removes its command.

Requires [Lera's sized, collapsing splits and session-switch APIs](https://github.com/lundmark/lera/commit/926d7023e0fc855df93e6b311e7cf15c2fee7e62).
