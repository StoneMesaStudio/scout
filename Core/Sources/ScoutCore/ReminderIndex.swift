import Foundation

/// The Reminders lane's matching, done here rather than by EventKit.
///
/// EventKit offers no way to search reminders by text at all, so everything is read and matched
/// locally — the title first, then the list it is in, then the notes on it. Same rule as the rest
/// of Scout: a match means the words are actually in there.
public struct ReminderIndex: Sendable {

    struct Entry: Sendable {
        let record: ReminderRecord
        let title: String
        let list: String
        let body: String
    }

    private let entries: [Entry]

    public init(records: [ReminderRecord]) {
        entries = records.map {
            Entry(record: $0,
                  title: ContactIndex.fold($0.title),
                  list: ContactIndex.fold($0.list),
                  body: ContactIndex.fold($0.body))
        }
    }

    public var isEmpty: Bool { entries.isEmpty }

    public var count: Int { entries.count }

    /// Still-open reminders first, then by how well they matched, then by what is due soonest.
    ///
    /// Completed ones are kept rather than hidden — "did I ever write that down" is as common a
    /// question as "what do I still owe" — but nothing finished outranks something outstanding.
    public func search(_ query: String, limit: Int = 20) -> SearchPage<ReminderHit> {
        let needle = ContactIndex.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard needle.count >= 2 else { return .empty }

        var scored: [(hit: ReminderHit, score: Int)] = []
        for entry in entries {
            let score = Self.score(entry, needle: needle)
            guard score > 0 else { continue }
            scored.append((entry.record.hit, score))
        }

        scored.sort { left, right in
            if left.hit.isCompleted != right.hit.isCompleted { return !left.hit.isCompleted }
            if left.score != right.score { return left.score > right.score }
            switch (left.hit.due, right.hit.due) {
            case let (a?, b?) where a != b: return a < b
            // A reminder with a date to hit comes before one with no date at all.
            case (nil, _?): return false
            case (_?, nil): return true
            default: return left.hit.title < right.hit.title
            }
        }

        return SearchPage(items: Array(scored.prefix(limit).map(\.hit)), total: scored.count)
    }

    /// Zero means no match at all.
    static func score(_ entry: Entry, needle: String) -> Int {
        if entry.title == needle { return 1000 }

        let separators = CharacterSet(charactersIn: " -_.'’/")
        if entry.title.components(separatedBy: separators).contains(where: { $0.hasPrefix(needle) }) {
            return 800
        }
        if entry.title.contains(needle) { return 600 }
        if entry.list.contains(needle) { return 400 }
        if entry.body.contains(needle) { return 250 }
        return 0
    }
}

/// Keeps the reminder list loaded and off the main thread.
public actor ReminderSearchService {

    private let searcher = ReminderSearcher()
    private var index: ReminderIndex?
    private var loadedAt: Date?

    /// Reminders change more often than contacts but not while somebody is typing. A minute is
    /// long enough to avoid re-reading on every keystroke and short enough that ticking one off
    /// in Reminders shows up almost at once — and the store's own change notification drops this
    /// on the floor the moment anything actually moves.
    private let staleAfter: TimeInterval = 60

    public init() {}

    public func access() -> ReminderSearcher.Access {
        searcher.access
    }

    public func requestAccess() async -> Bool {
        await searcher.requestAccess()
    }

    /// Drop what is loaded so the next search reads fresh — used when Reminders reports a change,
    /// and right after access is granted.
    public func invalidate() {
        index = nil
        loadedAt = nil
    }

    public func search(_ query: String, limit: Int = 20, now: Date = Date()) async -> SearchPage<ReminderHit> {
        guard searcher.access == .allowed else { return .empty }

        if index == nil || loadedAt.map({ now.timeIntervalSince($0) > staleAfter }) ?? true {
            index = ReminderIndex(records: await searcher.loadAll())
            loadedAt = now
        }
        return index?.search(query, limit: limit) ?? .empty
    }

    /// How many reminders are loaded, for the diagnostics.
    public func count() async -> Int {
        if index == nil {
            index = ReminderIndex(records: await searcher.loadAll())
            loadedAt = Date()
        }
        return index?.count ?? 0
    }
}
