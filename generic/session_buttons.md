# Session buttons

Load this plugin in each connection's profile:

```lua
plugin.load("/path/to/lera-plugins/generic/session_buttons.lua")
```

It shows the same rounded, three-row button strip above your existing layout.
The active connection is bright and bold; the others are dim. Click a button
to switch connections. Your layout tree and input/status bars stay as configured.
The strip appears only with multiple sessions and enough space to show it.

Use `/tabs off` to hide the strip, `/tabs on` to show it, or `/tabs` to toggle.
The setting applies to the connection where you run the command. Unloading the
plugin removes both the strip and its command. No layout configuration is needed.

Requires Lera's plugin top-bar and `session.active()` / `session.switch()` APIs
from [Lera PR #70](https://github.com/lundmark/lera/pull/70). Older builds report
the missing API when loading the plugin.
