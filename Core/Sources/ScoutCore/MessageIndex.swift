import Foundation

/// Scout's own full-text index of the Messages history.
///
/// This is the one lane that does not ride on Spotlight, because macOS barely indexes texts —
/// which is exactly why searching Messages is so bad today. Scout reads `chat.db` once, pulls the
/// text out of every message (including the ones stored only as styled blobs), and keeps its own
/// FTS5 index that it tops up with whatever is new.
///
/// Reading `chat.db` needs Full Disk Access. Without it every call throws `notAccessible`, which
/// is what the Messages lane shows as an explanation rather than an empty list.
public final class MessageIndex {

    public enum Failure: Error, CustomStringConvertible {
        case notAccessible
        case unexpectedDatabase

        public var description: String {
            switch self {
            case .notAccessible:
                "Scout needs Full Disk Access to read your messages."
            case .unexpectedDatabase:
                "The Messages database is not in the shape Scout expects."
            }
        }
    }

    /// Where macOS keeps the Messages history.
    public static func defaultSource(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Messages/chat.db")
    }

    /// Where Scout keeps its own index.
    public static func defaultIndexLocation(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appending(path: "Library/Application Support/Scout/messages.sqlite")
    }

    private let source: URL
    private let location: URL
    private var index: SQLiteDatabase?

    public init(source: URL = MessageIndex.defaultSource(), location: URL = MessageIndex.defaultIndexLocation()) {
        self.source = source
        self.location = location
    }

    /// True when `chat.db` can be opened at all — the plain-language version of "has the user
    /// granted Full Disk Access yet".
    public var sourceIsReadable: Bool {
        StoreAccess.canRead(file: source)
    }

    // MARK: - Building

    /// Bring the index up to date. Cheap after the first run: only messages newer than the
    /// highest row already indexed are read.
    ///
    /// - Returns: how many messages were added.
    @discardableResult
    public func sync() throws -> Int {
        let index = try openIndex()
        let chat = try openSource()

        guard chat.hasTable("message") else { throw Failure.unexpectedDatabase }

        var since = try highestIndexedRowID(in: index)

        // If the source now has fewer messages than we have already indexed, it is not the same
        // database — Messages was turned off and on, restored from a backup, or the Mac is new.
        // Carrying the old watermark forward would mean never indexing anything again.
        if since > 0, try highestSourceRowID(in: chat) < since {
            try index.execute("DELETE FROM messages")
            since = 0
        }

        let rows = try read(from: chat, after: since)
        guard !rows.isEmpty else { return 0 }

        // IMMEDIATE takes the write lock up front rather than partway through, so a collision
        // fails here — where it can be retried — instead of halfway through the inserts.
        try index.execute("BEGIN IMMEDIATE")
        var committed = false
        // Without this, one bad row left the transaction open for the life of the connection and
        // every later sync failed with the database locked, which is exactly what happened.
        defer { if !committed { try? index.execute("ROLLBACK") } }

        let insert = try index.prepare("""
            INSERT OR REPLACE INTO messages(rowid, body, counterpart, chat_identifier, date, is_from_me, has_attachment)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        """)

        for row in rows {
            insert.reset()
            insert.bind(row.rowID, at: 1)
            insert.bind(row.text, at: 2)
            insert.bind(row.counterpart, at: 3)
            insert.bind(row.chatIdentifier ?? "", at: 4)
            insert.bind(row.rawDate, at: 5)
            insert.bind(row.isFromMe ? 1 : 0, at: 6)
            insert.bind(row.hasAttachment ? 1 : 0, at: 7)
            try insert.step()
        }
        try index.execute("COMMIT")
        committed = true

        return rows.count
    }

    /// Throw away the index and build it again — for when the shape of what we store changes.
    public func rebuild() throws {
        index = nil
        try? FileManager.default.removeItem(at: location)
        try sync()
    }

    // MARK: - Searching

