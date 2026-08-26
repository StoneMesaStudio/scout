// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Foundation

/// Everything Scout has written outside its own bundle, so it can all be taken back.
///
/// Dragging the app to the Trash leaves the indexes behind, and on the Mac this was written on
/// that is 349 MB of mail — the largest thing Scout owns and the one thing nobody would think to
/// look for. An app that reads someone's whole Mac owes them a clean way off it.
///
/// The inventory is here rather than in the app so it can be tested against a directory made up
/// for the purpose. Deleting a person's real preferences to prove that deleting works is not a
/// test anybody should run twice.
public enum Uninstall {

    /// One thing Scout leaves behind, named the way a person would name it rather than by path.
    public struct Leftover: Identifiable, Sendable, Equatable {
        public let title: String
        public let detail: String
        public let url: URL
        public let bytes: Int64

        public var id: String { url.path }

        public init(title: String, detail: String, url: URL, bytes: Int64) {
            self.title = title
            self.detail = detail
            self.url = url
            self.bytes = bytes
        }
    }

    /// What macOS will not let an app take back on its own.
    ///
    /// There is no API to revoke a TCC grant — by design, since an app that could revoke its own
    /// permissions could grant them too. Saying so plainly is the only honest option; the
    /// alternative is a person believing Scout is gone while three System Settings panes still
    /// list it.
    public static let permissionsOnlyTheUserCanRemove = [
        "Full Disk Access", "Contacts", "Reminders",
    ]

    /// Everything on disk, in the order worth reading it: biggest first, and the indexes first of
    /// all because that is the number that surprises people.
    public static func leftovers(
        bundleIdentifier: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [Leftover] {
        let candidates: [(String, String, String)] = [
            ("Search indexes", "What Scout built from your mail, messages and notes",
             "Library/Application Support/Scout"),
            ("Settings", "Sources, scope, exclusions and pinned places",
             "Library/Preferences/\(bundleIdentifier).plist"),
            ("Saved window state", "Where the panel was and how big",
             "Library/Saved Application State/\(bundleIdentifier).savedState"),
            ("Caches", "Temporary files macOS keeps for every app",
             "Library/Caches/\(bundleIdentifier)"),
            ("Stored web data", "Cookies and credentials macOS keeps per app — Scout writes none",
             "Library/HTTPStorages/\(bundleIdentifier)"),
        ]

        return candidates.compactMap { title, detail, path in
            let url = home.appending(path: path)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return Leftover(title: title, detail: detail, url: url,
                            bytes: size(of: url, fileManager: fileManager))
        }
    }

    /// Delete them, and report whatever survived rather than claiming a clean sweep.
    ///
    /// One failure does not stop the rest: a locked cache file should not leave 349 MB of index
    /// on the disk.
    @discardableResult
    public static func remove(
        _ leftovers: [Leftover],
        fileManager: FileManager = .default
    ) -> [Leftover] {
        leftovers.filter { leftover in
            do {
                try fileManager.removeItem(at: leftover.url)
                return false
            } catch {
                return fileManager.fileExists(atPath: leftover.url.path)
            }
        }
    }

    /// Bytes on disk, walking into a folder rather than reporting the folder's own 64 bytes.
    static func size(of url: URL, fileManager: FileManager = .default) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

        func bytes(_ item: URL) -> Int64 {
            guard let values = try? item.resourceValues(forKeys: keys) else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return bytes(url) }

        guard let walk = fileManager.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let child as URL in walk { total += bytes(child) }
        return total
    }

    /// "349 MB", for a sentence rather than a table.
    public static func readable(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
