import AppKit
import Contacts
import EventKit
import Observation
import ScoutCore

/// One line in the panel. Every source produces these, which is what lets the arrow keys, Return
/// and ⌘Return work identically no matter what is being searched.
enum PanelRow: Identifiable {
    /// An app. `pinned` marks the exact-name match that sits above file results.
    case app(AppIndex.Entry, pinned: Bool)
    case file(SearchResult)
    case pane(SettingsPaneIndex.Pane)
    case mail(MailHit)
    case message(MessageHit)
    case contact(ContactHit)
    case note(NoteHit)
    case reminder(ReminderHit)

    var id: String {
        switch self {
        case .app(let entry, let pinned): "app:\(pinned):\(entry.url.path)"
        case .file(let result): "file:\(result.url.path)"
        case .pane(let pane): "pane:\(pane.identifier)"
        case .mail(let hit): "mail:\(hit.rowID)"
        case .message(let hit): "message:\(hit.rowID)"
        case .contact(let hit): "contact:\(hit.identifier)"
        case .note(let hit): "note:\(hit.rowID)"
        case .reminder(let hit): "reminder:\(hit.identifier)"
        }
    }
}

/// Why a source has nothing to show. An empty list and a missing permission look identical
/// otherwise, and the second one is fixable.
enum LaneStatus: Equatable {
    case ready
    case needsFullDiskAccess
    /// Contacts has never been asked for. Unlike Full Disk Access, this one an app *can* ask
    /// about — so the notice offers a prompt rather than a trip to System Settings.
    case contactsNotAsked
    case contactsDenied
    /// Reminders, like Contacts, is a permission an app may ask for itself.
    case remindersNotAsked
    case remindersDenied
    case building
    case failed(String)
}

/// One line of the panel as drawn: a heading, an explanation, a result, or the note about what
/// was left out.
enum PanelItem: Identifiable {
    case header(lane: SearchLane, count: Int, total: Int)
    case status(lane: SearchLane, status: LaneStatus)
    case row(PanelRow, index: Int)
    case showMore(lane: SearchLane, remaining: Int)
    case indexing(lane: SearchLane, done: Int, total: Int)
    case hiddenNotice(count: Int)

    var id: String {
        switch self {
        case .header(let lane, _, _): "header:\(lane.rawValue)"
        case .status(let lane, _): "status:\(lane.rawValue)"
        case .row(let row, let index): "row:\(index):\(row.id)"
        case .showMore(let lane, _): "more:\(lane.rawValue)"
        case .indexing(let lane, _, _): "indexing:\(lane.rawValue)"
        case .hiddenNotice: "hidden"
        }
    }
}

/// One labelled group of results. Sources stay in their own sections rather than interleaving,
/// so turning four of them on still reads as four answers instead of one pile.
struct PanelSection: Identifiable {
    let lane: SearchLane
    var rows: [PanelRow]
    var status: LaneStatus
    /// How many matched altogether, which is usually more than are shown.
    var total: Int
    var id: String { lane.rawValue }
}

/// Everything the panel shows and does.
///
/// The order of operations for files is the product: scope and exclusions **remove** first,
/// then filters remove again, and only then does the ranker sort what survived. Nothing filtered
/// out can drift back in, which is the specific failure that made Spotlight unusable.
@MainActor
@Observable
final class SearchModel {

    // MARK: - What the panel shows

    var text: String = "" {
        didSet { scheduleSearch() }
    }

    var scope: SearchScope = .myFiles {
        didSet {
            guard scope != oldValue else { return }
            runSearch()
        }
    }

    /// The chips under the field. Changing one re-filters what is already on screen — no new
    /// search is needed, so the list updates instantly.
    var filter = FileFilter() {
        didSet { rebuildSections() }
    }

    private(set) var suggestions = FilterSuggestions(folders: [], kinds: [], windows: [])

    /// Set by pressing Tab on a folder — the file search then covers only that folder.
    private(set) var focusedFolder: URL?
    var focusedFolderName: String? { focusedFolder?.lastPathComponent }

    private(set) var sections: [PanelSection] = []
    /// Exactly what the panel draws, in order.
    private(set) var displayItems: [PanelItem] = []
    /// How far through reading the mail archive Scout is, while that is still happening.
    private(set) var mailIndexing: MailBodyIndex.Progress?
    /// How many file matches the exclusions removed, so nothing disappears without a trace.
    private(set) var hiddenCount: Int = 0

    var showHidden: Bool = false {
        didSet { rebuildSections() }
    }

    var selection: Int = 0
    var onDismiss: (() -> Void)?

