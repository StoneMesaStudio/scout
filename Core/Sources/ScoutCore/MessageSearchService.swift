// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Foundation

/// The Messages lane, kept off the main thread.
///
/// Building the index the first time means reading every message ever received, which on a long
/// history takes seconds — far too long to do while someone is typing. The actor owns the
/// database connection so the panel can await results without ever blocking the panel itself.
public actor MessageSearchService {

    public enum State: Sendable, Equatable {
        case idle
        case needsFullDiskAccess
        case building
        case ready
        case failed(String)
    }

    private let index: MessageIndex
    private var state: State = .idle
    private var lastSync: Date?
    private var hasRebuilt = false

    /// How stale the index is allowed to get before opening the lane tops it up again. Syncing is
    /// incremental, so this is cheap — it exists only to avoid re-reading on every keystroke.
    private let staleAfter: TimeInterval = 30

    public init(
        source: URL = MessageIndex.defaultSource(),
        location: URL = MessageIndex.defaultIndexLocation()
    ) {
        index = MessageIndex(source: source, location: location)
    }

    public func currentState() -> State { state }

    /// Bring the index up to date. Safe to call every time the lane is opened: after the first
    /// build it reads only what is new, and it does nothing at all if it ran a moment ago.
    ///
    /// The work is synchronous inside the actor, which keeps it off the main thread and makes
    /// two simultaneous calls impossible without any locking of our own.
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
        } catch let failure as MessageIndex.Failure {
            state = failure == .notAccessible ? .needsFullDiskAccess : .failed(failure.description)
        } catch {
            // The index is ours and rebuildable from the source, so a damaged one is worth
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

    public func search(_ query: String, limit: Int = 60) -> SearchPage<MessageHit> {
        do {
            return try index.search(query, limit: limit)
        } catch {
            // Reported rather than swallowed. A damaged index used to render as "no matches",
            // which is the one answer a search must never give when it did not actually look.
            state = .failed(error.localizedDescription)
            return .empty
        }
    }
}
