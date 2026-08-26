// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Foundation

/// How well the query matched an item's name. Ordered worst to best so the raw value can
/// carry the score.
public enum NameMatch: Int, Sendable, Comparable {
    /// The query appears only inside the file's text, not in its name.
    case contentOnly = 80
    /// "vice" in "service".
    case substring = 300
    /// "serv" starting a word in "Ford Service Receipts".
    case wordPrefix = 520
    /// The query is a whole word of the name: "service" in "Ford Service Receipts".
    case wordExact = 620
    /// The name starts with the query.
    case prefix = 700
    /// The name is the query.
    case exact = 1000

    public static func < (a: NameMatch, b: NameMatch) -> Bool { a.rawValue < b.rawValue }

    public static func classify(name: String, query: String) -> NameMatch {
        let name = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let query = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !query.isEmpty else { return .contentOnly }

        if name == query { return .exact }
        // A name match on the stem alone counts as exact: "Invoice" matching "Invoice.pdf".
        if (name as NSString).deletingPathExtension == query { return .exact }
        if name.hasPrefix(query) { return .prefix }

        // Whole word, then word prefix. This is what puts "Ford F350 Service Receipts" above
        // "webservices.log" for the query "service", and "Warranty.pdf" above "Warrantied".
        let separators = CharacterSet(charactersIn: " -_.·/()[]'\u{2019}")
        let words = name.components(separatedBy: separators)
        if words.contains(query) { return .wordExact }
        if words.contains(where: { $0.hasPrefix(query) }) { return .wordPrefix }

        if name.contains(query) { return .substring }
        return .contentOnly
    }
}

/// Turns a pile of matches into an order worth reading.
///
/// Every weight here is deliberately explicit rather than tuned by feel, because the whole
/// point of the app is that its ordering can be explained — and argued with.
public struct Ranker: Sendable {

    public struct Weights: Sendable {
        /// Folders are navigational: finding one usually answers the question behind the search.
        public var folderBonus: Double = 45
        /// An app matched by name is almost always what was wanted.
        public var applicationBonus: Double = 120
        /// Maximum boost for something touched just now, decaying over `recencyHalfLifeDays`.
        ///
        /// Deliberately smaller than the gap between two match qualities, so that being recent
        /// can reorder equally-good matches but never promote a worse one above a better one.
        public var recencyBonus: Double = 170
        public var recencyHalfLifeDays: Double = 120
        /// Applied when the Mac recorded the user actually opening the item.
        public var openedBeforeBonus: Double = 90
        /// Subtracted per path component past `shallowDepth`, capped at `maxDepthPenalty`.
        public var depthPenalty: Double = 6
        public var shallowDepth: Int = 5
        public var maxDepthPenalty: Double = 72
        public init() {}
    }

    public var weights: Weights
    public var home: URL

    public init(weights: Weights = Weights(), home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.weights = weights
        self.home = home
    }

    /// A `yyyy-mm-dd` at the very start of a filename, as a sortable string. Nil for anything
    /// else — a bare year or a date in the middle is too weak a signal to reorder on.
    static func leadingDate(in name: String) -> String? {
        let characters = Array(name)
        guard characters.count >= 10 else { return nil }
        let candidate = String(characters[0..<10])

        let digits = [0, 1, 2, 3, 5, 6, 8, 9]
        let dashes = [4, 7]
        let parts = Array(candidate)
        guard digits.allSatisfy({ parts[$0].isNumber }), dashes.allSatisfy({ parts[$0] == "-" })
        else { return nil }

        return candidate
    }

