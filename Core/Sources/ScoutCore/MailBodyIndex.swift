import Foundation

/// Scout's own full-text index of what mail actually says.
///
/// Mail's Envelope Index holds subjects, senders and mailboxes but not a word of body text —
/// searching it finds 26 messages for a name where Mail itself finds 2,367. The bodies live in
/// the message files on disk, one per message, so this reads them and keeps an index of its own.
///
/// Two limits, widened on 2026-08-23. 256 KB of each file is read and 48,000 characters of text
/// are kept from it. The first pass used 64 KB and 16,000, and searching "jose" found 1,606
/// messages where Mail itself finds 2,367 — the gap being text that sits past the read window in
/// long or image-heavy messages, and text past the keep limit in long ones.
///
/// Both limits exist because a MIME message puts its text parts before its attachments, so a
/// bounded read catches the words while skipping the megabytes. What neither fixes is text inside
/// attachments, which Scout does not read at all; that is the rest of the gap.
///
/// Each message is stored under its RFC Message-ID rather than its file path, because Mail moves
/// files between mailboxes and the ID does not change.
///
/// **Changing either limit invalidates every row.** The values are recorded in the index and
/// checked when it opens; if they differ, the index empties itself and the next sync reads the
/// archive again. Leaving old rows in place would mean a search silently covering some messages
/// to 64 KB and others to 256 KB, with no way to tell which.
public final class MailBodyIndex {

    public struct Progress: Sendable, Equatable {
        public let indexed: Int
        public let remaining: Int

        public var isComplete: Bool { remaining == 0 }
        public var total: Int { indexed + remaining }
    }

    /// How much of each message file to read.
    static let readLimit = 256 * 1024
    /// How much text to keep from one message.
    static let bodyLimit = 48_000

    private let mailDirectory: URL
    private let location: URL
    private var index: SQLiteDatabase?

    public init(
        mailDirectory: URL = MailIndex.defaultDirectory(),
        location: URL = MailBodyIndex.defaultLocation()
    ) {
        self.mailDirectory = mailDirectory
        self.location = location
    }

    public static func defaultLocation(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appending(path: "Library/Application Support/Scout/mail-bodies.sqlite")
    }

    public var databaseLocation: URL { location }

    public var isAccessible: Bool {
        StoreAccess.canRead(directory: mailDirectory)
    }