    /// Newest first, because a conversation is almost always searched to find the most recent
    /// time something was said.
    public func search(_ query: String, limit: Int = 60) throws -> SearchPage<MessageHit> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return .empty }

        let index = try openIndex()
        let statement = try index.prepare("""
            SELECT rowid, body, counterpart, chat_identifier, date, is_from_me, has_attachment
            FROM messages
            WHERE messages MATCH ?1
            ORDER BY date DESC
            LIMIT ?2
        """)
        statement.bind(Self.ftsQuery(for: trimmed), at: 1)
        statement.bind(Int64(limit), at: 2)

        var hits: [MessageHit] = []
        while try statement.step() {
            let chatIdentifier = statement.string(3)
            hits.append(MessageHit(
                rowID: statement.int64(0),
                text: statement.string(1) ?? "",
                date: MessageHit.date(fromAppleTimestamp: statement.int64(4)),
                isFromMe: statement.bool(5),
                counterpart: statement.string(2) ?? "Unknown",
                chatIdentifier: (chatIdentifier?.isEmpty ?? true) ? nil : chatIdentifier,
                hasAttachment: statement.bool(6)
            ))
        }

        // Only worth a second pass when the page filled up.
        var total = hits.count
        if hits.count == limit {
            let counter = try index.prepare("SELECT COUNT(*) FROM messages WHERE messages MATCH ?1")
            counter.bind(Self.ftsQuery(for: trimmed), at: 1)
            total = try counter.step() ? Int(counter.int64(0)) : hits.count
        }
        return SearchPage(items: hits, total: total)
    }

    /// Turn what the user typed into an FTS5 query.
    ///
    /// Every word is quoted so punctuation, apostrophes and phone numbers cannot be read as FTS
    /// operators, and a trailing `*` makes the last word a prefix — which is what makes results
    /// appear while still typing.
    static func ftsQuery(for text: String) -> String {
        let words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }

        guard !words.isEmpty else { return "\"\"" }

        var terms = words.map { "\"\($0)\"" }
        terms[terms.count - 1] += "*"
        return terms.joined(separator: " ")
    }

    // MARK: - Plumbing

    private func openIndex() throws -> SQLiteDatabase {
        if let index { return index }

        let database = try SQLiteDatabase.openOrCreate(location)
        // `content=''` would make this contentless; we keep the columns so a hit can be shown
        // without going back to chat.db, which may no longer be readable.
        try database.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS messages USING fts5(
                body,
                counterpart UNINDEXED,
                chat_identifier UNINDEXED,
                date UNINDEXED,
                is_from_me UNINDEXED,
                has_attachment UNINDEXED,
                tokenize = 'unicode61 remove_diacritics 2'
            )
        """)
        index = database
        return database
    }

    private func openSource() throws -> SQLiteDatabase {
        guard sourceIsReadable else { throw Failure.notAccessible }
        do {
            // Messages keeps chat.db open with a write-ahead log. Opening it immutable is the
            // only way to read it without write access to the log's side files; the cost is that
            // messages sent in the last few seconds may not appear yet.
            return try SQLiteDatabase.openReadOnly(source, immutable: true)
        } catch {
            throw Failure.notAccessible
        }
    }

    private func highestIndexedRowID(in index: SQLiteDatabase) throws -> Int64 {
        let statement = try index.prepare("SELECT COALESCE(MAX(rowid), 0) FROM messages")
        return try statement.step() ? statement.int64(0) : 0
    }

    private func highestSourceRowID(in chat: SQLiteDatabase) throws -> Int64 {
        let statement = try chat.prepare("SELECT COALESCE(MAX(ROWID), 0) FROM message")
        return try statement.step() ? statement.int64(0) : 0
    }

    private struct Row {
        let rowID: Int64
        let text: String
        let counterpart: String
        let chatIdentifier: String?
        let rawDate: Int64
        let isFromMe: Bool
        let hasAttachment: Bool
    }

    private func read(from chat: SQLiteDatabase, after rowID: Int64) throws -> [Row] {
        let statement = try chat.prepare("""
            SELECT m.ROWID,
                   m.text,
                   m.attributedBody,
                   m.date,
                   m.is_from_me,
                   m.cache_has_attachments,
                   h.id,
                   c.display_name,
                   c.chat_identifier
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            LEFT JOIN chat_message_join j ON j.message_id = m.ROWID
            LEFT JOIN chat c ON c.ROWID = j.chat_id
            WHERE m.ROWID > ?1
            -- One row per message. A message that belongs to more than one conversation comes
            -- back once per chat through this join, and inserting the same message twice is a
            -- constraint failure that aborts the whole sync.
            GROUP BY m.ROWID
            ORDER BY m.ROWID ASC
        """)
        statement.bind(rowID, at: 1)

        var rows: [Row] = []
        while try statement.step() {
            // Prefer the plain column; fall back to digging the text out of the styled blob.
            let plain = statement.string(1)
            let text = (plain?.isEmpty == false ? plain : nil)
                ?? statement.blob(2).flatMap(TypedStreamText.extract)

            // Messages with no text at all — a bare photo, a tapback — are skipped. There is
            // nothing in them to find by searching.
            guard let text, !text.isEmpty else { continue }

            let handle = statement.string(6)
            let displayName = statement.string(7)
            let counterpart = [displayName, handle]
                .compactMap { $0 }
                .first { !$0.isEmpty } ?? "Unknown"

            rows.append(Row(
                rowID: statement.int64(0),
                text: text,
                counterpart: counterpart,
                chatIdentifier: statement.string(8),
                rawDate: statement.int64(3),
                isFromMe: statement.bool(4),
                hasAttachment: statement.bool(5)
            ))
        }
        return rows
    }
}
