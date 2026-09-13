# Where Scout blocks the main thread

Working notes, not a document for John. Written 2026-09-09 while chasing a beachball he could not
reproduce. Ranked by what actually costs him time.

## 0. The one that was actually freezing it · FIXED 2026-09-12

Everything below was real, and none of it was the beachball John kept hitting. The watchdog caught
three freezes — two on 1.0.6, one on 1.0.7 — and all three were the same line, 99% of the stuck
time in `SpotlightSearcher.publish()` → `NSMetadataItem.value(forAttribute:)` →
`MDItemCopyAttribute` → a synchronous XPC round trip to `mds`.

**Asking a result for an attribute is a trip to the Spotlight server, every time.** Measured one
attribute at a time over 1,500 real matches:

| attribute | asked per match | declared up front |
| --- | --- | --- |
| path | 3 µs (the item carries it) | nil — not a stored attribute |
| display name | 329 µs | 0.07 µs |
| content type | 257 µs | 0.06 µs |
| modification date | 349 µs | 0.06 µs |
| last-used date | 281 µs | 0.04 µs, identical values (101 apps compared) |
| size | 354 µs | 0.06 µs |

Five round trips per match is 1.57 ms a match, on the main thread, on every delivery. The old
comment on `sortDescriptors = []` said "ask the system for nothing but the matches" — which is the
trap exactly: asking for nothing up front means paying for everything one item at a time.

Declared values are present *during* gathering, not only after (29/29 and 4,428/4,428 on progress
reports), so Scout's streaming deliveries can use them.

The fix, in `SpotlightSearcher`: the five attributes go in `valueListAttributes` and are read with
`value(ofAttribute:forResultAt:)`; the path still comes from the item. And the whole query now lives
on its own serial queue (`operationQueue`), so `start()` opening a cold iCloud folder, a slow `mds`,
or a live update from iCloud churn can hold up file results but never the window. A generation
counter bumped on the caller's thread drops deliveries a newer search has overtaken.

Measured, same search both times:

| | before | after |
| --- | --- | --- |
| the searcher alone, whole Mac, "png", 6,818 matches | 3,658 ms | 16 ms |
| the real app, `--selftest png … wholeMac 14`, 493 files kept | **7,258 ms** | **144 ms** |

Section 2 below was a partial fix and the reason the wheel kept turning: it made the walk happen
less often and moved the *ranking* off the main thread, and left the walk itself — the expensive
part — exactly where it was.

`--selftest` now takes a scope and a duration and reports the longest the main thread went without
answering. That is the number to check before shipping anything that touches the results path:

    open -n -a /absolute/path/Scout.app --args --selftest png /tmp/out.txt wholeMac 14

## 1. Starting the query opens the scope folders — and one of them is iCloud's · FIXED 2026-09-09

`SpotlightSearcher.search(_:directories:)` calls `query.start()` on the main thread. A sample of the
running app caught it parked there for a full 3-second sample:

    -[NSMetadataQuery startQuery] → _recreateQuery → MDQuerySetSearchScope
      → _MDQueryCopyRealPathsInArray → accurate_realpath → open()

`open()` on `~/Documents`, timed directly, took **54,951 ms once and 0.0 ms on the next five tries**.
That folder carries `com.apple.file-provider-domain-id: com.apple.CloudDocs.iCloudDriveFileProvider`
— it is one of the iCloud "Desktop & Documents" folders, so the syscall goes through the file
provider daemon and blocks for as long as that daemon wants.

This is the beachball John reported. It fires **once per keystroke**, because `runSearch()` restarts
the query and the 90 ms debounce barely coalesces anything.

Fixed by:
- Raising the debounce from 90 ms to 250 ms, so typing a word starts two or three searches rather
  than eight.
- Opening every scope directory on a detached task and holding the query until that returns
  (`SpotlightSearcher.warmUp`). The blocking `open()` now happens off the thread that draws the
  window, so a cold search comes back late instead of freezing the Mac. It is deliberately not a
  cache — a folder that has gone cold again is opened again — because the point is only ever
  *where* the waiting happens.

`query.start()` itself was left on the main thread on purpose: it wants a run loop and its delivery
thread follows the starting thread, which is a much larger change for the same result.

**Not verified before-and-after.** The 55-second open has not been reproducible since; the folder
went warm and stayed warm. Verified by construction, by the suite, and by a self-test confirming
file results still arrive through the now-asynchronous start. Making it cold on demand would mean
evicting John's Documents folder, which is not worth doing to prove a point.

## 2. Re-ranking every match on every progress report · PARTIAL 2026-09-09 — see §0 (5d77fce…)

A 1-second sample of the shipped 1.0.0 put **571 of 667 main-thread samples (86%)** inside
`SpotlightSearcher.publish` → `SearchModel.rebuildSections` → `fileRows` → `Ranker.rank`.
Spotlight batches at 0.12 s, so that ran up to eight times a second, and each pass re-read six
metadata attributes per match out of the metadata server and re-scored the whole set.

Now: deliveries throttled to one per 350 ms while gathering (`DeliveryThrottle`, tested); the
exclusions, ranking and chip suggestions moved off the main actor with the superseded task
cancelled; the `--shot` path still ranks in place so a photograph is complete when taken.

Not verified before-and-after under load — reproducing the loaded state needs the panel open on
John's screen. Verified by construction and by an idle sample showing zero samples on that path.

