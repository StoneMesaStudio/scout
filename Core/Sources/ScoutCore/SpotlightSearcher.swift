import Foundation

/// Reads the same index Spotlight and Finder read, through `NSMetadataQuery`.
///
/// Nothing here builds an index of its own — macOS already has one, kept current by the system,
/// covering names, dates, tags and the text inside documents. What the system does not expose is
/// its ordering, which is exactly the part being replaced: this asks for raw matches and hands
/// them to `Ranker`.
@MainActor
public final class SpotlightSearcher {

    /// Raw matches, delivered as the query gathers them and again when it settles.
    public var onResults: (([SearchResult]) -> Void)?

    private let query = NSMetadataQuery()
    private let home: URL

    /// Notification tokens, held outside actor isolation so `deinit` can unregister them.
    /// Only ever written on the main actor, in `init`.
    private final class TokenBox: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
    }
    private nonisolated let tokens = TokenBox()

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        query.notificationBatchingInterval = 0.12
        // We sort ourselves, so ask the system for nothing but the matches.
        query.sortDescriptors = []

        let center = NotificationCenter.default
        for name in [
            NSNotification.Name.NSMetadataQueryGatheringProgress,
            NSNotification.Name.NSMetadataQueryDidFinishGathering,
            NSNotification.Name.NSMetadataQueryDidUpdate,
        ] {
            let token = center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish() }
            }
            tokens.tokens.append(token)
        }
    }

    deinit {
        let center = NotificationCenter.default
        for token in tokens.tokens { center.removeObserver(token) }
    }

    public func stop() {
        query.stop()
    }

    /// Start a fresh search. Calling this again replaces the one in flight.
    ///
    /// `folder` narrows the search to one directory — what pressing Tab on a folder row does —
    /// and takes precedence over the scope.
    public func search(_ text: String, scope: SearchScope, folder: URL? = nil) {
        let directories = folder.map { [$0] } ?? SearchScope.directories(for: scope, home: home)
        search(text, directories: directories)
    }

    /// Search a specific set of directories. An empty list means the whole indexed Mac.
    public func search(_ text: String, directories: [URL]) {
        query.stop()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            onResults?([])
            return
        }

        query.predicate = Self.predicate(for: trimmed)
        query.searchScopes = directories.isEmpty ? [NSMetadataQueryLocalComputerScope] : directories
        query.start()
    }

    /// Matches the query against names first and document text second.
    ///
    /// `LIKE[cd]` is case- and diacritic-insensitive; the `*` wildcards make it a contains match.
    /// Any `*` or `?` the user typed is escaped so it searches for the character rather than
    /// acting as a wildcard.
    public nonisolated static func predicate(for text: String) -> NSPredicate {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
        let wildcard = "*\(escaped)*"
        return NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemDisplayNameKey, wildcard),
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, wildcard),
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemTextContentKey, wildcard),
        ])
    }

    private func publish() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var results: [SearchResult] = []
        results.reserveCapacity(query.resultCount)

        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            results.append(Self.result(from: item, path: path))
        }

        onResults?(results)
    }

    private static func result(from item: NSMetadataItem, path: String) -> SearchResult {
        let url = URL(filePath: path)
        let contentType = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
        let name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
            ?? url.lastPathComponent

        let kind: SearchResult.Kind
        switch contentType {
        case "com.apple.application-bundle": kind = .application
        case "public.folder", "public.directory": kind = .folder
        default: kind = url.hasDirectoryPath ? .folder : .file
        }

        return SearchResult(
            url: url,
            displayName: name,
            kind: kind,
            contentType: contentType,
            modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
            lastUsed: item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date,
            size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value
        )
    }
}
