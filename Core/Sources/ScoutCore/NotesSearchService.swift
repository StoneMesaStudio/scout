import Foundation

/// The Notes lane, kept off the main thread.
///
/// The first sync decompresses every note body on the Mac, which takes long enough to be visible;
/// every sync after that reads only the notes whose modification date moved. The actor owns the
/// connection, so the panel can await results without ever blocking.
public actor NotesSearchService {

    public enum State: Sendable, Equatable {
        case idle
        case needsFullDiskAccess
        case building
        case ready
        case failed(String)
    }

    private let index: NotesIndex
    private var state: State = .idle
    private var lastSync: Date?
    private var hasRebuilt = false

    /// How stale the index may get before the lane tops it up again. Syncing is incremental, so
    /// this exists only to stop a re-read on every keystroke.
    private let staleAfter: TimeInterval = 30

    public init(
        source: URL = NotesIndex.defaultSource(),
        location: URL = NotesIndex.defaultIndexLocation()
    ) {
        index = NotesIndex(source: source, location: location)
    }

    public func currentState() -> State { state }

    public func indexedCount() -> Int {
        (try? index.indexedCount()) ?? 0
    }

    /// Bring the index up to date. Safe to call whenever the lane is used.
    public func prepare(now: Date = Date()) {
        if case .ready = state, let lastSync, now.timeIntervalSince(lastSync) < staleAfter {
            return
        }

        guard index.sourceIsReadable else {
            state = .needsFullDiskAccess
            return
        }

        state = .building
        do {
            _ = try index.sync()
            state = .ready
            lastSync = now
        } catch let failure as NotesIndex.Failure {
            state = failure == .notAccessible ? .needsFullDiskAccess : .failed(failure.description)
        } catch {
            // The index is ours and rebuildable from Notes itself, so a damaged one is worth
            // throwing away rather than reporting. Once per launch, so a real fault still
            // surfaces instead of looping.
            guard !hasRebuilt else {
                state = .failed(error.localizedDescription)
                return
            }
            hasRebuilt = true
            do {
                try index.rebuild()
                state = .ready
                lastSync = now
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    public func search(_ query: String, limit: Int = 60) -> SearchPage<NoteHit> {
        do {
            return try index.search(query, limit: limit)
        } catch {
            // Reported rather than swallowed: a damaged index rendering as "no matches" is the
            // one answer a search must never give when it did not actually look.
            state = .failed(error.localizedDescription)
            return .empty
        }
    }

    /// Throw the index away and build it again, for the Settings button that offers it.
    public func rebuild() {
        do {
            try index.rebuild()
            state = .ready
            lastSync = Date()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
