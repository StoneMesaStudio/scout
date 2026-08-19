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

        // Word prefix: the query starts any word in the name. This is the one that puts
        // "Ford F350 Service Receipts" above "webservices.log" for the query "service".
        let separators = CharacterSet(charactersIn: " -_.·/()[]")
        for word in name.components(separatedBy: separators) where word.hasPrefix(query) {
            return .wordPrefix
        }

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
        public var recencyBonus: Double = 220
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

        // Recency uses whichever is newer: when it changed, or when it was last opened.
        let touched = [result.modified, result.lastUsed].compactMap(\.self).max()
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

        // Ties break on name so the order never jitters between identical searches.
        scored.sort { a, b in
            a.score == b.score ? a.result.displayName < b.result.displayName : a.score > b.score
        }
        let ordered = scored.map(\.result)
        guard !learnedPicks.isEmpty else { return ordered }

        let picked = ordered.filter { learnedPicks.contains($0.url) }
        return picked + ordered.filter { !learnedPicks.contains($0.url) }
    }
}
