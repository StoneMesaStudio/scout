import AppKit
import Observation
import ScoutCore

/// Everything the panel shows and does.
///
/// The order of operations is the product: scope and exclusions **remove** first, then the
/// ranker sorts what survived. Nothing that was filtered out can drift back in, which is the
/// specific failure that made Spotlight unusable for narrow searches.
@MainActor
@Observable
final class SearchModel {

    // MARK: - What the panel shows

    var text: String = "" {
        didSet { scheduleSearch() }
    }

    var scope: SearchScope = .myFiles {
        didSet { runSearch() }
    }

    /// Set by pressing Tab on a folder — the search then covers only that folder.
    private(set) var focusedFolder: URL?
    var focusedFolderName: String? { focusedFolder?.lastPathComponent }

    private(set) var results: [SearchResult] = []
    /// An app whose name the user typed exactly, pinned above the files.
    private(set) var pinnedApp: AppIndex.Entry?
    /// How many matches the exclusions removed, so nothing disappears without a trace.
    private(set) var hiddenCount: Int = 0

    var showHidden: Bool = false {
        didSet { applyRanking() }
    }

    var selection: Int = 0

    /// Called when the panel should close.
    var onDismiss: (() -> Void)?

    /// Rows the arrow keys move through: the pinned app first, then the files.
    var rowCount: Int { (pinnedApp == nil ? 0 : 1) + results.count }

    // MARK: - Machinery

    private let searcher = SpotlightSearcher()
    private let ranker = Ranker()
    private let appIndex = AppIndex.scan()
    private let pickMemory = PickMemory()

    private var rawResults: [SearchResult] = []
    private var debounce: Task<Void, Never>?
    private let resultLimit = 60

    init() {
        searcher.onResults = { [weak self] results in
            guard let self else { return }
            self.rawResults = results
            self.applyRanking()
        }
    }

    // MARK: - Lifecycle

    func reset() {
        text = ""
        scope = .myFiles
        focusedFolder = nil
        showHidden = false
        rawResults = []
        results = []
        pinnedApp = nil
        hiddenCount = 0
        selection = 0
    }

    func stop() {
        debounce?.cancel()
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
        pinnedApp = appIndex.exactMatch(for: text)
        searcher.search(text, scope: scope, folder: focusedFolder)
    }

    private func applyRanking() {
        let exclusions = showHidden ? Exclusions.none : Exclusions.standard
        let kept = rawResults.filter { !exclusions.excludes($0.url) }
        hiddenCount = rawResults.count - kept.count

        let ranked = ranker.rank(kept, query: text, learnedPicks: pickMemory.picks(for: text))
        results = Array(ranked.prefix(resultLimit))
        selection = min(selection, max(0, rowCount - 1))
    }

    // MARK: - Moving around

    func moveSelection(by delta: Int) {
        guard rowCount > 0 else { return }
        selection = (selection + delta + rowCount) % rowCount
    }

    /// The file under the cursor, or nil when the pinned app row is selected.
    var selectedResult: SearchResult? {
        let offset = pinnedApp == nil ? 0 : 1
        let index = selection - offset
        guard index >= 0, index < results.count else { return nil }
        return results[index]
    }

    var selectedIsPinnedApp: Bool {
        pinnedApp != nil && selection == 0
    }

    // MARK: - Doing something

    /// Return: launch the app, or open the file.
    func activate() {
        if selectedIsPinnedApp, let app = pinnedApp {
            NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
            onDismiss?()
            return
        }
        guard let result = selectedResult else { return }
        pickMemory.record(query: text, url: result.url)
        NSWorkspace.shared.open(result.url)
        onDismiss?()
    }

    /// ⌘Return: show it in the Finder rather than opening it.
    func revealInFinder() {
        let url = selectedIsPinnedApp ? pinnedApp?.url : selectedResult?.url
        guard let url else { return }
        if let result = selectedResult { pickMemory.record(query: text, url: result.url) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        onDismiss?()
    }

    /// Tab: narrow the search into the selected folder.
    func drillIntoSelection() {
        guard let result = selectedResult, result.kind == .folder else { return }
        focusedFolder = result.url
        text = ""
        rawResults = []
        results = []
        hiddenCount = 0
    }

    /// Escape: leave a folder first, close the panel only when there is nothing left to leave.
    func escape() {
        if focusedFolder != nil {
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
