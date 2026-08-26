// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Foundation

/// How recently something was touched.
public enum DateWindow: String, CaseIterable, Identifiable, Sendable {
    case today
    case thisWeek
    case thisMonth
    case thisYear

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: "Today"
        case .thisWeek: "This week"
        case .thisMonth: "This month"
        case .thisYear: "This year"
        }
    }

    public var days: Double {
        switch self {
        case .today: 1
        case .thisWeek: 7
        case .thisMonth: 31
        case .thisYear: 365
        }
    }

    public func contains(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) <= days * 86_400
    }
}

/// The chips under the search field, as data.
///
/// Every field here is a **wall**. A result that fails any active condition is removed before
/// ranking runs, and cannot come back with a high enough score. Spotlight's filters behave more
/// like suggestions, which is why narrowing a search there so often makes it worse.
public struct FileFilter: Sendable, Equatable {

    public var kinds: Set<FileKind>
    /// Folders to stay inside. Any one of them qualifies.
    public var folders: Set<URL>
    public var dateWindow: DateWindow?

    public init(kinds: Set<FileKind> = [], folders: Set<URL> = [], dateWindow: DateWindow? = nil) {
        self.kinds = kinds
        self.folders = folders
        self.dateWindow = dateWindow
    }

    public var isEmpty: Bool {
        kinds.isEmpty && folders.isEmpty && dateWindow == nil
    }

    public var activeCount: Int {
        kinds.count + folders.count + (dateWindow == nil ? 0 : 1)
    }

    public func matches(_ result: SearchResult, now: Date = Date()) -> Bool {
        if !kinds.isEmpty, !kinds.contains(FileKind.of(result)) { return false }

        if !folders.isEmpty {
            let path = result.url.path
            let inside = folders.contains { path.hasPrefix($0.path + "/") || path == $0.path }
            if !inside { return false }
        }

        if let dateWindow {
            let touched = [result.modified, result.lastUsed].compactMap(\.self).max()
            if !dateWindow.contains(touched, now: now) { return false }
        }

        return true
    }

    public func apply(to results: [SearchResult], now: Date = Date()) -> [SearchResult] {
        isEmpty ? results : results.filter { matches($0, now: now) }
    }

    // MARK: - Toggling, for the chip row

    public mutating func toggle(kind: FileKind) {
        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
    }

    public mutating func toggle(folder: URL) {
        if folders.contains(folder) { folders.remove(folder) } else { folders.insert(folder) }
    }

    public mutating func toggle(window: DateWindow) {
        dateWindow = dateWindow == window ? nil : window
    }

    public mutating func clear() {
        self = FileFilter()
    }
}
