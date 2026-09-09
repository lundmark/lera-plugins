# Autostepper mob ignores

```
/step mobignore add A gentle guide
/step mobignore remove A gentle guide
/step mobignore list
/step mobignore clear
```

`add` and `remove` take the entire remaining text as one name (no quotes
needed). `list` and `clear` accept no name. Bare `/step mobignore` also lists
entries. Missing names, unknown operations, extra arguments to list/clear,
and non-whitespace control characters are rejected without changing the list.
Duplicates are harmless; listing is sorted.

Names match the **entire GMCP monster display name**, lowercased with Lua's
`string.lower`, with leading/trailing whitespace removed and runs of Lua `%s`
whitespace collapsed to one space. This is not Unicode case folding.
Punctuation, articles, and all other words remain significant. For example,
`A gentle guide` matches `  a  GENTLE guide ` but not `a gentle guide captain`.
There are no substring, wildcard, or Lua-pattern matches; `.*` is literal.
Use the full name reported by roominfo, not just a kill-command keyword.
The legacy XML's `-mobignore` used Lua-pattern substring matching; this list
is intentionally safer and is not automatically imported.

Changes are saved immediately in autostepper's Lera plugin store, isolated by
Lera profile (not by explorer area). A failed save is reported; the in-memory
change still applies. The default list is empty. No friendly mobs are ignored
automatically.

Ignored mobs are excluded from both target selection and the remaining-mob
check in normal stepping, targets-only stepping, explorer clear/dive/leave,
and Chaos Sea farming. A room containing only ignored mobs can be traversed;
a real non-ignored mob later in the room list is still considered normally.
The underlying room snapshot is retained, so removing an ignore makes that
mob eligible again at the next decision.

Edits take effect at the **next room decision**; they do not interrupt an
already issued attack or manufacture a new room/combat event. Existing player
skip, auto-attack, navigation exclusions, difficulty/setup and safety behavior
are unchanged. This is not protection from a mob attacking you, nor a new
health/boss safety system. Ignoring a required gatekeeper may prevent the MUD
from allowing progress.

Chaos Sea runs stop at the cask or portal after clearing its non-ignored mobs,
even with unexplored rooms remaining. Farm mode starts its next instance from
there. If the server truncates that room's contents, the run stops with a warning
without declaring completion or restarting, since omitted mobs may still exist.

For example, ignore a guide while exploring:

```
/step mobignore add A gentle guide
/step explore chaossea
```