    /// Turn a `yyyy-mm-dd` string into a date, in UTC so the result never shifts with the
    /// machine's time zone.
    static func date(fromISO text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }

        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: components)
    }

    /// A multiplier on the whole score, by where the item lives. Deliberately a multiplier and
    /// not an addition: a perfect name match in a cache folder should still lose to a decent one
    /// in Documents.
    public func locationWeight(for url: URL) -> Double {
        let path = url.path
        let documents = home.appending(path: "Documents").path
        let desktop = home.appending(path: "Desktop").path
        let downloads = home.appending(path: "Downloads").path
        let iCloud = SearchScope.iCloudDrive(home: home).path

        if path.hasPrefix(documents) || path.hasPrefix(iCloud) { return 1.0 }
        if path.hasPrefix(desktop) { return 0.96 }
        if path.hasPrefix(downloads) { return 0.88 }
        if path.hasPrefix(home.path + "/Library") { return 0.25 }
        if path.hasPrefix(home.path) { return 0.80 }
        if path.hasPrefix("/Volumes/") { return 0.70 }
        return 0.35
    }

    public func score(
        _ result: SearchResult,
        query: String,
        now: Date = Date()
    ) -> Double {
        var score = Double(NameMatch.classify(name: result.displayName, query: query).rawValue)

        switch result.kind {
        case .folder: score += weights.folderBonus
        case .application: score += weights.applicationBonus
        case .file: break
        }

        // Recency uses whichever is newer: when it changed, or when it was last opened — except
        // that a date written into the filename replaces the filesystem's. People name receipts
        // and scans by their real date; a copy or a re-save overwrites the filesystem's version
        // of that date with the day the file was moved, which means nothing.
        let stamped = Self.leadingDate(in: result.displayName).flatMap(Self.date(fromISO:))
        let touched = [stamped ?? result.modified, result.lastUsed].compactMap(\.self).max()
        if let touched {
            let days = max(0, now.timeIntervalSince(touched) / 86_400)
            score += weights.recencyBonus * pow(0.5, days / weights.recencyHalfLifeDays)
        }
        if result.lastUsed != nil { score += weights.openedBeforeBonus }

        let depth = result.url.pathComponents.count
        if depth > weights.shallowDepth {
            score -= min(weights.maxDepthPenalty, Double(depth - weights.shallowDepth) * weights.depthPenalty)
        }

        score *= locationWeight(for: result.url)
        return score
    }

    /// Collapse identical copies, score what's left, and sort.
    ///
    /// Duplicates are matched on name *and* size, so two genuinely different files that happen to
    /// share a name stay separate rows.
    ///
    /// A learned pick is not a bonus but an override: something the person chose for this exact
    /// query goes first, full stop. Scoring it higher would only mean it usually wins, and
    /// "usually" is not what a deliberate choice deserves.
    public func rank(
        _ results: [SearchResult],
        query: String,
        now: Date = Date(),
        learnedPicks: Set<URL> = []
    ) -> [SearchResult] {
        var collapsed: [String: SearchResult] = [:]
        var order: [String] = []

        for result in results {
            let key = "\(result.displayName.lowercased())|\(result.size ?? -1)|\(result.kind.rawValue)"
            if var existing = collapsed[key] {
                // Keep whichever copy scores higher; the rest become the expandable list.
                let keepExisting = score(existing, query: query, now: now)
                    >= score(result, query: query, now: now)
                if keepExisting {
                    existing.duplicates.append(result.url)
                    existing.duplicateCount += 1
                    collapsed[key] = existing
                } else {
                    var winner = result
                    winner.duplicates = existing.duplicates + [existing.url]
                    winner.duplicateCount = existing.duplicateCount + 1
                    collapsed[key] = winner
                }
            } else {
                collapsed[key] = result
                order.append(key)
            }
        }

        let survivors: [SearchResult] = order.compactMap { collapsed[$0] }
        var scored: [(result: SearchResult, score: Double)] = []
        scored.reserveCapacity(survivors.count)
        for item in survivors {
            let value = score(item, query: query, now: now)
            scored.append((result: item, score: value))
        }

        // Ties break on what was touched most recently, then on name so the order never jitters
        // between identical searches. Without the recency step, folders full of date-prefixed
        // files come back oldest-first, which is exactly backwards.
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let aTouched = [a.result.modified, a.result.lastUsed].compactMap(\.self).max()
            let bTouched = [b.result.modified, b.result.lastUsed].compactMap(\.self).max()
            // A date the person typed into the filename beats the one the filesystem recorded.
            // In an archive of receipts every file was copied in at once, so the modification
            // dates are an artefact of the copy while the filename dates are the real ones.
            if let aDated = Self.leadingDate(in: a.result.displayName),
               let bDated = Self.leadingDate(in: b.result.displayName) {
                if aDated != bDated { return aDated > bDated }
            } else if aTouched != bTouched {
                return (aTouched ?? .distantPast) > (bTouched ?? .distantPast)
            }
            return a.result.displayName < b.result.displayName
        }
        let ordered = scored.map(\.result)
        guard !learnedPicks.isEmpty else { return ordered }

        let picked = ordered.filter { learnedPicks.contains($0.url) }
        return picked + ordered.filter { !learnedPicks.contains($0.url) }
    }
}