## 3. Icons resolved inside the view body · FIXED 2026-09-09 (same commit)

`FileManager.fileExists` + `NSWorkspace.icon(forFile:)` ran per row per render — every keystroke and
every arrow key, for up to 500 rows. On a `/Volumes/` mount that has gone away, `fileExists` blocks
until the mount times out. Now memoised per path in `IconCache`.

Still true: the *first* lookup for a path is on the main thread. If a stranger searches a
disconnected network volume, that first draw still blocks. Worth moving to a placeholder-then-fill
if it ever shows up in a real report.

## 3b. Icons resolved on the main thread, properly this time · FIXED 2026-09-09

The cache above fixed the repeat cost and not the first one, and the first one was the expensive
one: most of John's results live under an iCloud-managed Documents folder, so `fileExists` and
`icon(forFile:)` both go through the file provider, which answers when it answers. Ten new paths a
keystroke, each one a trip to a daemon, on the thread drawing the window.

`RowIcon` now draws the icon for the file's *type* — which needs no disk — and asks the Finder for
the real one on a detached task. One slow answer redraws one row instead of stopping the panel. The
placeholder is the right icon for the kind, so most rows never visibly change.

## The watchdog

`App/HangWatchdog.swift`. Asks the main thread whether it is still there four times a second, and
when it stops answering for two seconds — which is when macOS draws the wheel — runs `sample`
against this process and writes the result to
`~/Library/Application Support/Scout/hangs/hang-<timestamp>.txt`, newest ten kept.

Proved by making the app hang on purpose for six seconds: the report appeared, said "not answering
for 2.2 seconds", and named the exact line. Stack traces and library names only, nothing about what
was being searched for, and it goes nowhere.

This exists because three separate causes have now been found for one symptom and each was found by
sampling a live process at the right moment. Waiting for that moment to be noticed by a person is
the slow way.

## 4–8. Found by audit, not yet measured against real use · NOT FIXED

- **Permissions heartbeat.** FIXED 2026-09-09, and it was worse than a hang. Every 2 s the tab read
  Documents, Desktop and Downloads to find out whether it was allowed to — and for a folder nobody
  has answered for yet, that read *is* the request, so macOS put up a prompt every two seconds for
  as long as the page was open. The page whose job is to show you your permissions was the thing
  demanding them. The answer is now remembered and re-asked only on an explicit user action
  (opening the page, Check again, Allow); the timer runs only the checks that cannot prompt. The
  Full Disk Access test also reorders to put the two single-file opens ahead of the mail-archive
  enumeration.
- **`Diagnostics.report()` runs on the main thread.** A bare `Task {}` inside a `@MainActor` class
  inherits main-actor isolation, so "Diagnose Sources…" enumerates all of `~/Library/Mail`, reads 40
  `.emlx` files and reads Contacts without ever leaving the main thread. `AppDelegate.swift:224`.
- **`Uninstall.leftovers()` called from a view body.** Recursive enumeration of the 352 MB
  Application Support folder on every render of the General tab. `SettingsView.swift:166`.
- **Launch-time scans on the main actor.** `AppIndex.scan()` does one `MDItemCopyAttribute` per app
  and `SettingsPaneIndex.scan()` opens a `Bundle` per `.appex` — roughly 200 Spotlight round-trips
  before the first keystroke. `SearchModel.swift:255`.
- **Mail body indexer never yields.** Off the main thread, so not a hang, but the loop re-enumerates
  the whole Mail tree per 1,500-file slice and Settings asks it for progress every 3 s, which is
  another full walk. It saturates disk I/O for hours after launch, which lengthens every blocking
  main-thread call above.

## The permission prompts that arrived at random · FIXED 2026-09-09

Separate from the Settings heartbeat above, and the one the user actually noticed. macOS asks for
Documents, Desktop and Downloads the first time something reads one, and Scout reads all three on
every search — `SpotlightSearcher` sets them as the query's search scopes, and `warmUp` opens them.

The panel is `.floating` with `hidesOnDeactivate = true` (`PanelController.swift:169, 172`) and
macOS draws its permission prompts in ordinary windows. So a prompt raised while somebody is typing
lands *behind* the panel. Nothing appears to happen, so nothing gets answered, so the permission
stays undecided and the next search asks again — and the prompt finally surfaces whenever the panel
happens to go away, with nothing on screen to explain it.

The app already knew this. `SearchModel.requestContactsAccess` and `requestRemindersAccess` both
route their prompts through the Settings window for exactly this reason, and both say so in a
comment. The folders had no such route because nothing asks for them deliberately — searching just
touches them.

Fixed by `AppDelegate.askAboutFoldersOnce`: opened once ever, at launch, with no panel in front,
off the main thread. `ScoutSettings.hasAskedForFolders` records that it happened whatever the
answer was, because asking twice is the bug.

Still open, if it ever matters: a Files section notice for the denied case, the way Contacts has
one. And on Whole Mac, a brand-new `/Volumes/` path can still raise its own prompt from the icon
lookup in `PanelRowView`.

## What the databases got right

Every index service (`MailSearchService`, `MessageSearchService`, `NotesSearchService`,
`ContactSearchService`, `ReminderSearchService`) is a real `actor`, so SQLite, FTS5, EventKit and
Contacts reads are all correctly off the main thread. There is no semaphore, no `NSLock`, no
`.wait()` and no `DispatchQueue.main.sync` anywhere in the app. Every hang found here is on the
file, Spotlight or ranking side.
