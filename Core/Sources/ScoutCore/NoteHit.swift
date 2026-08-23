import Foundation

/// One note found in Apple Notes.
public struct NoteHit: Identifiable, Sendable, Hashable {

    /// Notes' own row for this note. Stable enough to key an index on, and what Scout stores.
    public let rowID: Int64
    /// The UUID Notes uses for the note, which is what opens it.
    public let identifier: String?
    public let title: String
    public let folder: String?
    public let account: String?
    public let modified: Date?
    /// A few words either side of the match, when the match was in the body.
    public let snippet: String?
    /// A locked note: Notes encrypts the body, so only its title is searchable.
    public let isLocked: Bool

    public var id: Int64 { rowID }

    public init(
        rowID: Int64,
        identifier: String?,
        title: String,
        folder: String?,
        account: String?,
        modified: Date?,
        snippet: String? = nil,
        isLocked: Bool = false
    ) {
        self.rowID = rowID
        self.identifier = identifier
        self.title = title
        self.folder = folder
        self.account = account
        self.modified = modified
        self.snippet = snippet
        self.isLocked = isLocked
    }

    /// What to show under the title: where the note lives, when it changed, and — when the match
    /// was in the body rather than the title — the words that matched.
    public var detail: String {
        var parts: [String] = []
        if let folder, !folder.isEmpty { parts.append(folder) }
        if let modified { parts.append(modified.formatted(date: .abbreviated, time: .omitted)) }
        if let snippet, !snippet.isEmpty { parts.append(snippet) }
        return parts.joined(separator: " · ")
    }

    /// Opens the note in Notes.
    ///
    /// `notes://showNote?identifier=` is Notes' own scheme and takes the note's UUID. Without an
    /// identifier there is nothing to open, and the panel falls back to launching Notes itself.
    public var openURL: URL? {
        guard let identifier, !identifier.isEmpty else { return nil }
        guard let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "notes://showNote?identifier=\(encoded)")
    }

    /// Core Data keeps its dates as seconds since 2001, like the rest of Apple's stores.
    public static func date(fromCoreData raw: Double) -> Date? {
        guard raw > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: raw)
    }
}
