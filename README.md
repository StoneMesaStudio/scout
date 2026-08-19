# Scout

A menu-bar search panel for macOS that replaces ⌘-Space.

Scout reads the same index Spotlight and Finder read — it builds no index of its own for files —
but it does its own filtering and its own ordering, which is the part Apple does not expose.

## What it does

**Files ⌘1** — the default lane.
- *My Files* (Documents, iCloud Drive, Desktop, Downloads) or *Whole Mac*, one click or ⌘L apart.
- Developer and system folders are removed outright, and the number removed is shown so nothing
  vanishes silently.
- Filter chips under the field for folder, kind and date, derived from the results on screen so
  every chip offered would actually narrow this search. A chip is a wall: what fails it is gone
  before ranking runs.
- Pinned places get a chip on every search.
- Duplicate collapsing, reveal in Finder on ⌘Return, Tab to search inside a folder.
- One exact app-name match pins to the top, so typing "Mail" and pressing Return still launches Mail.

**Mail ⌘2** — subject, sender and body, from the Spotlight index Apple's own importer fills.

**Messages ⌘3** — Scout's own full-text index, because macOS barely indexes texts. It reads
`chat.db` read-only, recovers text from the styled blobs recent macOS leaves the plain column
empty for, and tops itself up incrementally.

**Apps ⌘4** — ordered by what you actually launch, not alphabetically.

**System ⌘5** — the settings panes this Mac has, found by scanning rather than from a list that
rots, with keywords so "full disk access" finds Privacy & Security.

Results never blend across lanes. A file search returns files.

## Ranking

Name match quality first (exact › whole word › word prefix › prefix › substring › text inside the
document), then location weight as a **multiplier**, so a perfect match in a cache still loses to a
good one in Documents. Recency is weighted below the gap between two match qualities, so being
recent reorders equally good matches but never promotes a worse one. A date written into a filename
is trusted over the filesystem's, because in an imported archive the latter records the day of the
copy and nothing else. Something you picked before for the same search goes first, full stop.

Every weight is a named constant in `Ranker.Weights`, and every rule has a test that states it in
terms of a real search.

## Layout

    App/          the panel, the hotkey, the menu bar item — everything that needs a window server
    Core/         ScoutCore: scopes, exclusions, ranking, the Spotlight query. Pure logic, tested.
    bin/          preflight.sh — build + test gate, identical across the studio's Swift apps

## Building

    xcodegen generate          # Scout.xcodeproj is generated, never committed
    bin/preflight.sh           # builds the app and runs the ranking suite

`swift test --package-path Core` runs the same tests without Xcode.

## Permissions

Two things Scout cannot do for itself, both explained on first run:

- **⌘-Space** belongs to Spotlight until the user unticks it in Keyboard Shortcuts. ⌥-Space works
  from the first launch either way.
- **Full Disk Access** is required for the Mail and Messages lanes. Without it those lanes say so
  and offer the settings pane, rather than showing an empty list that reads as "nothing found".

## Why it isn't on the App Store

Sandboxing is mandatory there, and a sandboxed app can only see files handed to it one at a time
through an open panel. Full Disk Access — which the Mail and Messages lanes need — cannot be
granted to a sandboxed app at all. Scout ships as a signed, notarized direct download instead.
