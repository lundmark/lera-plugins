# Balatro client prototype

This is the public client for the native `/players/skuggis/balatro` game. It is
**under construction**. The native game is wizard-gated and the new Balatro
transport is not connected yet. This prototype must not be presented as a full
playable release; Joker coverage, bosses/campaign, progression, help/collection,
PvP and illustrated Joker/consumable assets remain in progress.

Load this directory as a Lera plugin and use `/balatro` to open the popup.
`/balatro png` selects original PNG card fronts; `/balatro ascii` uses text cards
and works without the GUI image API. The preference is saved in the plugin store.
The Hand and Shop tabs expose selection, play/discard, cash-out, purchases,
consumables and pack choices. The Profile tab shows deck access. Help opens native
help in the MUD output. Missing centre illustrations fall back to readable text.

Click up to five hand cards, then Play or Discard. Targets for consumables and
Arcana/Spectral packs use the same selected hand cards. `/balatro play` and
`/balatro discard` act on the current selection. `/balatro new` explicitly invokes
the native wizard test-run command; `/balatro resume` explicitly resumes saved
work. No timers, automatic gameplay, chat triggers or private Viking modules are
included. Refresh sends only `balatro status`; `/balatro status` prints local feed
counters. The server remains authoritative for legality, capacity, costs and
unlock restrictions.

The root subscription is `Balatro 1`. Schema 1 currently uses Info, Profile,
State, Cards, Shop and Score. Each logical message must be sent as a **full**
packet. Physical page/pages frames assemble first; then segment/segments areas
assemble, and only a complete twelve-part base snapshot is published. Incomplete
or malformed updates retain the prior complete state. Session/revision and opaque
IDs bind every action. Stale rendered targets send nothing. Local pointer targets
are never replaced by remote renders.

The 52 fronts and back are original geometric pixel graphics, generated from
repo-native code rather than copied desktop assets. Regenerate with Pillow:

```
python3 3scapes/balatro/tools/build_assets.py
```

Tests:

```
luajit tests/balatro_protocol_test.lua
luajit tests/balatro_window_test.lua
```

The tests cover atomic physical/logical paging, malformed/stale feeds, safe
session/revision commands, duplicate-click blocking, PNG/ASCII selection,
remote/local hit-test isolation and stale pointer rejection. Real GUI appearance,
preference lifecycle and end-to-end native delivery still need verification.
