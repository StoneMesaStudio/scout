import Foundation

/// The chips offered under the search field.
///
/// They are derived from the results actually on screen rather than from a fixed list, so the
/// choices are always ones that would narrow *this* search. Offering "Presentations" when nothing
/// found is a presentation is how a filter row becomes wallpaper.
public struct FilterSuggestions: Sendable, Equatable {

    public struct FolderChip: Sendable, Equatable, Identifiable {
        public let url: URL
        public let name: String
        public let count: Int
        public var id: URL { url }
    }

    public let folders: [FolderChip]
    public let kinds: [FileKind]
    public let windows: [DateWindow]

    public var isEmpty: Bool { folders.isEmpty && kinds.isEmpty && windows.isEmpty }

    public init(folders: [FolderChip], kinds: [FileKind], windows: [DateWindow]) {
        self.folders = folders
        self.kinds = kinds
        self.windows = windows
    }

    /// Build the chip row for a set of results.
    ///
    /// - Parameters:
    ///   - folderLimit: how many folder chips to offer. Past a handful they stop being a
    ///     shortcut and start being a list to read.
    public static func from(
        _ results: [SearchResult],
        now: Date = Date(),
        folderLimit: Int = 4
    ) -> FilterSuggestions {
        var folderCounts: [URL: Int] = [:]
        var kindsPresent: Set<FileKind> = []
        var newest: Date?

        for result in results {
            let parent = result.url.deletingLastPathComponent()
            folderCounts[parent, default: 0] += 1
            kindsPresent.insert(FileKind.of(result))
            if let touched = [result.modified, result.lastUsed].compactMap(\.self).max() {
                newest = max(newest ?? touched, touched)
            }
        }

        // A folder chip only earns its place if it holds more than one match — narrowing to a
        // folder with a single result in it is the same as clicking the result.
        let folders = folderCounts
            .filter { $0.value > 1 }
            .sorted {
                $0.value == $1.value
                    ? $0.key.lastPathComponent < $1.key.lastPathComponent
                    : $0.value > $1.value
            }
            .prefix(folderLimit)
            .map { FolderChip(url: $0.key, name: $0.key.lastPathComponent, count: $0.value) }

        let kinds = FileKind.allCases.filter { kindsPresent.contains($0) && $0 != .other }

        // Only offer date windows that would actually match something.
        let windows = DateWindow.allCases.filter { window in
            results.contains { result in
                let touched = [result.modified, result.lastUsed].compactMap(\.self).max()
                return window.contains(touched, now: now)
            }
        }

        return FilterSuggestions(folders: Array(folders), kinds: kinds, windows: windows)
    }
}