    /// Which sources are switched on. Remembered between searches and between launches.
    var enabledLanes: Set<SearchLane> {
        // Demo mode keeps its own set. Sharing the real one would write the screenshot's
        // arrangement straight into the preferences of whoever's Mac took the picture.
        get { isDemo ? demoLanes : settings.enabledLanes }
        set {
            guard !isDemo else { demoLanes = newValue; runSearch(); return }
            // Zero sources is allowed. Switching everything off and then clicking the one you
            // want beats switching seven off one at a time, and the panel says plainly that
            // nothing is on rather than looking broken.
            settings.enabledLanes = newValue
            runSearch()
        }
    }

    /// The sources in the order the user has arranged them, which is also the order their
    /// results appear in.
    ///
    /// The pictures on the website use the order the app ships in, not the order of whoever's Mac
    /// took them — otherwise the buttons on the website would be arranged the way one person
    /// happens to like them, and the numbered shortcuts underneath would not match.
    var orderedLanes: [SearchLane] { isDemo ? SearchLane.allCases : settings.laneOrder }

    /// The number on a source's button: where it sits, not what it is.
    func number(for lane: SearchLane) -> Int? {
        orderedLanes.firstIndex(of: lane).map { $0 + 1 }
    }

    var allLanesAreOn: Bool { enabledLanes.count == SearchLane.allCases.count }

    var noLanesAreOn: Bool { enabledLanes.isEmpty }

    /// Set when one source has been opened out on its own from its heading.
    private(set) var soloedLane: SearchLane?
    /// What was on before that, so Escape can put it back.
    private var previousLanes: Set<SearchLane>?

    /// Show one source by itself, with far more of it.
    ///
    /// This is the answer to a long list: rather than scrolling past four sources to reach the
    /// files, take the one you meant and see all of it.
    func soloLane(_ lane: SearchLane) {
        if soloedLane == nil { previousLanes = enabledLanes }
        soloedLane = lane
        // The setter runs the search, which reads the raised limit below through `limit(for:)`.
        enabledLanes = [lane]
    }

    /// Put back whatever was on before a source was opened out on its own.
    func showAllSources() {
        guard let restored = previousLanes else { return }
        soloedLane = nil
        previousLanes = nil
        enabledLanes = restored
    }

    /// Turn every source on, or every source off.
    func setAllLanes(_ on: Bool) {
        clearSolo()
        enabledLanes = on ? Set(SearchLane.allCases) : []
    }

    /// Move a source to a position in the row. The results follow the buttons.
    func moveLane(_ lane: SearchLane, to index: Int) {
        guard settings.moveLane(lane, to: index) else { return }
        rebuildSections()
    }

    /// Put the buttons back the way they shipped.
    func resetLaneOrder() {
        settings.resetLaneOrder()
        rebuildSections()
    }

    private func clearSolo() {
        soloedLane = nil
        previousLanes = nil
    }

    /// Put the sources back without kicking off a search — for the moments the panel is closing
    /// or reopening and is about to do that anyway.
    private func restoreLanesQuietly() {
        guard !isDemo, let restored = previousLanes else { return }
        clearSolo()
        settings.enabledLanes = restored
    }

    /// Every row across every section, in the order they are drawn — what the arrow keys walk.
    var rows: [PanelRow] { sections.flatMap(\.rows) }
    var rowCount: Int { rows.count }

    var pinnedPlaces: [URL] { settings.pinnedPlaces }

    /// Whether macOS is still handing ⌘-Space to Spotlight. Re-read each time the panel opens,
    /// so the offer to fix it disappears as soon as it is fixed.
    private(set) var spotlightOwnsCommandSpace = SpotlightShortcut.isEnabled

    /// Whether to offer the swap in the footer at all.
    ///
    /// Always on in demo mode. It is the state every freshly installed Mac is in — and therefore
    /// the widest the footer ever has to be — so it is the one worth photographing. Dismissing it
    /// on the machine doing the development is exactly how that case stopped being visible.
    var showsCommandSpaceHint: Bool {
        if isDemo { return true }
        return spotlightOwnsCommandSpace && !settings.hideCommandSpaceHint
    }

    func dismissCommandSpaceHint() {
        settings.hideCommandSpaceHint = true
    }

    var hasChips: Bool {
        enabledLanes.contains(.files) && (!pinnedPlaces.isEmpty || !suggestions.isEmpty)
    }

    // MARK: - Machinery

