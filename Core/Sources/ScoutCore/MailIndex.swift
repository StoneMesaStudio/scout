import Foundation

/// The Mail lane, read from Mail's own index.
///
/// Spotlight was the obvious route and it returned nothing: the `.emlx` files are all there —
/// twenty thousand of them — but macOS does not index them for other apps to find. Mail keeps its
/// own catalogue at `~/Library/Mail/V*/MailData/Envelope Index`, and that is what Mail's own
/// search reads. Scout reads the same thing, so what it finds is what Mail would find.
///
/// Read-only and never written to. Reaching it needs Full Disk Access.
public final class MailIndex {

    public enum Failure: Error, CustomStringConvertible {
        case notAccessible
        case noIndexFound

        public var description: String {
            switch self {
            case .notAccessible: "Scout needs Full Disk Access to read your mail."
            case .noIndexFound: "Couldn't find Mail's index. Has Mail ever been set up on this Mac?"
            }
        }
    }

    private let mailDirectory: URL
    /// Scout's own index of message bodies, when there is one to consult.
    private let bodyIndexLocation: URL?

    public init(
        mailDirectory: URL = MailIndex.defaultDirectory(),
        bodyIndexLocation: URL? = nil
    ) {
        self.mailDirectory = mailDirectory
        self.bodyIndexLocation = bodyIndexLocation
    }

    public static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Mail", directoryHint: .isDirectory)
    }

    public var isAccessible: Bool {
        StoreAccess.canRead(directory: mailDirectory)
    }

    /// Mail versions its storage — V10 today, V11 tomorrow — so the newest one wins rather than
    /// a hard-coded name that expires with the next macOS.
    public func locateIndex() -> URL? {
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: mailDirectory.path)) ?? []
        let candidates = versions
            .filter { $0.hasPrefix("V") }
            .sorted { versionNumber($0) < versionNumber($1) }
            .reversed()

        for version in candidates {
            let index = mailDirectory.appending(path: "\(version)/MailData/Envelope Index")
            if FileManager.default.fileExists(atPath: index.path) { return index }
        }
        return nil
    }

    private func versionNumber(_ name: String) -> Int {
        Int(name.dropFirst()) ?? 0
    }

    /// Newest first: mail is nearly always searched for the most recent time something was said.
    ///
    /// The total comes back with the page, because "6 of 2,367" and a bare six mean very
    /// different things to someone deciding whether to keep typing.
    public func search(_ query: String, limit: Int = 40) throws -> SearchPage<MailHit> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return .empty }
        guard isAccessible else { throw Failure.notAccessible }
        guard let location = locateIndex() else { throw Failure.noIndexFound }

        // Immutable, because Mail keeps the index open with a write-ahead log and read-only access
        // to that would need write permission on its side files. The cost is that a message that
        // arrived in the last moment or two may not be there yet.
        guard let database = try? SQLiteDatabase.openReadOnly(location, immutable: true) else {
            throw Failure.notAccessible
        }

        let pattern = "%\(Self.escapeForLike(trimmed))%"

        // Attach Scout's body index, if it has been built, so subject, sender and body are one
        // query — which is the only way the count and the ordering can both be right.
        var bodyMatch = ""
        if let bodyIndexLocation, FileManager.default.fileExists(atPath: bodyIndexLocation.path) {
            let escaped = bodyIndexLocation.path.replacingOccurrences(of: "'", with: "''")
            if (try? database.execute("ATTACH DATABASE '\(escaped)' AS bodies")) != nil {
                bodyMatch = """
                    OR trim(g.message_id_header, '<>') IN (
                        SELECT message_id FROM bodies.bodies WHERE bodies MATCH ?3
                    )
                """
            }
        }
        let ftsQuery = Self.ftsQuery(for: trimmed)

        // Subject, sender name and sender address, in one pass. Recipients are a second pass
        // because that join multiplies rows and would otherwise slow down every search for the
        // sake of the rarer case.
        let statement = try database.prepare("""
            SELECT m.ROWID, s.subject, a.comment, a.address, m.date_received, m.date_sent,
                   b.url, g.message_id_header, m.read
            FROM messages m
            LEFT JOIN subjects  s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN mailboxes b ON b.ROWID = m.mailbox
            LEFT JOIN message_global_data g ON g.message_id = m.ROWID
            WHERE m.deleted = 0
              AND (s.subject LIKE ?1 ESCAPE '\\'
                   OR a.comment LIKE ?1 ESCAPE '\\'
                   OR a.address LIKE ?1 ESCAPE '\\'
                   \(bodyMatch))
            ORDER BY \(Self.trashLastClause) ASC, \(Self.sortDateClause) DESC
            LIMIT ?2
        """)
        statement.bind(pattern, at: 1)
        statement.bind(Int64(limit), at: 2)
        if !bodyMatch.isEmpty { statement.bind(ftsQuery, at: 3) }

        var hits: [MailHit] = []
        while try statement.step() {
            hits.append(Self.hit(from: statement))
        }

        // Only worth a second pass when the page filled up; otherwise what came back is all
        // there is.
        let total = hits.count < limit
            ? hits.count
            : try Self.count(in: database, pattern: pattern, bodyMatch: bodyMatch, ftsQuery: ftsQuery)
        return SearchPage(items: hits, total: total)
    }

    /// The same WHERE clause as the page, counted. Written from the same pieces on purpose: a
    /// count that filters differently from the results is worse than no count at all.
    private static func count(
        in database: SQLiteDatabase,
        pattern: String,
        bodyMatch: String,
        ftsQuery: String
    ) throws -> Int {
        let statement = try database.prepare("""
            SELECT COUNT(*)
            FROM messages m
            LEFT JOIN subjects  s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN mailboxes b ON b.ROWID = m.mailbox
            LEFT JOIN message_global_data g ON g.message_id = m.ROWID
            WHERE m.deleted = 0
              AND (s.subject LIKE ?1 ESCAPE '\\'
                   OR a.comment LIKE ?1 ESCAPE '\\'
                   OR a.address LIKE ?1 ESCAPE '\\'
                   \(bodyMatch))
        """)
        statement.bind(pattern, at: 1)
        if !bodyMatch.isEmpty { statement.bind(ftsQuery, at: 3) }
        return try statement.step() ? Int(statement.int64(0)) : 0
    }

    /// Every word quoted so punctuation cannot be read as an FTS operator, with the last word a
    /// prefix so results appear while still typing.
    static func ftsQuery(for text: String) -> String {
        let words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }

        guard !words.isEmpty else { return "\"\"" }
        var terms = words.map { "\"\($0)\"" }
        terms[terms.count - 1] += "*"
        return terms.joined(separator: " ")
    }

    private static func hit(from statement: SQLiteStatement) -> MailHit {
        let name = statement.string(2) ?? ""
        let address = statement.string(3) ?? ""
        let received = statement.int64(4)
        let sent = statement.int64(5)

        return MailHit(
            rowID: statement.int64(0),
            subject: statement.string(1).flatMap { $0.isEmpty ? nil : $0 } ?? "(no subject)",
            sender: name.isEmpty ? (address.isEmpty ? "Unknown sender" : address) : name,
            senderAddress: address.isEmpty ? nil : address,
            date: MailHit.date(fromEnvelopeTimestamp: received > 0 ? received : sent),
            mailbox: MailHit.mailboxName(fromURL: statement.string(6)),
            messageID: statement.string(7),
            isUnread: !statement.bool(8)
        )
    }

    /// Sort by the same date the row displays.
    ///
    /// A message in Sent, or one not fully synced, has no received date at all — so ordering on
    /// `date_received` alone buried today's message below ones from a fortnight ago while showing
    /// today's date beside it.
    static let sortDateClause = "max(coalesce(m.date_received, 0), coalesce(m.date_sent, 0))"

    /// Mail found in the trash or in junk sorts below everything else.
    ///
    /// Not excluded: plenty of people delete a message and still want to find it later. But a
    /// mailbox full of things already thrown away should not be the first answer, which is what
    /// pure date order produced.
    static let trashLastClause = """
        CASE WHEN b.url LIKE '%Deleted%' OR b.url LIKE '%Trash%'
                  OR b.url LIKE '%Junk%' OR b.url LIKE '%Spam%'
             THEN 1 ELSE 0 END
    """

    /// `%` and `_` are wildcards in SQL's LIKE, so someone searching for a literal underscore
    /// gets what they asked for rather than every message.
    static func escapeForLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

