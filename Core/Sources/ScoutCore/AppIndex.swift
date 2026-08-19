import Foundation

/// The installed applications, scanned once and matched by exact name.
///
/// Launching an app is the most common thing ⌘-Space does, so a search that only returned files
/// would break thirty years of muscle memory. The compromise: apps get their own lane, but typing
/// an app's name *exactly* pins that one app to the top of the file results. Only exact matches
/// qualify — a partial match would put Mail above every file whose name starts with "mai".
public struct AppIndex: Sendable {

    public struct Entry: Sendable, Hashable {
        public let url: URL
        public let name: String

        public init(url: URL, name: String) {
            self.url = url
            self.name = name
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
                entries.append(Entry(url: url, name: url.deletingPathExtension().lastPathComponent))
            }
        }

        return AppIndex(entries: entries)
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

    /// Every app whose name contains the query — the Apps lane, which arrives in a later phase.
    public func matches(for query: String) -> [Entry] {
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !needle.isEmpty else { return entries.sorted { $0.name < $1.name } }

        return entries
            .filter { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(needle) }
            .sorted { $0.name < $1.name }
    }
}
