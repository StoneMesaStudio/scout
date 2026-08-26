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

**Contacts ⌘2** — every field on the card, matched here rather than by Apple's name predicate,
which returns names that merely sound like the one you typed and misses ones that don't.

**Mail ⌘3** — subject and sender from Mail's own Envelope Index, plus what the messages actually
say, from an index Scout builds over the message files.

**Messages ⌘4** — Scout's own full-text index, because macOS barely indexes texts. It reads
`chat.db` read-only, recovers text from the styled blobs recent macOS leaves the plain column
empty for, and tops itself up incrementally.

**Apps ⌘5** — ordered by what you actually launch, not alphabetically.

**System ⌘6** — the settings panes this Mac has, found by scanning rather than from a list that
rots, with keywords so "full disk access" finds Privacy & Security.

**Notes ⌘7** — the words inside your notes, not just their titles. Notes stores its text as a
gzipped protobuf in a Core Data database with no read API, which is why nothing outside Notes.app
can search it — Spotlight included. Scout ungzips it, keeps its own index, and re-reads a note
whenever it changes. Locked notes stay locked: only their titles are searchable, and the row says
so rather than pretending the note is empty.

**Reminders ⌘8** — by title, by list, or by the note attached. EventKit has no text search for
reminders at all, so Scout reads them and matches here. What is still outstanding sorts above what
is done, and what is done is still findable.

Results never blend across lanes. A file search returns files.

**Arranging them** — the sources live in one capsule under the field, each wearing the real icon
of the app it reads from, asked of the system so it stays right through an OS update. A source
that is off goes grey; one that is on keeps its colour and gains a whisper of a plate. Drag them
into any order and the result sections follow; the number on a disc is where it sits, so ⌘1 is
whatever you put first. ⌘0 turns them all on, then all off — zero sources is a real state, and it
is the quick way down to one. Right-click for icons, labels, or both, the way Mail's toolbar does.

**Getting through a long list** — every heading carries a *Show only Mail* link that drops the
other seven and opens that one out. ⌥↑ and ⌥↓ jump from section to section. How many each source
shows before offering the rest is one number in Settings.

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

What macOS makes you allow, and what Scout can and cannot ask for itself — all of it explained
on first run and listed again under Settings › Permissions:

- **⌘-Space** belongs to Spotlight until the user unticks it in Keyboard Shortcuts. ⌥-Space works
  from the first launch either way.
- **Full Disk Access** is required for the Mail, Messages and Notes lanes. Without it those lanes
  say so and offer the settings pane, rather than showing an empty list that reads as "nothing
  found".
- **Contacts** and **Reminders** are the two an app is allowed to ask about itself. Scout does not
  ask while you are typing — a prompt that appears by itself is one people dismiss without reading.
  The lane shows a notice with a button, so the prompt arrives because you asked for it.

## Why it isn't on the App Store

Sandboxing is mandatory there, and a sandboxed app can only see files handed to it one at a time
through an open panel. Full Disk Access — which the Mail, Messages and Notes lanes need — cannot
be granted to a sandboxed app at all. Scout ships as a signed, notarized direct download instead.

## Licence

Scout is free software, under the **GNU General Public License, version 3 or later** —
see [LICENSE](LICENSE). You may use it, read it, change it and pass it on; anything you
pass on has to carry the same freedoms and the same source.

Two things the licence does not hand over:

- **The name and the icon.** "Scout" and the app's mark belong to Stone Mesa Studio, LLC.
  Fork the code freely; ship it under your own name.
- **A signing identity.** `bin/release.sh` notarizes with this project's Apple Developer
  ID (`TEAM_ID`, and credentials from `~/.appstoreconnect/`). A fork needs its own — a
  Developer ID Application certificate, which is not the same certificate the App Store
  uses.

Scout depends on nothing but Apple's own frameworks. There is no third-party code in the
repository to reconcile with the GPL.
