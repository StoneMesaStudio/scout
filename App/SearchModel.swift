import AppKit
import Observation
import ScoutCore

/// One line in the panel. Every lane produces these, which is what lets the arrow keys, Return
/// and ⌘Return work identically no matter what is being searched.
enum PanelRow: Identifiable {
    /// An app. `pinned` marks the exact-name match that sits above file results.
    case app(AppIndex.Entry, pinned: Bool)
    case file(SearchResult)
    case pane(SettingsPaneIndex.Pane)
    case mail(MailHit)
    case message(MessageHit)

    var id: String {
        switch self {
        case .app(let entry, let pinned): "app:\(pinned):\(entry.url.path)"
        case .file(let result): "file:\(result.url.path)"
        case .pane(let pane): "pane:\(pane.identifier)"
        case .mail(let hit): "mail:\(hit.url.path)"
        case .message(let hit): "message:\(hit.rowID)"
        }
    }
}

/// Why a lane has nothing to show. An empty list and a missing permission look identical
/// otherwise, and the second one is fixable.
enum LaneStatus: Equatable {
    case ready
    case needsFullDiskAccess
    case building
    case failed(String)
}

/// Everything the panel shows and does.
///
/// The order of operations is the product: scope and exclusions **remove** first, then filters
/// remove again, and only then does the ranker sort what survived. Nothing filtered out can drift
/// back in, which is the specific failure that made Spotlight unusable for narrow searches.
@MainActor
@Observable
final class SearchModel {

    // MARK: - What the panel shows

    var text: String = "" {
        didSet { scheduleSearch() }
    }

    var lane: SearchLane = .files {
        didSet {
            guard lane != oldValue else { return }
            filter.clear()
            focusedFolder = nil
            runSearch()
        }
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
        didSet { rebuildRows() }
    }

    /// Which chips to offer, derived from the results themselves.
    private(set) var suggestions = FilterSuggestions(folders: [], kinds: [], windows: [])

    /// Set by pressing Tab on a folder — the search then covers only that folder.
    private(set) var focusedFolder: URL?
    var focusedFolderName: String? { focusedFolder?.lastPathComponent }

    private(set) var rows: [PanelRow] = []
    private(set) var status: LaneStatus = .ready
    /// How many matches the exclusions removed, so nothing disappears without a trace.
    private(set) var hiddenCount: Int = 0

    var showHidden: Bool = false {
        didSet { rebuildRows() }
    }

    var selection: Int = 0

    /// Called when the panel should close.
    var onDismiss: (() -> Void)?

    var rowCount: Int { rows.count }

    // MARK: - Machinery

    private let searcher = SpotlightSearcher()
    private let mailSearcher = MailSearcher()
    private let messages = MessageSearchService()
    private let ranker = Ranker()
    private let appIndex = AppIndex.scan()
    private let paneIndex = SettingsPaneIndex.scan()
    private let pickMemory = PickMemory()

    private var rawResults: [SearchResult] = []
    private var debounce: Task<Void, Never>?
    private let resultLimit = 60

    private var messageTask: Task<Void, Never>?

    init() {
        searcher.onResults = { [weak self] results in
            guard let self else { return }
            self.rawResults = results
            self.rebuildRows()
        }
        mailSearcher.onResults = { [weak self] hits in
            guard let self, self.lane == .mail else { return }
            self.rows = hits.map { .mail($0) }
            self.status = .ready
            self.selection = min(self.selection, max(0, self.rows.count - 1))
        }
    }

    // MARK: - Lifecycle

    func reset() {
        text = ""
        lane = .files
        scope = .myFiles
        focusedFolder = nil
        showHidden = false
        filter.clear()
        rawResults = []
        rows = []
        hiddenCount = 0
        selection = 0
        status = .ready
    }

    func stop() {
        debounce?.cancel()
        messageTask?.cancel()
        searcher.stop()
        mailSearcher.stop()
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
        searcher.stop()
        mailSearcher.stop()
        messageTask?.cancel()

        switch lane {
        case .files:
            status = .ready
            searcher.search(text, scope: scope, folder: focusedFolder)

        case .apps, .system:
            // Both are small in-memory lists, so there is nothing to wait for.
            status = .ready
            rawResults = []
            rebuildRows()

        case .mail:
            rows = []
            status = mailSearcher.isIndexReadable ? .ready : .needsFullDiskAccess
            if case .ready = status { mailSearcher.search(text) }

        case .messages:
            rows = []
            searchMessages()
        }
    }

