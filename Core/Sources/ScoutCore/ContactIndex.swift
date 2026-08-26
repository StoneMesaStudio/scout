// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

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

    public var isEmpty: Bool { entries.isEmpty }

    public var count: Int { entries.count }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Best matches first: a match on someone's name beats their company, which beats their
    /// address; and a name that starts with the query beats one that merely contains it.
    public func search(_ query: String, limit: Int = 20) -> SearchPage<ContactHit> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = Self.fold(trimmed)
        guard needle.count >= 2 else { return .empty }

        // Numbers are matched as well as text, never instead of it. Punctuation is stripped from
        // the query, so "505 652" and "505-652" find the number that "505652" finds — and a
        // postcode still finds the address it sits in.
        let digits = trimmed.filter(\.isNumber)
        let matchDigits = digits.count >= 3

        var scored: [(hit: ContactHit, score: Int)] = []
        for entry in entries {
            var score = Self.score(entry, needle: needle)

            if score == 0, matchDigits, entry.record.phoneDigits.contains(where: { $0.contains(digits) }) {
                score = 500
            }
            guard score > 0 else { continue }
            scored.append((entry.record.hit, score))
        }

        scored.sort { $0.score == $1.score ? $0.hit.name < $1.hit.name : $0.score > $1.score }
        return SearchPage(items: Array(scored.prefix(limit).map(\.hit)), total: scored.count)
    }

    /// Zero means no match at all.
    static func score(_ entry: Entry, needle: String) -> Int {
        let separators = CharacterSet(charactersIn: " -_.'")

        func words(_ text: String) -> [String] {
            fold(text).components(separatedBy: separators)
        }

        // Name fields only — the displayed name is skipped, because for a card with no name at
        // all it is the placeholder "No name", and matching that floats blank cards to the top.
        for field in entry.record.nameFields {
            let folded = fold(field)
            if folded == needle { return 1000 }
            if words(field).contains(where: { $0.hasPrefix(needle) }) { return 800 }
            if folded.contains(needle) { return 600 }
        }

        for field in entry.record.workFields where fold(field).contains(needle) {
            return 400
        }

        guard entry.haystack.contains(needle) else { return 0 }
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
            let loaded = ContactIndex(records: searcher.loadAll())
            // An empty result is only cached when the address book really is empty. Otherwise the
            // store failed — busy just after launch, or just after access was granted — and
            // caching that would answer "no contacts" for the next five minutes.
            if loaded.isEmpty, searcher.loadFailed() {
                return .empty
            }
            index = loaded
            loadedAt = now
        }
        return index?.search(query, limit: limit) ?? .empty
    }
}
