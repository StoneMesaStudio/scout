import AppKit
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

    var id: String {
        switch self {
        case .app(let entry, let pinned): "app:\(pinned):\(entry.url.path)"
        case .file(let result): "file:\(result.url.path)"
        case .pane(let pane): "pane:\(pane.identifier)"
        case .mail(let hit): "mail:\(hit.rowID)"
        case .message(let hit): "message:\(hit.rowID)"
        case .contact(let hit): "contact:\(hit.identifier)"
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
    case hiddenNotice(count: Int)

    var id: String {
        switch self {
        case .header(let lane, _, _): "header:\(lane.rawValue)"
        case .status(let lane, _): "status:\(lane.rawValue)"
        case .row(let row, let index): "row:\(index):\(row.id)"
        case .showMore(let lane, _): "more:\(lane.rawValue)"
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
    /// How many file matches the exclusions removed, so nothing disappears without a trace.
    private(set) var hiddenCount: Int = 0

    var showHidden: Bool = false {
        didSet { rebuildSections() }
    }

    var selection: Int = 0
    var onDismiss: (() -> Void)?

    /// Which sources are switched on. Remembered between searches and between launches.
    var enabledLanes: Set<SearchLane> {
        get { settings.enabledLanes }
        set {
            // At least one source has to stay on, or the panel has nothing to do.
            guard !newValue.isEmpty else { return }
            settings.enabledLanes = newValue
            runSearch()
        }
    }

    /// Every row across every section, in the order they are drawn — what the arrow keys walk.
    var rows: [PanelRow] { sections.flatMap(\.rows) }
    var rowCount: Int { rows.count }

    var pinnedPlaces: [URL] { settings.pinnedPlaces }

    /// Whether macOS is still handing ⌘-Space to Spotlight. Re-read each time the panel opens,
    /// so the offer to fix it disappears as soon as it is fixed.
    private(set) var spotlightOwnsCommandSpace = SpotlightShortcut.isEnabled

    /// Whether to offer the swap in the footer at all.
    var showsCommandSpaceHint: Bool {
        spotlightOwnsCommandSpace && !settings.hideCommandSpaceHint
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
    /// The authorization check is a plain static read, so it stays synchronous.
    private let contactAccess = ContactSearcher()
    private let ranker = Ranker()
    private let appIndex = AppIndex.scan()
    private let paneIndex = SettingsPaneIndex.scan()
    private let pickMemory = PickMemory()
    private let settings = ScoutSettings.shared

    private var rawFiles: [SearchResult] = []
    private var mailRows: [PanelRow] = []
    private var messageRows: [PanelRow] = []
    private var contactRows: [PanelRow] = []

    private var mailStatus: LaneStatus = .ready
    private var messageStatus: LaneStatus = .ready
    private var contactStatus: LaneStatus = .ready

    private var debounce: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var mailTask: Task<Void, Never>?
    private var contactTask: Task<Void, Never>?

    /// How many of each source to show before offering the rest. Files get the room; the others
    /// are there to answer a question, not to fill the panel — but every one of them can be
    /// opened out, because "6 of 2,367" is only useful if the other 2,361 are reachable.
    static func defaultLimit(for lane: SearchLane) -> Int {
        switch lane {
        case .files: 25
        case .contacts, .mail, .messages: 12
        case .apps, .system: 8
        }
    }

    /// How many more to add each time the rest are asked for.
    private let pageSize = 50

    private var laneLimits: [SearchLane: Int] = [:]
    private var laneTotals: [SearchLane: Int] = [:]

    func limit(for lane: SearchLane) -> Int {
        laneLimits[lane] ?? Self.defaultLimit(for: lane)
    }

    /// Show more of one source. Files, apps and settings are already in hand so they just
    /// re-slice; the other three go back to their store for the next page.
    func showMore(_ lane: SearchLane) {
        laneLimits[lane] = limit(for: lane) + pageSize
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch lane {
        case .contacts where query.count >= 2: searchContacts(query)
        case .mail where query.count >= 2: searchMail(query)
        case .messages where query.count >= 2: searchMessages(query)
        default: rebuildSections()
        }
    }

    init() {
        searcher.onResults = { [weak self] results in
            guard let self else { return }
            self.rawFiles = results
            self.rebuildSections()
        }
    }

    // MARK: - Lifecycle

    func reset() {
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
        sections = []
        hiddenCount = 0
    }

    func stop() {
        debounce?.cancel()
        messageTask?.cancel()
        mailTask?.cancel()
        contactTask?.cancel()
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

    private func runSearch() {
        selection = 0
        laneLimits.removeAll()
        laneTotals.removeAll()
        searcher.stop()
        mailTask?.cancel()
        messageTask?.cancel()
        contactTask?.cancel()
        clearResults()

        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if enabledLanes.contains(.files) {
            searcher.search(text, scope: scope, folder: focusedFolder)
        }

        if enabledLanes.contains(.mail), query.count >= 2 {
            searchMail(query)
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
            let state = await messages.currentState()
            let page = await messages.search(query, limit: cap)
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

    // MARK: - Assembling the panel

    private func rebuildSections() {
        var built: [PanelSection] = []

        for lane in SearchLane.allCases where enabledLanes.contains(lane) {
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
            }
        }

        // A section with neither results nor anything to say is not worth a heading.
        sections = built.filter { !$0.rows.isEmpty || $0.status != .ready }
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
        laneTotals[.files] = matching.count
        let files = matching.prefix(limit(for: .files)).map { PanelRow.file($0) }

        // The one exact app-name match sits at the very top so Return still launches apps.
        if settings.pinExactAppMatch, let app = appIndex.exactMatch(for: text), focusedFolder == nil {
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
        var updated = enabledLanes
        if updated.contains(lane) { updated.remove(lane) } else { updated.insert(lane) }
        enabledLanes = updated
    }

    /// ⌘1 … ⌘6 toggle a source on or off.
    func toggleLane(number: Int) {
        let lanes = SearchLane.allCases
        guard number >= 1, number <= lanes.count else { return }
        toggleLane(lanes[number - 1])
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
        case .message(let hit):
            // Without a conversation to open, fall back to launching Messages itself rather
            // than doing nothing.
            if let url = hit.openURL {
                NSWorkspace.shared.open(url)
            } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
        case nil:
            return
        }
        onDismiss?()
    }

    /// ⌘Return: show it in the Finder rather than opening it.
    func revealInFinder() {
        let url: URL? = switch selectedRow {
        case .app(let entry, _): entry.url
        case .file(let result): result.url
        case .pane, .mail, .message, .contact, nil: nil
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