    /// The Messages index is built and read off the main thread, so the panel keeps responding
    /// while a long history is read for the first time.
    private func searchMessages() {
        let query = text
        status = .building
        messageTask = Task { [messages] in
            await messages.prepare()
            let state = await messages.currentState()
            let hits = query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
                ? await messages.search(query)
                : []

            guard !Task.isCancelled else { return }
            self.applyMessages(hits, state: state, query: query)
        }
    }

    private func applyMessages(_ hits: [MessageHit], state: MessageSearchService.State, query: String) {
        guard lane == .messages, query == text else { return }
        switch state {
        case .needsFullDiskAccess: status = .needsFullDiskAccess
        case .failed(let reason): status = .failed(reason)
        case .idle, .building, .ready: status = .ready
        }
        rows = hits.map { .message($0) }
        selection = min(selection, max(0, rows.count - 1))
    }

    private func rebuildRows() {
        switch lane {
        case .files: rebuildFileRows()
        case .apps: rows = appIndex.matches(for: text).map { .app($0, pinned: false) }
        case .system: rows = paneIndex.matches(for: text).map { .pane($0) }
        case .mail, .messages: break  // filled in by their own asynchronous searches
        }
        selection = min(selection, max(0, rows.count - 1))
    }

    private func rebuildFileRows() {
        let exclusions = showHidden ? Exclusions.none : Exclusions.standard
        let kept = rawResults.filter { !exclusions.excludes($0.url) }
        hiddenCount = rawResults.count - kept.count

        let ranked = ranker.rank(kept, query: text, learnedPicks: pickMemory.picks(for: text))

        // Chips are offered from the unfiltered set, so applying one never empties the row that
        // would let you take it back off.
        suggestions = FilterSuggestions.from(Array(ranked.prefix(300)))

        let files = filter.apply(to: ranked).prefix(resultLimit).map { PanelRow.file($0) }

        // The one exact app-name match sits above the files so Return still launches apps.
        if let app = appIndex.exactMatch(for: text), focusedFolder == nil {
            rows = [.app(app, pinned: true)] + files
        } else {
            rows = Array(files)
        }
    }

    // MARK: - Moving around

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        selection = (selection + delta + rows.count) % rows.count
    }

    func selectLane(_ lane: SearchLane) {
        self.lane = lane
    }

    /// ⌘1 … ⌘5.
    func selectLane(number: Int) {
        let lanes = SearchLane.allCases
        guard number >= 1, number <= lanes.count else { return }
        lane = lanes[number - 1]
    }

    var selectedRow: PanelRow? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    var selectedFile: SearchResult? {
        if case .file(let result) = selectedRow { return result }
        return nil
    }

    // MARK: - Doing something

    /// Return: launch the app, open the file, or jump to the settings pane.
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
            NSWorkspace.shared.open(hit.openURL)
        case .message(let hit):
            // Without a conversation to open, fall back to launching Messages itself rather
            // than doing nothing.
            if let url = hit.openURL {
                NSWorkspace.shared.open(url)
            } else if let messages = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") {
                NSWorkspace.shared.openApplication(at: messages, configuration: NSWorkspace.OpenConfiguration())
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
        case .mail(let hit): hit.url
        case .pane, .message, nil: nil
        }
        guard let url else { return }
        if let result = selectedFile { pickMemory.record(query: text, url: result.url) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        onDismiss?()
    }

    /// Tab: narrow the search into the selected folder.
    func drillIntoSelection() {
        guard lane == .files, let result = selectedFile, result.kind == .folder else { return }
        focusedFolder = result.url
        filter.clear()
        text = ""
        rawResults = []
        rows = []
        hiddenCount = 0
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

    func toggleScope() {
        scope = scope == .myFiles ? .wholeMac : .myFiles
    }
}
