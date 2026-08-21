import Foundation

/// The Contacts lane's matching, done here rather than by Apple's name predicate.
///
/// A person is looked up by whatever the searcher happens to remember — part of a name, a company,
/// the last four digits of a number, a fragment of an address — so all of those are searched, and
/// a match means the text is actually in there.
public struct ContactIndex: Sendable {

    struct Entry: Sendable {
        let record: ContactRecord
        /// Everything on the card, folded and joined, so a query is compared once per person.
        let haystack: String
    }

    private let entries: [Entry]

    public init(records: [ContactRecord]) {
        entries = records.map { record in
            Entry(record: record, haystack: Self.fold(record.searchable.joined(separator: " ")))
        }
    }

    public var count: Int { entries.count }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Best matches first: a name that starts with the query beats one that merely contains it,
    /// and a match on a name beats a match on a company, an address or a number.
    public func search(_ query: String, limit: Int = 20) -> SearchPage<ContactHit> {
        let needle = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard needle.count >= 2 else { return .empty }

        let digits = needle.filter(\.isNumber)
        let searchingForANumber = digits.count >= 3 && digits.count == needle.count

        var scored: [(hit: ContactHit, score: Int)] = []
        for entry in entries {
            if searchingForANumber {
                if entry.record.phoneDigits.contains(where: { $0.contains(digits) }) {
                    scored.append((entry.record.hit, 500))
                }
                continue
            }
            guard entry.haystack.contains(needle) else { continue }
            scored.append((entry.record.hit, Self.score(entry, needle: needle)))
        }

        scored.sort { $0.score == $1.score ? $0.hit.name < $1.hit.name : $0.score > $1.score }
        return SearchPage(items: Array(scored.prefix(limit).map(\.hit)), total: scored.count)
    }

    private static func score(_ entry: Entry, needle: String) -> Int {
        let name = fold(entry.record.hit.name)
        let separators = CharacterSet(charactersIn: " -_.'")

        if name == needle { return 1000 }
        if name.components(separatedBy: separators).contains(where: { $0.hasPrefix(needle) }) { return 800 }
        if name.contains(needle) { return 600 }

        // A name field that isn't the displayed one — the person's first name on a card filed
        // under their company.
        let names = entry.record.searchable.prefix(8).map(fold)
        if names.contains(where: { $0.components(separatedBy: separators).contains(where: { $0.hasPrefix(needle) }) }) {
            return 500
        }
        if let organization = entry.record.hit.organization, fold(organization).contains(needle) { return 400 }
        return 200
    }
}

/// Keeps the contact list loaded and off the main thread.
public actor ContactSearchService {

    private let searcher = ContactSearcher()
    private var index: ContactIndex?
    private var loadedAt: Date?

    /// Contacts change rarely; re-reading them every few minutes is enough and costs nothing
    /// noticeable when it happens.
    private let staleAfter: TimeInterval = 300

    public init() {}

    public func access() -> ContactSearcher.Access {
        searcher.access
    }

    public func requestAccess() async -> Bool {
        await searcher.requestAccess()
    }

    /// Drop what is loaded, so the next search reads fresh — used right after access is granted.
    public func invalidate() {
        index = nil
        loadedAt = nil
    }

    public func search(_ query: String, limit: Int = 20, now: Date = Date()) -> SearchPage<ContactHit> {
        guard searcher.access == .allowed else { return .empty }

        if index == nil || loadedAt.map({ now.timeIntervalSince($0) > staleAfter }) ?? true {
            index = ContactIndex(records: searcher.loadAll())
            loadedAt = now
        }
        return index?.search(query, limit: limit) ?? .empty
    }
}
