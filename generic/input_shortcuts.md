# Input shortcuts

Load the plugin in the profile where you want command stacking or counted walks:

```lua
plugin.load("/path/to/lera-plugins/generic/input_shortcuts.lua")
```

Both features start **off**. Settings are persisted per profile through `store`.
Run `/input-shortcuts` to show settings, or configure them with:

```
/input-shortcuts stack on|off
/input-shortcuts walk on|off
/input-shortcuts separator CHAR
/input-shortcuts prefix TEXT
```

The separator defaults to `;` and must be one printable ASCII character without
spaces. The walk prefix defaults to `#` and accepts 1–15 such characters.

With stacking enabled, `look;score` runs two commands. A doubled separator is
literal: `say a;;b;look` sends `say a;b` then `look`. A leading separator sends
the remainder as one command: `;say a;b` sends `say a;b`, and `;#2n` sends `#2n`
unchanged by this plugin. Empty parts are skipped, including a trailing separator
or a lone `;`. Whitespace-only parts are preserved. The leading-separator rule
takes precedence: `;;look` sends `;look`.

With walking enabled, `#3n 2e` sends `north` three times and `east` twice.
Use `(ne)` for `northeast`, `(nw)`, `(se)`, `(sw)` for the other diagonals, and
`(open gate)` for a custom step. Bare `ne` means north then east. Horizontal
spaces outside parentheses are ignored, except between digits of a count;
spaces inside custom steps are preserved. Directions are emitted as full names
(`north`, `south`, `east`, `west`, `up`, `down`, and the diagonals).
The core parser clamps each count to 255 and treats zero as one. Its
`(forward/backward)` syntax is accepted; empty forward steps and `.pause` steps
are skipped, as in the reference implementation. This is immediate execution,
not a timed walk.

Stack parts and walk steps use `mud.execute`, passing through aliases and input
filters. Thus `#2n;look` expands into two north moves followed by look. Literal
separators use a one-call passthrough marker so this plugin cannot recursively
split them. A literal part claimed by this plugin returns its exact text to the
input filters; later aliases do not run for that part.

Each expansion allows at most 1,024 plugin dispatches and nesting depth 8,
shared across stacks, walks, and synchronous alias re-entry. Intermediate stack
parts count toward the dispatch budget too. An oversized outermost batch is rejected
before it is emitted; a limit reached in nested expansion stops the remaining
work and prints a message. Commands already sent cannot be recalled. These
guards cannot control recursion or extra sends entirely inside other plugins.

Only enabled features register aliases. Configuration changes remove and
re-register them (stack before walk), moving them to the **end of the alias order**.
Unloading removes both aliases and the slash command. No core `on_command`
hook or hook priority is used.

Aliases run in insertion order and the first match wins; plugin `on_load` runs
in `plugin.load()` order. With speedwalk loaded first, `.n;s` is claimed whole
by speedwalk's `^\.(.+)$` alias. This is expected. With input_shortcuts loaded
first and stacking enabled at load, `.n;s` is split into `.n` and `s`, each
re-run through aliases. Enabling or reconfiguring shortcuts later changes that
order. The default counted-walk prefix `#` does not collide with speedwalk's `.`.

The walk regex accepts only complete sequences of counted direction letters or
parenthesized steps. Names such as `#chaossea-home` and arbitrary text after the
prefix are left for other aliases. The callback additionally normalizes and
validates with `speedwalk.parse`. If parsing fails after the regex matched, the
original text is sent unchanged through input filters. Unlike PR #78's pre-alias
hook, an alias cannot fall through to later aliases after it has matched.
Nested parentheses and incomplete count/step syntax do not match the walk alias.