/// Keeps the Mail search — and the building of the body index — off the main thread.
public actor MailSearchService {

    public enum State: Sendable, Equatable {
        case ready
        case needsFullDiskAccess
        case failed(String)
    }

    private let mailDirectory: URL
    private let bodies: MailBodyIndex
    private var state: State = .ready
    private var bodySearchEnabled = true

    public init(
        mailDirectory: URL = MailIndex.defaultDirectory(),
        bodyIndexLocation: URL = MailBodyIndex.defaultLocation()
    ) {
        self.mailDirectory = mailDirectory
        bodies = MailBodyIndex(mailDirectory: mailDirectory, location: bodyIndexLocation)
    }

    public func currentState() -> State { state }

    public func setBodySearch(_ enabled: Bool) {
        bodySearchEnabled = enabled
        if !enabled { bodies.remove() }
    }

    /// Index another slice of the archive. Returns what is left to do.
    public func syncBodies(budget: Int = 2_000) -> MailBodyIndex.Progress? {
        guard bodySearchEnabled else { return nil }
        return try? bodies.sync(budget: budget)
    }

    public func bodyProgress() -> MailBodyIndex.Progress? {
        guard bodySearchEnabled else { return nil }
        return try? bodies.progress()
    }

    public func bodyIndexSize() -> Int64 {
        bodies.sizeOnDisk
    }

    public func rebuildBodies() {
        try? bodies.rebuild()
    }

    public func search(_ query: String, limit: Int = 40) -> SearchPage<MailHit> {
        let index = MailIndex(
            mailDirectory: mailDirectory,
            bodyIndexLocation: bodySearchEnabled ? bodies.databaseLocation : nil
        )
        do {
            let page = try index.search(query, limit: limit)
            state = .ready
            return page
        } catch let failure as MailIndex.Failure {
            state = failure == .notAccessible ? .needsFullDiskAccess : .failed(failure.description)
            return .empty
        } catch {
            state = .failed(error.localizedDescription)
            return .empty
        }
    }
}
