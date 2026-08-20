import Foundation

/// The Contacts lane's matching, done here rather than by Apple's name predicate.
///
/// A person is looked up by whatever the searcher happens to remember — part of a name, a company,
/// the last four digits of a number, a fragment of an address — so all of those are searched, and
/// a match means the text is actually in there.
public struct ContactIndex: Sendable {

    /// One contact with everything about it flattened into a single searchable string, so a
    /// query only has to be compared once per person.
    struct Entry: Sendable {
        let hit: ContactHit
        let haystack: String
        /// Just the digits of every number, so "5556789" finds "(505) 555-6789".
        let phoneDigits: String
    }

    private let entries: [Entry]

    public init(contacts: [ContactHit]) {
        entries = contacts.map { contact in
            let parts = [contact.name, contact.organization, contact.email, contact.phone]
                .compactMap(\.self)
            return Entry(
                hit: contact,
                haystack: Self.fold(parts.joined(separator: " ")),
                phoneDigits: (contact.phone ?? "").filter(\.isNumber)
            )
        }
    }

    public var count: Int { entries.count }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Best matches first: a name that starts with the query beats one that merely contains it,
    /// and a match on the name beats a match on the company or the address.
    public func search(_ query: String, limit: Int = 20) -> [ContactHit] {
        let needle = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard needle.count >= 2 else { return [] }

        let digits = needle.filter(\.isNumber)
        let searchingForANumber = digits.count >= 3 && digits.count == needle.count

        var scored: [(hit: ContactHit, score: Int)] = []
        for entry in entries {
            if searchingForANumber {
                if entry.phoneDigits.contains(digits) {
                    scored.append((entry.hit, 500))
                }
                continue
            }
            guard entry.haystack.contains(needle) else { continue }
            scored.append((entry.hit, Self.score(entry, needle: needle)))
        }

        return scored
            .sorted { $0.score == $1.score ? $0.hit.name < $1.hit.name : $0.score > $1.score }
            .prefix(limit)
            .map(\.hit)
    }

    private static func score(_ entry: Entry, needle: String) -> Int {
        let name = fold(entry.hit.name)

        if name == needle { return 1000 }
        // A word of the name starting with the query — "Jose" in "Hernandez Jose".
        if name.components(separatedBy: CharacterSet(charactersIn: " -_.'")).contains(where: { $0.hasPrefix(needle) }) {
            return 800
        }
        if name.contains(needle) { return 600 }
        if let organization = entry.hit.organization, fold(organization).contains(needle) { return 400 }
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

    public func search(_ query: String, limit: Int = 20, now: Date = Date()) -> [ContactHit] {
        guard searcher.access == .allowed else { return [] }

        if index == nil || loadedAt.map({ now.timeIntervalSince($0) > staleAfter }) ?? true {
            index = ContactIndex(contacts: searcher.loadAll())
            loadedAt = now
        }
        return index?.search(query, limit: limit) ?? []
    }
}
