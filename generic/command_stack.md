# Command stack

Load the plugin in the profile where you want command stacking:

```lua
plugin.load("/path/to/lera-plugins/generic/command_stack.lua")
```

Turn it on with `/command-stack on`. It starts off. Run `/command-stack` to
see the current setting. The setting is saved per profile.

With stacking on, `look;score` runs two commands. Each part goes through your
aliases and input filters, the same as if you had typed it on its own line.
Use `;;` to send a literal semicolon. Start the line with `;` to send the rest
as one command. Change the separator with `/command-stack separator |`. The
separator cannot be `.`, which the speedwalk plugin uses.

For counted walks, use the speedwalk plugin's `.` command: `.3n2e` walks
north three times and east twice.

The plugin is an ordinary alias, with no core hook. A line holding the
separator is claimed by whichever alias was added first, so load this plugin
before any plugin whose aliases should also see stacked lines. One line can
hold up to 256 commands.