    private let searcher = SpotlightSearcher()
    private let mail = MailSearchService()
    private let messages = MessageSearchService()
    private let contacts = ContactSearchService()
    private let notes = NotesSearchService()
    private let reminders = ReminderSearchService()
    /// The authorization checks are plain static reads, so they stay synchronous.
    private let contactAccess = ContactSearcher()
    private let reminderAccess = ReminderSearcher()
    private let ranker = Ranker()
    private let appIndex = AppIndex.scan()
    private let paneIndex = SettingsPaneIndex.scan()
    private let pickMemory = PickMemory()
    private let settings = ScoutSettings.shared

    private var rawFiles: [SearchResult] = []
    private var mailRows: [PanelRow] = []
    private var messageRows: [PanelRow] = []
    private var contactRows: [PanelRow] = []
    private var noteRows: [PanelRow] = []
    private var reminderRows: [PanelRow] = []

    private var mailStatus: LaneStatus = .ready
    private var messageStatus: LaneStatus = .ready
    private var contactStatus: LaneStatus = .ready
    private var noteStatus: LaneStatus = .ready
    private var reminderStatus: LaneStatus = .ready

    private var debounce: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var mailTask: Task<Void, Never>?
    private var contactTask: Task<Void, Never>?
    private var noteTask: Task<Void, Never>?
    private var reminderTask: Task<Void, Never>?
    private var mailIndexTask: Task<Void, Never>?
    private var selectedRowID: String?

    /// How many more to add each time the rest are asked for.
    private let pageSize = 50

    /// How much a source opened out on its own shows at once.
    ///
    /// Not everything. The results list is a plain stack rather than a lazy one — a lazy one
    /// recycled rows into the wrong views — so two thousand rows would take seconds to draw. Two
    /// hundred at a time, with Show more right underneath, is the honest version of "all of it".
    private let soloLimit = 200

    private var laneLimits: [SearchLane: Int] = [:]
    private var laneTotals: [SearchLane: Int] = [:]

    /// How many of this source to show. One number for all eight, chosen in Settings — the point
    /// of the panel is a list you can take in at a glance, with the rest one click away.
    func limit(for lane: SearchLane) -> Int {
        if let asked = laneLimits[lane] { return asked }
        if soloedLane == lane { return soloLimit }
        return settings.resultsPerSource
    }

    /// The most rows one source will draw at once.
    ///
    /// The results list is a plain stack rather than a lazy one — a lazy one recycled rows into
    /// the wrong views — so a thousand rows would take seconds to draw. Past this the section
    /// keeps its "Show more" row, because a cap that hides things silently is the exact failure
    /// this app exists to fix.
    static let maximumDrawn = 500

    /// Show the next page of one source.
    func showMore(_ lane: SearchLane) {
        grow(lane, to: limit(for: lane) + (soloedLane == lane ? soloLimit : pageSize))
    }

    /// Open one source right out, from its heading.
    func showAll(_ lane: SearchLane) {
        grow(lane, to: Self.maximumDrawn)
    }

    /// How many of a source there are altogether, which is usually more than are shown.
    func total(for lane: SearchLane) -> Int {
        sections.first { $0.lane == lane }?.total ?? 0
    }

    /// Files, apps and settings are already in hand so they just re-slice; the rest go back to
    /// their store for the next page.
    private func grow(_ lane: SearchLane, to newLimit: Int) {
        // Selection is an index into a flat list, so growing a section above the cursor would
        // slide the highlight onto somebody else's row. Remember what was selected, not where.
        selectedRowID = selectedRow?.id
        laneLimits[lane] = min(newLimit, Self.maximumDrawn)
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch lane {
        case .contacts where query.count >= 2: searchContacts(query)
        case .mail where query.count >= 2: searchMail(query)
        case .messages where query.count >= 2: searchMessages(query)
        case .notes where query.count >= 2: searchNotes(query)
        case .reminders where query.count >= 2: searchReminders(query)
        default: rebuildSections()
        }
    }

    /// Contacts changing under us — someone added in Contacts.app, or a card edited — otherwise
    /// would not be findable until the five-minute cache expired.
    private var contactChangeObserver: NSObjectProtocol?

    /// Same problem for reminders: one ticked off in Reminders would keep showing as outstanding
    /// until the cache expired.
    private var reminderChangeObserver: NSObjectProtocol?

    init() {
        contactChangeObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [contacts] _ in
            Task { await contacts.invalidate() }
        }

        reminderChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [reminders] _ in
            Task { await reminders.invalidate() }
        }

        searcher.onResults = { [weak self] results in
            guard let self else { return }
            self.rawFiles = results
            self.rebuildSections()
        }
    }

    // MARK: - Lifecycle

    func reset() {
        restoreLanesQuietly()
        spotlightOwnsCommandSpace = SpotlightShortcut.isEnabled
        laneLimits.removeAll()
        laneTotals.removeAll()
        text = ""
        scope = settings.defaultScope
        focusedFolder = nil
        showHidden = false
        filter.clear()
        clearResults()
        selection = 0
    }

    private func clearResults() {
        rawFiles = []
        mailRows = []
        messageRows = []
        contactRows = []
        noteRows = []
        reminderRows = []
        sections = []
        displayItems = []
        hiddenCount = 0
    }

    func stop() {
        // Opening one source out on its own is a drill, not a preference. Left in place it would
        // be written to disk as "only Mail is on", and the next launch would look like seven
        // sources had switched themselves off.
        restoreLanesQuietly()
        debounce?.cancel()
        messageTask?.cancel()
        mailTask?.cancel()
        contactTask?.cancel()
        noteTask?.cancel()
        reminderTask?.cancel()
        // The mail index keeps building across panel closes on purpose: stopping and restarting
        // it every time would mean never finishing.
        searcher.stop()
    }

    // MARK: - Searching

    /// A short delay so a fast typist runs one search, not eight.
    private func scheduleSearch() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            self?.runSearch()
        }
    }

    /// Fills the panel from `DemoData` instead of reading anything real. Used only by
    /// `--shot`, so the pictures on the website are of invented mail and invented files.
    ///
    /// Nothing in this mode writes to the preferences — it runs as a second copy of the app,
    /// sharing the real one's defaults, and a screenshot must not cost somebody their settings.
    var isDemo = false
    private var demoScene: DemoData.Scene = .sections
    /// A word typed on the command line instead of the scene's own, for trying one out without
    /// a rebuild.
    private var demoQuery: String?
    private var demoLanes: Set<SearchLane> = Set(SearchLane.allCases)

    /// Arrange the panel for one of the pictures on the website.
    ///
    /// Everything after this point is the ordinary drawing path — the scene only decides what the
    /// sources hand back, so a picture cannot show a layout the app is incapable of.
    func showDemoScene(_ scene: DemoData.Scene, query: String? = nil) {
        isDemo = true
        demoScene = scene
        demoQuery = query
        let setup = DemoData.setup(for: scene, query: query)
        demoLanes = setup.lanes
        soloedLane = setup.solo
        scope = setup.scope
        filter = setup.filter
        text = setup.query
        buildDemoSections()
    }

    private func runSearch() {
        if isDemo { buildDemoSections(); return }
        selection = 0
        laneLimits.removeAll()
        laneTotals.removeAll()
        searcher.stop()
        mailTask?.cancel()
        messageTask?.cancel()
        contactTask?.cancel()
        noteTask?.cancel()
        reminderTask?.cancel()
        clearResults()

        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if enabledLanes.contains(.files) {
            searcher.search(text, scope: scope, folder: focusedFolder)
        }

        if enabledLanes.contains(.mail) {
            startMailIndexingIfNeeded()
            if query.count >= 2 { searchMail(query) }
        }

        if enabledLanes.contains(.contacts) {
            switch contactAccess.access {
            case .allowed:
                contactStatus = .ready
                if query.count >= 2 { searchContacts(query) }
            case .notRequested:
                // Deliberately not asked here. A permission prompt that appears by itself while
                // someone is typing is one people dismiss without reading; the notice offers a
                // button instead, so the prompt arrives because they asked for it.
                contactStatus = .contactsNotAsked
            case .denied:
                contactStatus = .contactsDenied
            }
        }

        if enabledLanes.contains(.messages), query.count >= 2 {
            searchMessages(query)
        }

        if enabledLanes.contains(.notes), query.count >= 2 {
            searchNotes(query)
        }

        if enabledLanes.contains(.reminders) {
            switch reminderAccess.access {
            case .allowed:
                reminderStatus = .ready
                if query.count >= 2 { searchReminders(query) }
            case .notRequested:
                // Same reasoning as Contacts: a prompt that appears by itself mid-typing is one
                // people dismiss without reading, so the notice offers a button instead.
                reminderStatus = .remindersNotAsked
            case .denied:
                reminderStatus = .remindersDenied
            }
        }

        rebuildSections()
    }

    /// Raise the system's own Contacts prompt.
    ///
    /// The panel goes away first, and that is not politeness. It floats above ordinary windows,
    /// and macOS presents its permission prompt in an ordinary one — so with the panel up, the
    /// prompt appears behind it and nothing seems to happen at all.
    func requestContactsAccess() {
        onDismiss?()
        // Routed through the Settings window rather than asked from here. The panel floats above
        // ordinary windows and macOS draws its permission prompt in an ordinary one, so asking
        // with the panel up put the prompt behind it — nothing appeared to happen at all. The
        // settings window is an ordinary window, and it is also where the answer is shown.
        Task { [contacts] in await contacts.invalidate() }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: SettingsWindowController.openNotification,
                object: nil,
                userInfo: [
                    SettingsWindowController.tabKey: SettingsView.Tab.permissions,
                    SettingsWindowController.requestKey: "contacts",
                ]
            )
        }
    }

    /// Raise the system's own Reminders prompt. Routed through Settings for the same reason the
    /// Contacts one is: the panel floats, macOS's prompt does not, and the prompt lands behind it.
    func requestRemindersAccess() {
        onDismiss?()
        Task { [reminders] in await reminders.invalidate() }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: SettingsWindowController.openNotification,
                object: nil,
                userInfo: [
                    SettingsWindowController.tabKey: SettingsView.Tab.permissions,
                    SettingsWindowController.requestKey: "reminders",
                ]
            )
        }
    }

    /// Reading every contact takes long enough to be worth keeping off the main thread, and it
    /// only happens once every few minutes.
    private func searchContacts(_ query: String) {
        let cap = limit(for: .contacts)
        contactTask = Task { [contacts] in
            let page = await contacts.search(query, limit: cap)
            guard !Task.isCancelled, query == self.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            self.contactRows = page.items.map { .contact($0) }
            self.laneTotals[.contacts] = page.total
            self.rebuildSections()
        }
    }

    /// Notes are read off the main thread for the same reason messages are: the first sync
    /// decompresses every note on the Mac.
    private func searchNotes(_ query: String) {
        noteStatus = .building
        let cap = limit(for: .notes)
        noteTask = Task { [notes] in
            await notes.prepare()
            let page = await notes.search(query, limit: cap)
            // Read the state after searching, not before: a damaged index only shows itself when
            // a query runs, and reading first would report it as ready and empty.
            let state = await notes.currentState()
            guard !Task.isCancelled else { return }
            self.applyNotes(page, state: state, query: query)
        }
    }

    private func applyNotes(_ page: SearchPage<NoteHit>, state: NotesSearchService.State, query: String) {
        guard query == text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        switch state {
        case .needsFullDiskAccess: noteStatus = .needsFullDiskAccess
        case .failed(let reason): noteStatus = .failed(reason)
        case .idle, .building, .ready: noteStatus = .ready
        }
        noteRows = page.items.map { .note($0) }
        laneTotals[.notes] = page.total
        rebuildSections()
    }

    /// EventKit reads every reminder on the Mac to answer anything at all, so it happens on its
    /// own task and the result is cached for a minute.
    private func searchReminders(_ query: String) {
        let cap = limit(for: .reminders)
        reminderTask = Task { [reminders] in
            let page = await reminders.search(query, limit: cap)
            guard !Task.isCancelled, query == self.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            self.reminderRows = page.items.map { .reminder($0) }
            self.laneTotals[.reminders] = page.total
            self.rebuildSections()
        }
    }

    /// Keep reading the mail archive until it is all indexed.
    ///
    /// Bounded slices rather than one long run, so the lane answers throughout — the first pass
    /// over a long archive is tens of thousands of files. Each slice re-searches, so results
    /// improve while it works instead of only at the end.
    func startMailIndexingIfNeeded() {
        guard settings.searchMailBodies, mailIndexTask == nil else { return }

        mailIndexTask = Task { [mail] in
            await mail.setBodySearch(true)
            while !Task.isCancelled {
                guard let progress = await mail.syncBodies(budget: 1_500) else { break }
                self.mailIndexing = progress.isComplete ? nil : progress

                if progress.isComplete { break }
                // Re-run the search so what has been indexed so far is already useful.
                let query = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if query.count >= 2 { self.searchMail(query) }
            }
            self.mailIndexing = nil
            self.mailIndexTask = nil
        }
    }

    /// Mail's own index is read off the main thread — 46,000 messages is not something to scan
    /// while someone is typing.
    private func searchMail(_ query: String) {
        let cap = limit(for: .mail)
        mailTask = Task { [mail] in
            let page = await mail.search(query, limit: cap)
            let state = await mail.currentState()
            guard !Task.isCancelled else { return }
            self.applyMail(page, state: state, query: query)
        }
    }

    private func applyMail(_ page: SearchPage<MailHit>, state: MailSearchService.State, query: String) {
        guard query == text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        switch state {
        case .needsFullDiskAccess: mailStatus = .needsFullDiskAccess
        case .failed(let reason): mailStatus = .failed(reason)
        case .ready: mailStatus = .ready
        }
        mailRows = page.items.map { .mail($0) }
        laneTotals[.mail] = page.total
        rebuildSections()
    }

    /// The Messages index is built and read off the main thread, so the panel keeps responding
    /// while a long history is read for the first time.
    private func searchMessages(_ query: String) {
        messageStatus = .building
        let cap = limit(for: .messages)
        messageTask = Task { [messages] in
            await messages.prepare()
            let page = await messages.search(query, limit: cap)
            // Read the state after searching, not before: a damaged index only shows itself when
            // a query runs, and reading first would report it as ready and empty.
            let state = await messages.currentState()
            guard !Task.isCancelled else { return }
            self.applyMessages(page, state: state, query: query)
        }
    }

    private func applyMessages(_ page: SearchPage<MessageHit>, state: MessageSearchService.State, query: String) {
        guard query == text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        switch state {
        case .needsFullDiskAccess: messageStatus = .needsFullDiskAccess
        case .failed(let reason): messageStatus = .failed(reason)
        case .idle, .building, .ready: messageStatus = .ready
        }
        messageRows = page.items.map { .message($0) }
        laneTotals[.messages] = page.total
        rebuildSections()
    }

    /// Fill every section from the scene, and nothing from disk.
    private func buildDemoSections() {
        selection = 0
        laneLimits.removeAll()
        laneTotals.removeAll()
        clearResults()

        let setup = DemoData.setup(for: demoScene, query: demoQuery)
        demoLanes = setup.lanes

        // The shipped cap, not whoever's Mac is taking the picture. Left to read the real
        // preference, a Mac set to show 5 would quietly publish a different set of screenshots
        // from a Mac set to show 20.
        for lane in SearchLane.allCases where lane != soloedLane {
            laneLimits[lane] = ScoutSettings.defaultResultsPerSource
        }

        rawFiles = setup.files
        contactRows = trimmed(setup.contacts.map { PanelRow.contact($0) }, .contacts)
        mailRows = trimmed(setup.mail.map { PanelRow.mail($0) }, .mail)
        messageRows = trimmed(setup.messages.map { PanelRow.message($0) }, .messages)
        noteRows = trimmed(setup.notes.map { PanelRow.note($0) }, .notes)
        reminderRows = trimmed(setup.reminders.map { PanelRow.reminder($0) }, .reminders)

        for (lane, total) in setup.totals { laneTotals[lane] = total }
        mailStatus = .ready
        contactStatus = .ready
        messageStatus = .ready
        noteStatus = .ready
        reminderStatus = .ready

        rebuildSections()
    }

    /// Sources cut themselves down to the cap before handing rows over; the demo has to do the
    /// same, or a scene with more rows than the cap would draw a section the app never draws.
    private func trimmed(_ rows: [PanelRow], _ lane: SearchLane) -> [PanelRow] {
        Array(rows.prefix(limit(for: lane)))
    }

    // MARK: - Assembling the panel

    private func rebuildSections() {
        var built: [PanelSection] = []

        for lane in orderedLanes where enabledLanes.contains(lane) {
            switch lane {
            case .files:
                let rows = fileRows()
                built.append(PanelSection(lane: .files, rows: rows, status: .ready,
                                          total: laneTotals[.files] ?? rows.count))
            case .contacts:
                built.append(PanelSection(lane: .contacts, rows: contactRows, status: contactStatus,
                                          total: laneTotals[.contacts] ?? contactRows.count))
            case .mail:
                built.append(PanelSection(lane: .mail, rows: mailRows, status: mailStatus,
                                          total: laneTotals[.mail] ?? mailRows.count))
            case .messages:
                built.append(PanelSection(lane: .messages, rows: messageRows, status: messageStatus,
                                          total: laneTotals[.messages] ?? messageRows.count))
            case .apps:
                let all = appIndex.matches(for: text)
                let rows = all.prefix(limit(for: .apps)).map { PanelRow.app($0, pinned: false) }
                built.append(PanelSection(lane: .apps, rows: Array(rows), status: .ready, total: all.count))
            case .system:
                let all = paneIndex.matches(for: text)
                let rows = all.prefix(limit(for: .system)).map { PanelRow.pane($0) }
                built.append(PanelSection(lane: .system, rows: Array(rows), status: .ready, total: all.count))
            case .notes:
                built.append(PanelSection(lane: .notes, rows: noteRows, status: noteStatus,
                                          total: laneTotals[.notes] ?? noteRows.count))
            case .reminders:
                built.append(PanelSection(lane: .reminders, rows: reminderRows, status: reminderStatus,
                                          total: laneTotals[.reminders] ?? reminderRows.count))
            }
        }

        // A section with neither results nor anything to say is not worth a heading — except the
        // one opened out on its own, whose heading carries the only way back. Dropping it left a
        // search that matched nothing looking like a dead end.
        sections = built.filter { !$0.rows.isEmpty || $0.status != .ready || $0.lane == soloedLane }
        rebuildDisplayItems()
        selection = min(selection, max(0, rowCount - 1))
    }

    /// Flatten the sections into the exact sequence the panel draws.
    ///
    /// Built here rather than assembled in the view, because a header and its rows have to come
    /// from one walk of the same list — computing each section's starting offset separately is how
    /// headers ended up sitting over other sections' results.
    private func rebuildDisplayItems() {
        var items: [PanelItem] = []
        var index = 0

        for section in sections {
            items.append(.header(lane: section.lane, count: section.rows.count, total: section.total))
            if section.lane == .mail, let progress = mailIndexing {
                items.append(.indexing(lane: .mail, done: progress.indexed, total: progress.total))
            }
            if section.status != .ready {
                items.append(.status(lane: section.lane, status: section.status))
            }
            for row in section.rows {
                items.append(.row(row, index: index))
                index += 1
            }
            let remaining = section.total - section.rows.count
            if remaining > 0 {
                items.append(.showMore(lane: section.lane, remaining: remaining))
            }
        }

        if enabledLanes.contains(.files), hiddenCount > 0 {
            items.append(.hiddenNotice(count: hiddenCount))
        }
        displayItems = items

        // Put the highlight back on the row it was on, wherever that row has moved to.
        if let selectedRowID {
            for item in items {
                if case .row(let row, let index) = item, row.id == selectedRowID {
                    selection = index
                    break
                }
            }
            self.selectedRowID = nil
        }
    }

    private func fileRows() -> [PanelRow] {
        let exclusions = showHidden ? Exclusions.none : settings.exclusions
        let kept = rawFiles.filter { !exclusions.excludes($0.url) }
        hiddenCount = rawFiles.count - kept.count

        let ranked = ranker.rank(kept, query: text, learnedPicks: pickMemory.picks(for: text))

        // Chips are offered from the unfiltered set, so applying one never empties the row that
        // would let you take it back off.
        suggestions = FilterSuggestions.from(Array(ranked.prefix(300)))

        let matching = filter.apply(to: ranked)
        // A believable total for the screenshot: "4 of 1,090" is the part of the design worth
        // photographing, and a bare 4 says the opposite of what it should.
        laneTotals[.files] = isDemo ? 1_090 : matching.count
        let files = matching.prefix(limit(for: .files)).map { PanelRow.file($0) }

        // The one exact app-name match sits at the very top so Return still launches apps. It is
        // counted in the total as well, or "remaining" would be short by one and the last file
        // would have no Show more to reach it.
        if settings.pinExactAppMatch, let app = appIndex.exactMatch(for: text), focusedFolder == nil {
            laneTotals[.files] = (laneTotals[.files] ?? 0) + 1
            return [.app(app, pinned: true)] + files
        }
        return Array(files)
    }

    // MARK: - Moving around

    func moveSelection(by delta: Int) {
        guard rowCount > 0 else { return }
        selection = (selection + delta + rowCount) % rowCount
    }

    func toggleLane(_ lane: SearchLane) {
        // Touching the switches by hand ends the "show only this one" state; otherwise Escape
        // would later put back a set the user had already moved on from.
        clearSolo()
        var updated = enabledLanes
        if updated.contains(lane) { updated.remove(lane) } else { updated.insert(lane) }
        enabledLanes = updated
    }

    /// ⌘1 … ⌘8 toggle a source on or off, by where its button sits.
    func toggleLane(number: Int) {
        let lanes = orderedLanes
        guard number >= 1, number <= lanes.count else { return }
        toggleLane(lanes[number - 1])
    }

    /// ⌥↓ and ⌥↑ jump from one section's first result to the next, which is how you get past a
    /// hundred files without holding the arrow key down.
    func moveToSection(by delta: Int) {
        let starts = sections.filter { !$0.rows.isEmpty }.map { startIndex(of: $0) }
        guard !starts.isEmpty else { return }

        var current = 0
        for (index, start) in starts.enumerated() where selection >= start { current = index }

        // Going up from partway down a section lands at the top of that section first, the way a
        // paragraph jump does in a text editor.
        var target = current + delta
        if delta < 0, selection > starts[current] { target = current }
        selection = starts[(target + starts.count) % starts.count]
    }

    /// The row index at which a section starts, for drawing the selection.
    func startIndex(of section: PanelSection) -> Int {
        var index = 0
        for candidate in sections {
            if candidate.id == section.id { return index }
            index += candidate.rows.count
        }
        return index
    }

    /// The id of the item holding the selection, for scrolling it into view.
    var selectedItemID: String? {
        displayItems.first {
            if case .row(_, let index) = $0 { return index == selection }
            return false
        }?.id
    }

    var selectedRow: PanelRow? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    var selectedFile: SearchResult? {
        if case .file(let result) = selectedRow { return result }
        return nil
    }

    // MARK: - Doing something

    /// Return: open whatever is selected, in whatever app owns it.
    func activate() {
        switch selectedRow {
        case .app(let entry, _):
            NSWorkspace.shared.openApplication(at: entry.url, configuration: NSWorkspace.OpenConfiguration())
        case .file(let result):
            pickMemory.record(query: text, url: result.url)
            NSWorkspace.shared.open(result.url)
        case .pane(let pane):
            if let url = pane.url { NSWorkspace.shared.open(url) }
        case .mail(let hit):
            // Without a Message-ID there is nothing to open — Mail's index knows the message but
            // not where its file is.
            if let url = hit.openURL { NSWorkspace.shared.open(url) }
        case .contact(let hit):
            if let url = hit.openURL { NSWorkspace.shared.open(url) }
        case .note(let hit):
            // Same fallback as Messages: without an identifier there is nothing to open, and
            // launching Notes beats doing nothing.
            open(hit.openURL, orLaunch: "com.apple.Notes")
        case .reminder(let hit):
            open(hit.openURL, orLaunch: "com.apple.reminders")
        case .message(let hit):
            // Without a conversation to open, fall back to launching Messages itself rather
            // than doing nothing.
            open(hit.openURL, orLaunch: "com.apple.MobileSMS")
        case nil:
            return
        }
        onDismiss?()
    }

    /// Open a deep link, or failing that the app that owns it. The deep links into Notes,
    /// Reminders and Messages are all undocumented schemes; when one stops working, landing in
    /// the right app is still an answer, and a dead Return key is not.
    private func open(_ url: URL?, orLaunch bundleIdentifier: String) {
        // The return value matters. `open` answers false when nothing is registered for the
        // scheme, which is precisely what happens the day Apple retires one of these — and
        // ignoring it would leave Return doing nothing at all.
        if let url, NSWorkspace.shared.open(url) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// ⌘Return: show it in the Finder rather than opening it.
    func revealInFinder() {
        let url: URL? = switch selectedRow {
        case .app(let entry, _): entry.url
        case .file(let result): result.url
        case .pane, .mail, .message, .contact, .note, .reminder, nil: nil
        }
        guard let url else { return }
        if let result = selectedFile { pickMemory.record(query: text, url: result.url) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        onDismiss?()
    }

    /// Tab: narrow the file search into the selected folder.
    func drillIntoSelection() {
        guard let result = selectedFile, result.kind == .folder else { return }
        focusedFolder = result.url
        filter.clear()
        text = ""
        clearResults()
    }

    /// Escape: shed one layer at a time — filters, then the focused folder, then the panel.
    func escape() {
        if !filter.isEmpty {
            filter.clear()
        } else if previousLanes != nil {
            showAllSources()
        } else if focusedFolder != nil {
            focusedFolder = nil
            runSearch()
        } else {
            onDismiss?()
        }
    }

    /// Put the panel back to the size and place it starts at.
    func resetPanelGeometry() {
        NotificationCenter.default.post(name: PanelController.resetGeometryNotification, object: nil)
    }

    func toggleScope() {
        scope = scope == .myFiles ? .wholeMac : .myFiles
    }

    /// Open Scout's own settings. The panel gets out of the way first — a floating panel over a
    /// settings window is nobody's idea of helpful.
    func openSettings() {
        onDismiss?()
        // A turn later: dismissing hides Scout, and asking a hidden app to show a window in the
        // same breath is a race the window loses.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: SettingsWindowController.openNotification, object: nil)
        }
    }

    /// Open the System Settings page holding the Spotlight shortcut. The `?Shortcuts` anchor
    /// lands on Keyboard Shortcuts where macOS honours it, and on the Keyboard pane where it
    /// does not — either way, one step from the checkbox.
    func openSpotlightShortcutSettings() {
        onDismiss?()
        let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")
        if let url { NSWorkspace.shared.open(url) }
    }
}
