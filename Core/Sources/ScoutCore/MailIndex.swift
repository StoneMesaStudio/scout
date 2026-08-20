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

    public init(mailDirectory: URL = MailIndex.defaultDirectory()) {
        self.mailDirectory = mailDirectory
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
    public func search(_ query: String, limit: Int = 40) throws -> [MailHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        guard isAccessible else { throw Failure.notAccessible }
        guard let location = locateIndex() else { throw Failure.noIndexFound }

        // Immutable, because Mail keeps the index open with a write-ahead log and read-only access
        // to that would need write permission on its side files. The cost is that a message that
        // arrived in the last moment or two may not be there yet.
        guard let database = try? SQLiteDatabase.openReadOnly(location, immutable: true) else {
            throw Failure.notAccessible
        }

        let pattern = "%\(Self.escapeForLike(trimmed))%"

        // Subject, sender name and sender address, in one pass. Recipients are a second pass
        // because that join multiplies rows and would otherwise slow down every search for the
        // sake of the rarer case.
        let statement = try database.prepare("""
            SELECT m.ROWID, s.subject, a.comment, a.address, m.date_received, m.date_sent,
                   b.url, m.message_id, m.read
            FROM messages m
            LEFT JOIN subjects  s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN mailboxes b ON b.ROWID = m.mailbox
            WHERE m.deleted = 0
              AND (s.subject LIKE ?1 ESCAPE '\\'
                   OR a.comment LIKE ?1 ESCAPE '\\'
                   OR a.address LIKE ?1 ESCAPE '\\')
            ORDER BY m.date_received DESC
            LIMIT ?2
        """)
        statement.bind(pattern, at: 1)
        statement.bind(Int64(limit), at: 2)

        var hits: [MailHit] = []
        while try statement.step() {
            hits.append(Self.hit(from: statement))
        }
        return hits
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

    /// `%` and `_` are wildcards in SQL's LIKE, so someone searching for a literal underscore
    /// gets what they asked for rather than every message.
    static func escapeForLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

/// Keeps the Mail search off the main thread.
public actor MailSearchService {

    public enum State: Sendable, Equatable {
        case ready
        case needsFullDiskAccess
        case failed(String)
    }

    private let index: MailIndex
    private var state: State = .ready

    public init(mailDirectory: URL = MailIndex.defaultDirectory()) {
        index = MailIndex(mailDirectory: mailDirectory)
    }

    public func currentState() -> State { state }

    public func search(_ query: String, limit: Int = 40) -> [MailHit] {
        do {
            let hits = try index.search(query, limit: limit)
            state = .ready
            return hits
        } catch let failure as MailIndex.Failure {
            state = failure == .notAccessible ? .needsFullDiskAccess : .failed(failure.description)
            return []
        } catch {
            state = .failed(error.localizedDescription)
            return []
        }
    }
}
