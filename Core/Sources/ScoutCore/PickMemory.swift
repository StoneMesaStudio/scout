// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Foundation

/// Remembers which result the user chose for a given search, so it climbs next time.
///
/// Kept deliberately small and literal: an exact query string maps to the last thing opened for
/// it. No inference, no decay — the user picked it, so it wins, and picking something else
/// replaces it.
// `@unchecked` because UserDefaults is thread-safe but predates Sendable; the struct itself
// holds nothing else.
public struct PickMemory: @unchecked Sendable {

    private static let defaultsKey = "ScoutPickMemory"
    private let store: UserDefaults

    public init(store: UserDefaults = .standard) {
        self.store = store
    }

    private func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var table: [String: String] {
        get { store.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:] }
        nonmutating set { store.set(newValue, forKey: Self.defaultsKey) }
    }

    public func record(query: String, url: URL) {
        let key = normalize(query)
        guard !key.isEmpty else { return }
        var updated = table
        updated[key] = url.path
        table = updated
    }

    /// The URLs to boost for this query. A set because callers pass it straight to the ranker.
    public func picks(for query: String) -> Set<URL> {
        guard let path = table[normalize(query)] else { return [] }
        return [URL(filePath: path)]
    }

    public func forget(query: String) {
        var updated = table
        updated[normalize(query)] = nil
        table = updated
    }
}
