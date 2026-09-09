# Where Scout blocks the main thread

Working notes, not a document for John. Written 2026-09-09 while chasing a beachball he could not
reproduce. Ranked by what actually costs him time.

## 1. Starting the query opens the scope folders — and one of them is iCloud's · NOT FIXED

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

Fix, in order:
- Raise the debounce from 90 ms to ~250 ms. Fewer restarts, no behaviour anyone can see.
- Warm the scope directories on a background task whenever the scope changes, and hold the search
  until the warm-up for that scope has finished. That moves the blocking `open()` off the thread
  that draws the window: a cold search comes back late instead of freezing the Mac.
- Do not try to move `query.start()` itself off the main thread. It wants a run loop and the
  delivery thread follows the starting thread; that is a much larger change for the same result.

## 2. Re-ranking every match on every progress report · FIXED 2026-09-09 (5d77fce…)

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

## 4–8. Found by audit, not yet measured against real use · NOT FIXED

- **Permissions heartbeat.** Every 2 s while the Settings ▸ Permissions tab is open, on the main
  actor: `contentsOfDirectory` on `~/Library/Mail`, byte reads of `chat.db` and `NoteStore.sqlite`,
  `contentsOfDirectory` on Documents/Desktop/Downloads. The Documents one is the same iCloud folder
  as §1. `SettingsView.swift:401`, `Permissions.swift:71`.
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

## What the databases got right

Every index service (`MailSearchService`, `MessageSearchService`, `NotesSearchService`,
`ContactSearchService`, `ReminderSearchService`) is a real `actor`, so SQLite, FTS5, EventKit and
Contacts reads are all correctly off the main thread. There is no semaphore, no `NSLock`, no
`.wait()` and no `DispatchQueue.main.sync` anywhere in the app. Every hang found here is on the
file, Spotlight or ranking side.
