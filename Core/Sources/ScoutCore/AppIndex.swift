// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import CoreServices
import Foundation

/// The installed applications, scanned once and matched by exact name.
///
/// Launching an app is the most common thing ⌘-Space does, so a search that only returned files
/// would break thirty years of muscle memory. The compromise: apps get their own lane, but typing
/// an app's name *exactly* pins that one app to the top of the file results. Only exact matches
/// qualify — a partial match would put Mail above every file whose name starts with "mai".
public struct AppIndex: Sendable {

    public struct Entry: Sendable, Hashable, Identifiable {
        public let url: URL
        public let name: String
        /// When the Mac last recorded this app being launched. Used to order the Apps lane when
        /// nothing has been typed yet — "what I actually use" beats alphabetical.
        public let lastUsed: Date?

        public var id: URL { url }

        public init(url: URL, name: String, lastUsed: Date? = nil) {
            self.url = url
            self.name = name
            self.lastUsed = lastUsed
        }
    }

    public private(set) var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public static func defaultSearchPaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            URL(filePath: "/Applications"),
            URL(filePath: "/Applications/Utilities"),
            URL(filePath: "/System/Applications"),
            URL(filePath: "/System/Applications/Utilities"),
            home.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    /// Scan the usual application folders. One level deep only — nested `.app` bundles are
    /// helpers and frameworks, not things anyone launches.
    public static func scan(paths: [URL] = defaultSearchPaths()) -> AppIndex {
        let fm = FileManager.default
        var entries: [Entry] = []

        for folder in paths {
            guard let contents = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents where url.pathExtension == "app" {
                entries.append(Entry(
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    lastUsed: lastUsedDate(of: url)
                ))
            }
        }

        return AppIndex(entries: entries)
    }

    /// Reads the launch date Spotlight already records for the bundle. `MDItem` is the only
    /// public way to ask for a single file's indexed attributes without running a whole query,
    /// and /Applications is not a protected location, so this needs no permission.
    private static func lastUsedDate(of url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// The single app whose name is exactly the query, ignoring case. Nil for anything else.
    public func exactMatch(for query: String) -> Entry? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !needle.isEmpty else { return nil }

        return entries.first {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == needle
        }
    }

    /// The Apps lane: every app whose name contains the query.
    ///
    /// With nothing typed it shows what was launched most recently rather than an alphabetical
    /// wall — the list is there to be picked from, not read.
    public func matches(for query: String) -> [Entry] {
        func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }

        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return entries.sorted(by: mostRecentlyUsed) }

        return entries
            .filter { fold($0.name).contains(needle) }
            .sorted { a, b in
                // Best name match wins; ties fall back to what was used most recently.
                let rankA = matchRank(fold(a.name), needle)
                let rankB = matchRank(fold(b.name), needle)
                return rankA == rankB ? mostRecentlyUsed(a, b) : rankA > rankB
            }
    }

    private func matchRank(_ name: String, _ needle: String) -> Int {
        if name == needle { return 3 }
        if name.hasPrefix(needle) { return 2 }
        if name.components(separatedBy: " ").contains(where: { $0.hasPrefix(needle) }) { return 1 }
        return 0
    }

    private func mostRecentlyUsed(_ a: Entry, _ b: Entry) -> Bool {
        switch (a.lastUsed, b.lastUsed) {
        case let (x?, y?): return x == y ? a.name < b.name : x > y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.name < b.name
        }
    }
}