    /// How big the index has grown, for the settings screen.
    public var sizeOnDisk: Int64 {
        let sizes = ["", "-wal", "-shm"].map { suffix -> Int64 in
            let url = URL(filePath: location.path + suffix)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values?.fileSize ?? 0)
        }
        return sizes.reduce(0, +)
    }

    // MARK: - Building

    /// Index up to `budget` more message files and report what is left.
    ///
    /// Bounded on purpose: the first pass over a long archive is tens of thousands of files, and
    /// doing it in slices keeps the lane usable while it works rather than freezing until done.
    @discardableResult
    public func sync(budget: Int = 2_000) throws -> Progress {
        guard isAccessible else { throw MailIndex.Failure.notAccessible }
        let index = try openIndex()

        var alreadyIndexed = Set<String>()
        let known = try index.prepare("SELECT path FROM files")
        while try known.step() {
            if let path = known.string(0) { alreadyIndexed.insert(path) }
        }

        var pending: [URL] = []
        var remaining = 0
        let fileManager = FileManager.default

        if let walker = fileManager.enumerator(at: mailDirectory, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "emlx" {
                guard !alreadyIndexed.contains(url.path) else { continue }
                if pending.count < budget {
                    pending.append(url)
                } else {
                    remaining += 1
                }
            }
        }

        guard !pending.isEmpty else {
            return Progress(indexed: alreadyIndexed.count, remaining: 0)
        }

        try index.execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? index.execute("ROLLBACK") } }

        let insertBody = try index.prepare("INSERT INTO bodies(message_id, body) VALUES (?1, ?2)")
        let insertFile = try index.prepare("INSERT OR REPLACE INTO files(path) VALUES (?1)")

        var added = 0
        for url in pending {
            // Every file is recorded, even one we could not read a body out of, so a broken
            // message is skipped once rather than retried on every sync forever.
            insertFile.reset()
            insertFile.bind(url.path, at: 1)
            try insertFile.step()

            guard let parsed = Self.parse(url), !parsed.body.isEmpty else { continue }

            insertBody.reset()
            insertBody.bind(parsed.messageID, at: 1)
            insertBody.bind(parsed.body, at: 2)
            try insertBody.step()
            added += 1
        }

        try index.execute("COMMIT")
        committed = true

        return Progress(indexed: alreadyIndexed.count + pending.count, remaining: remaining)
    }

    public func rebuild() throws {
        index = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(filePath: location.path + suffix))
        }
        try sync()
    }

    /// Throw the index away without rebuilding — what "turn body search off" does.
    public func remove() {
        index = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(filePath: location.path + suffix))
        }
    }

    public func progress() throws -> Progress {
        let index = try openIndex()
        let counter = try index.prepare("SELECT COUNT(*) FROM files")
        let indexed = try counter.step() ? Int(counter.int64(0)) : 0

        var onDisk = 0
        if let walker = FileManager.default.enumerator(at: mailDirectory, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "emlx" { onDisk += 1 }
        }
        return Progress(indexed: indexed, remaining: max(0, onDisk - indexed))
    }

    // MARK: - Reading a message file

    struct Parsed {
        let messageID: String
        let body: String
    }

    /// Pull the Message-ID and the readable text out of one `.emlx`.
    static func parse(_ url: URL) -> Parsed? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: readLimit), !data.isEmpty else { return nil }

        // Lossy on purpose: mail is full of declared encodings we are not going to honour, and a
        // few mangled characters cost nothing in a search index.
        let text = String(decoding: data, as: UTF8.self)

        // An .emlx begins with a line holding the byte count of the message that follows.
        // Split on any newline: mail uses CRLF, and Swift treats CRLF as a single character, so
        // looking for a bare "\n" finds nothing at all.
        let afterCount = text.firstIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
        let message = text[afterCount...]

        guard let separator = message.range(of: "\r\n\r\n") ?? message.range(of: "\n\n") else {
            return nil
        }
        let headers = String(message[..<separator.lowerBound])
        let body = String(message[separator.upperBound...])

        guard let messageID = header("Message-ID", in: headers) else { return nil }
        let isHTML = header("Content-Type", in: headers)?.localizedCaseInsensitiveContains("text/html") ?? false
        let quoted = header("Content-Transfer-Encoding", in: headers)?
            .localizedCaseInsensitiveContains("quoted-printable") ?? false

        return Parsed(
            messageID: normalize(messageID),
            body: readableText(from: body, isHTML: isHTML, quotedPrintable: quoted)
        )
    }

    /// A header's value, including any folded continuation lines.
    static func header(_ name: String, in headers: String) -> String? {
        let needle = name.lowercased() + ":"
        var value: String?

        // Split on any newline rather than on "\n": mail line endings are CRLF, and Swift reads
        // CRLF as one Character, so splitting on a bare newline returns the whole block as a
        // single line — which is how this silently found no headers at all.
        for line in headers.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let text = String(line)

            if value != nil {
                // Folded lines begin with whitespace.
                if text.first == " " || text.first == "\t" {
                    value! += " " + text.trimmingCharacters(in: .whitespaces)
                    continue
                }
                break
            }
            if text.lowercased().hasPrefix(needle) {
                value = String(text.dropFirst(needle.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return value
    }

    /// Message-IDs are compared without their angle brackets, because Mail records them one way
    /// in one place and the other way in another.
    static func normalize(_ messageID: String) -> String {
        messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
    }

    /// Turn a raw message body into words worth indexing.
    static func readableText(from body: String, isHTML: Bool, quotedPrintable: Bool) -> String {
        var text = body

        if quotedPrintable {
            // Soft line breaks first, then the =XX escapes that carry accented characters.
            text = text.replacingOccurrences(of: "=\r\n", with: "")
            text = text.replacingOccurrences(of: "=\n", with: "")
            text = decodeQuotedPrintable(text)
        }

        if isHTML || text.contains("<html") || text.contains("<HTML") {
            text = stripTags(from: text)
        }

        // Base64 blocks are attachments and inline images — long unbroken runs of nothing
        // anyone would search for, and they would swamp the index.
        let words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count < 60 && !$0.isEmpty }

        return String(words.joined(separator: " ").prefix(bodyLimit))
    }

    static func decodeQuotedPrintable(_ text: String) -> String {
        // Decoded into bytes and read back as UTF-8 at the end, not character by character: an
        // accented letter arrives as two escapes that only mean anything together, so decoding
        // each one on its own turns "café" into "cafÃ©".
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)

        let characters = Array(text)
        var index = 0
        while index < characters.count {
            if characters[index] == "=", index + 2 < characters.count,
               let byte = UInt8(String(characters[(index + 1)...(index + 2)]), radix: 16) {
                bytes.append(byte)
                index += 3
            } else {
                bytes.append(contentsOf: Array(String(characters[index]).utf8))
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func stripTags(from html: String) -> String {
        var result = ""
        var insideTag = false
        var insideScript = false
        var buffer = ""

        for character in html {
            if character == "<" {
                insideTag = true
                buffer = ""
                continue
            }
            if character == ">" {
                insideTag = false
                let tag = buffer.lowercased()
                if tag.hasPrefix("script") || tag.hasPrefix("style") { insideScript = true }
                if tag.hasPrefix("/script") || tag.hasPrefix("/style") { insideScript = false }
                result.append(" ")
                continue
            }
            if insideTag {
                buffer.append(character)
            } else if !insideScript {
                result.append(character)
            }
        }

        return result
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    // MARK: - Plumbing

    private func openIndex() throws -> SQLiteDatabase {
        if let index { return index }

        let database = try SQLiteDatabase.openOrCreate(location)
        try database.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS bodies USING fts5(
                message_id UNINDEXED,
                body,
                tokenize = 'unicode61 remove_diacritics 2'
            );
            CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS limits(key TEXT PRIMARY KEY, value INTEGER);
        """)
        try emptyIfLimitsChanged(database)
        index = database
        return database
    }

    /// Rows read under a different pair of limits are not comparable to rows read under these, so
    /// when the limits move the index starts again rather than becoming a mixture.
    ///
    /// This empties the tables instead of deleting the file, so the settings screen's progress
    /// goes back to zero and climbs — a database that vanishes and reappears looks like a fault.
    private func emptyIfLimitsChanged(_ database: SQLiteDatabase) throws {
        let wanted: [(String, Int64)] = [("read", Int64(Self.readLimit)), ("body", Int64(Self.bodyLimit))]

        var matches = true
        for (key, value) in wanted {
            let statement = try database.prepare("SELECT value FROM limits WHERE key = ?1")
            statement.bind(key, at: 1)
            let stored = try statement.step() ? statement.int64(0) : -1
            if stored != value { matches = false }
        }
        guard !matches else { return }

        try database.execute("DELETE FROM bodies")
        try database.execute("DELETE FROM files")
        let write = try database.prepare("INSERT OR REPLACE INTO limits(key, value) VALUES (?1, ?2)")
        for (key, value) in wanted {
            write.reset()
            write.bind(key, at: 1)
            write.bind(value, at: 2)
            try write.step()
        }
    }
}
