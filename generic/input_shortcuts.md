# Input shortcuts

Load the plugin in the profile where you want command stacking or counted
speedwalks:

```lua
plugin.load("/path/to/lera-plugins/generic/input_shortcuts.lua")
```

Enable either feature with `/input-shortcuts stack on` or
`/input-shortcuts walk on`. Both start off. Run `/input-shortcuts` to see the
current settings. The settings are saved per profile.

With stacking enabled, `look;score` runs two commands. Use `;;` inside a
stack to send a literal semicolon. Start the line with `;` to send the rest
as one command. Change the separator with `/input-shortcuts separator |`.

With walking enabled, `#3n 2e` sends north three times and east twice.
Use `(ne)` for northeast and `(open gate)` for a custom command. Change the
prefix with `/input-shortcuts prefix !`. An unrecognized route such as
`#chaossea-home` still goes to your aliases.

Stacked commands go through aliases and input filters. Steps in a counted
walk go through input filters and use full direction names. An expansion can
contain up to 1,024 commands. The plugin requires Lera's pre-alias
`on_command` hook.
