# Scout

A menu-bar search panel for macOS that replaces ⌘-Space.

Scout reads the same index Spotlight and Finder read — it builds no index of its own for files —
but it does its own filtering and its own ordering, which is the part Apple does not expose.

## What it does today (phase one)

- **Panel on a global hotkey.** ⌥-Space works out of the box; ⌘-Space works once Spotlight's own
  shortcut is turned off. Menu bar shows an icon only; no Dock icon, no window at launch.
- **Two scopes.** *My Files* — Documents, iCloud Drive, Desktop, Downloads — is the default.
  *Whole Mac* is one click or ⌘L.
- **Exclusions, not demotions.** Developer and system folders are removed from file results
  entirely, and the number removed is shown so nothing vanishes silently.
- **Ranking that can be argued with.** Name match quality, then location weight as a multiplier,
  then recency, depth and prior use. Every weight is a named constant in `Ranker.Weights`.
- **Duplicate collapsing.** Same name, same size, several places — one row.
- **One exact app match pinned on top,** so typing "Mail" and pressing Return still launches Mail.
- **Reveal in Finder** on ⌘Return; **Tab** narrows the search into the selected folder.

Mail, Messages, Apps and System get their own lanes in later phases. Files never blend with them.

## Layout

    App/          the panel, the hotkey, the menu bar item — everything that needs a window server
    Core/         ScoutCore: scopes, exclusions, ranking, the Spotlight query. Pure logic, tested.
    bin/          preflight.sh — build + test gate, identical across the studio's Swift apps

## Building

    xcodegen generate          # Scout.xcodeproj is generated, never committed
    bin/preflight.sh           # builds the app and runs the ranking suite

`swift test --package-path Core` runs the same tests without Xcode.

## Why it isn't on the App Store

Sandboxing is mandatory there, and a sandboxed app can only see files handed to it one at a time
through an open panel. Full Disk Access — which the Mail and Messages lanes need — cannot be
granted to a sandboxed app at all. Scout ships as a signed, notarized direct download instead.
