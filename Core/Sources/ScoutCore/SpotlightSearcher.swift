// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Foundation
import Synchronization

/// Reads the same index Spotlight and Finder read, through `NSMetadataQuery`.
///
/// Nothing here builds an index of its own — macOS already has one, kept current by the system,
/// covering names, dates, tags and the text inside documents. What the system does not expose is
/// its ordering, which is exactly the part being replaced: this asks for raw matches and hands
/// them to `Ranker`.
///
/// **Two rules, both paid for in beachballs.**
///
/// 1. *Declare the attributes up front.* Asking a result for its name, kind, dates or size one at
///    a time is a round trip to the Spotlight server each — measured at 257–354 µs apiece, so five
///    of them per match came to 1.57 ms, and 6,818 matches held the main thread for 3.7 seconds.
///    Named in `valueListAttributes`, the same values come back with the results and read in about
///    0.06 µs. The path is the exception: it is not a stored attribute, the list returns nothing
///    for it, and the item already carries it locally for 3 µs.
///
/// 2. *Keep the query off the main thread.* Starting a query resolves and opens every folder in its
///    scope, and a folder the iCloud file provider has let go cold took 54,951 ms to open on one Mac
///    and 0.0 ms on the next five tries. The query lives on its own serial queue, so however long
///    Spotlight or the file provider takes, the panel keeps drawing and only the file results are
///    late. Finished results cross to the main thread in one piece.
public final class SpotlightSearcher: @unchecked Sendable {

    /// Raw matches, delivered on the main thread as the query gathers them and again when it
    /// settles. Set once, before the first search.
    @MainActor public var onResults: (([SearchResult]) -> Void)?

    /// The values that come back with the results rather than one round trip at a time.
    private static let declaredAttributes = [
        NSMetadataItemDisplayNameKey,
        NSMetadataItemContentTypeKey,
        NSMetadataItemFSContentChangeDateKey,
        NSMetadataItemLastUsedDateKey,
        NSMetadataItemFSSizeKey,
    ]

    private static let throttle = DeliveryThrottle(gap: .milliseconds(350))

    private let home: URL

    /// Everything below this line is touched only on `queue`.
    private let queue = DispatchQueue(label: "studio.stonemesa.scout.spotlight", qos: .userInitiated)
    private let operations = OperationQueue()
    private let query = NSMetadataQuery()
    private var pendingDelivery: DispatchWorkItem?
    private var lastDelivery: ContinuousClock.Instant?
    /// Which search the running query belongs to. Its deliveries carry this number.
    private var runningGeneration = 0

    /// Bumped on the caller's thread by every `search` and `stop`, so a delivery already on its
    /// way to the main thread can tell it has been overtaken and drop itself. Without this, results
    /// for the word typed a moment ago land after the panel has been cleared for the new one.
    private let generation = Atomic<Int>(0)

    /// Notification tokens, kept so `deinit` can unregister them.
    private final class TokenBox: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
    }
    private let tokens = TokenBox()

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home

        operations.underlyingQueue = queue
        operations.maxConcurrentOperationCount = 1

        query.operationQueue = operations
        query.notificationBatchingInterval = 0.12
        // We sort ourselves, so the system is asked for no ordering at all.
        query.sortDescriptors = []
        query.valueListAttributes = Self.declaredAttributes

        let center = NotificationCenter.default
        for name in [
            NSNotification.Name.NSMetadataQueryGatheringProgress,
            NSNotification.Name.NSMetadataQueryDidFinishGathering,
            NSNotification.Name.NSMetadataQueryDidUpdate,
        ] {
            // Finishing is the one notification worth interrupting anything for: it is the
            // complete answer, and it arrives once. Progress and updates are coalesced.
            let isFinal = name == NSNotification.Name.NSMetadataQueryDidFinishGathering
            let token = center.addObserver(forName: name, object: query, queue: operations) { [weak self] _ in
                if isFinal { self?.deliverNow() } else { self?.scheduleDelivery() }
            }
            tokens.tokens.append(token)
        }
    }

    deinit {
        let center = NotificationCenter.default
        for token in tokens.tokens { center.removeObserver(token) }
    }

    // MARK: - Asking

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
        let current = generation.add(1, ordering: .relaxed).newValue
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count >= 2 else {
            queue.async { [self] in halt() }
            deliver([], for: current)
            return
        }

        queue.async { [self] in
            halt()

            // Open every folder about to be searched before starting, here, where waiting costs
            // nothing. `start()` opens them anyway; doing it first means a cold iCloud folder holds
            // up this queue rather than the window.
            for url in directories {
                let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY)
                if descriptor >= 0 { Darwin.close(descriptor) }
            }

            // Somebody kept typing while the folders were being opened.
            guard generation.load(ordering: .relaxed) == current else { return }

            runningGeneration = current
            query.predicate = Self.predicate(for: trimmed)
            query.searchScopes = directories.isEmpty ? [NSMetadataQueryLocalComputerScope] : directories
            query.start()
        }
    }

    public func stop() {
        generation.add(1, ordering: .relaxed)
        queue.async { [self] in halt() }
    }

    /// Matches the query against names first and document text second.
    ///
    /// `LIKE[cd]` is case- and diacritic-insensitive; the `*` wildcards make it a contains match.
    /// Any `*` or `?` the user typed is escaped so it searches for the character rather than
    /// acting as a wildcard.
    public static func predicate(for text: String) -> NSPredicate {
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

    // MARK: - On the queue

    private func halt() {
        pendingDelivery?.cancel()
        pendingDelivery = nil
        query.stop()
    }

    /// Queue a delivery, unless one is already queued.
    private func scheduleDelivery() {
        guard pendingDelivery == nil else { return }

        let wait = Self.throttle.wait(sinceLastDelivery: lastDelivery.map { ContinuousClock().now - $0 })
        let parts = wait.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingDelivery = nil
            publish()
        }
        pendingDelivery = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Deliver at once, dropping anything queued — it would only repeat this.
    private func deliverNow() {
        pendingDelivery?.cancel()
        pendingDelivery = nil
        publish()
    }

    private func publish() {
        lastDelivery = ContinuousClock().now

        query.disableUpdates()
        var results: [SearchResult] = []
        results.reserveCapacity(query.resultCount)

        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            results.append(result(at: index, path: path))
        }
        query.enableUpdates()

        deliver(results, for: runningGeneration)
    }

    /// Everything but the path, read from what the query already holds.
    private func result(at index: Int, path: String) -> SearchResult {
        func value<T>(_ attribute: String, as: T.Type) -> T? {
            query.value(ofAttribute: attribute, forResultAt: index) as? T
        }

        let url = URL(filePath: path)
        let contentType = value(NSMetadataItemContentTypeKey, as: String.self)
        let name = value(NSMetadataItemDisplayNameKey, as: String.self) ?? url.lastPathComponent

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
            modified: value(NSMetadataItemFSContentChangeDateKey, as: Date.self),
            lastUsed: value(NSMetadataItemLastUsedDateKey, as: Date.self),
            size: value(NSMetadataItemFSSizeKey, as: NSNumber.self)?.int64Value
        )
    }

    /// Hand results to the main thread, unless a newer search has started since they were made.
    private func deliver(_ results: [SearchResult], for searchGeneration: Int) {
        DispatchQueue.main.async { [self] in
            guard generation.load(ordering: .relaxed) == searchGeneration else { return }
            MainActor.assumeIsolated { onResults?(results) }
        }
    }
}
