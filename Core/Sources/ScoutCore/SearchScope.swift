// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Foundation

/// Where a file search is allowed to look.
///
/// A scope is a hard boundary, not a preference: everything outside it is dropped before
/// anything is scored. That is the difference between this and Spotlight, where narrowing a
/// search still lets unrelated matches drift back to the top.
public enum SearchScope: String, Sendable, CaseIterable, Identifiable {
    /// Documents, iCloud Drive, Desktop and Downloads — the places the user actually puts things.
    case myFiles
    /// Everything the Mac has indexed, including system folders and other volumes.
    case wholeMac

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .myFiles: "My Files"
        case .wholeMac: "Whole Mac"
        }
    }

    /// The directories a `.myFiles` search covers.
    ///
    /// iCloud Drive is in here deliberately. Its container holds *every* file the user keeps in
    /// iCloud, including ones not yet downloaded to this Mac — Spotlight still indexes their
    /// names and dates locally, so they are findable and openable even before the bytes arrive.
    public static func directories(for scope: SearchScope, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        switch scope {
        case .wholeMac:
            return []
        case .myFiles:
            return [
                home.appending(path: "Documents", directoryHint: .isDirectory),
                home.appending(path: "Desktop", directoryHint: .isDirectory),
                home.appending(path: "Downloads", directoryHint: .isDirectory),
                Self.iCloudDrive(home: home),
            ]
        }
    }

    /// The on-disk home of iCloud Drive. Apple exposes no public constant for it; this path has
    /// been stable since iCloud Drive shipped, and `NSMetadataQuery`'s ubiquitous scopes only
    /// cover an app's *own* container, which is not what we want.
    public static func iCloudDrive(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    }
}
