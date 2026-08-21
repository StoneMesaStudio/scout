import Foundation

/// A one-shot report on what Mail and Messages actually look like on this Mac.
///
/// Scout can read those stores once Full Disk Access is granted; a terminal generally cannot. So
/// when a lane comes back empty and it is not obvious why, the app asks itself the questions
/// instead — how Mail stores its messages here, whether the system has indexed them, and whether
/// the Messages decoder is recovering text.
///
/// It reports shapes and counts only. No subject, address or message text is ever written out.
public enum Diagnostics {

    /// Counts only — how many rows a given word would match through each candidate join. Enough
    /// to tell a wrong query from an empty mailbox, without a single subject or address leaving
    /// the machine.
    public static func probe(_ term: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        var lines = ["Probe for \"\(term)\"", "===================="]
        let mail = MailIndex(mailDirectory: MailIndex.defaultDirectory(home: home))

        guard let location = mail.locateIndex() else { return "no Envelope Index found" }
        guard let db = try? SQLiteDatabase.openReadOnly(location, immutable: true) else {
            return "could not open the Envelope Index"
        }

        let pattern = "%\(MailIndex.escapeForLike(term))%"

        func count(_ label: String, _ sql: String) {
            guard let statement = try? db.prepare(sql) else {
                lines.append("\(label): could not run — \(db.lastErrorMessage)")
                return
            }
            statement.bind(pattern, at: 1)
            lines.append("\(label): \((try? statement.step()) == true ? String(statement.int64(0)) : "?")")
        }

        count("subjects matching", "SELECT COUNT(*) FROM subjects WHERE subject LIKE ?1")
        count("addresses matching (address)", "SELECT COUNT(*) FROM addresses WHERE address LIKE ?1")
        count("addresses matching (comment/name)", "SELECT COUNT(*) FROM addresses WHERE comment LIKE ?1")
        count("messages via subject join", """
            SELECT COUNT(*) FROM messages m JOIN subjects s ON s.ROWID = m.subject
            WHERE s.subject LIKE ?1
        """)
        count("messages via sender->addresses join", """
            SELECT COUNT(*) FROM messages m JOIN addresses a ON a.ROWID = m.sender
            WHERE a.address LIKE ?1 OR a.comment LIKE ?1
        """)
        count("messages via sender->sender_addresses->addresses", """
            SELECT COUNT(*) FROM messages m
            JOIN sender_addresses sa ON sa.ROWID = m.sender
            JOIN addresses a ON a.ROWID = sa.address
            WHERE a.address LIKE ?1 OR a.comment LIKE ?1
        """)
        count("messages via recipients", """
            SELECT COUNT(*) FROM messages m
            JOIN recipients r ON r.message = m.ROWID
            JOIN addresses a ON a.ROWID = r.address
            WHERE a.address LIKE ?1 OR a.comment LIKE ?1
        """)

        count("messages total", "SELECT COUNT(*) FROM messages WHERE ?1 IS NOT NULL")
        count("messages with deleted = 0", "SELECT COUNT(*) FROM messages WHERE deleted = 0 AND ?1 IS NOT NULL")
        count("messages with deleted IS NULL", "SELECT COUNT(*) FROM messages WHERE deleted IS NULL AND ?1 IS NOT NULL")
        count("the exact query Scout runs", """
            SELECT COUNT(*)
            FROM messages m
            LEFT JOIN subjects  s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN mailboxes b ON b.ROWID = m.mailbox
            WHERE m.deleted = 0
              AND (s.subject LIKE ?1 ESCAPE '\\'
                   OR a.comment LIKE ?1 ESCAPE '\\'
                   OR a.address LIKE ?1 ESCAPE '\\')
        """)
        count("same query without the deleted filter", """
            SELECT COUNT(*)
            FROM messages m
            LEFT JOIN subjects  s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            WHERE (s.subject LIKE ?1 OR a.comment LIKE ?1 OR a.address LIKE ?1)
        """)

        // Mail's own search finds far more than subject-and-sender, so something in here must
        // hold the body text.
        count("searchable_messages.message matching", "SELECT COUNT(*) FROM searchable_messages WHERE message LIKE ?1")
        count("summaries matching", "SELECT COUNT(*) FROM summaries WHERE summary LIKE ?1")
        count("attachments matching", "SELECT COUNT(*) FROM searchable_attachments WHERE name LIKE ?1")

        if let sample = try? db.prepare("SELECT typeof(message), length(message) FROM searchable_messages LIMIT 1"),
           (try? sample.step()) == true {
            lines.append("searchable_messages.message type: \(sample.string(0) ?? "?"), first length: \(sample.int64(1))")
        }

        // The real code path, not just the SQL: this is what the Mail lane actually calls.
        if let page = try? mail.search(term, limit: 40) {
            let hits = page.items
            lines.append("MailIndex.search returned: \(hits.count) of \(page.total)")
            lines.append("  with a subject: \(hits.filter { $0.subject != "(no subject)" }.count)")
            lines.append("  with a sender name: \(hits.filter { $0.senderAddress != nil }.count)")
            lines.append("  with a date: \(hits.filter { $0.date != nil }.count)")
            lines.append("  with a mailbox: \(hits.filter { $0.mailbox != nil }.count)")
            lines.append("  openable in Mail: \(hits.filter { $0.openURL != nil }.count)")
        } else {
            lines.append("MailIndex.search threw")
        }

        // The Messages lane, exercised the same way.
        let messages = MessageIndex()
        do {
            let added = try messages.sync()
            let page = try messages.search(term, limit: 40)
            lines.append("MessageIndex.sync added: \(added)")
            lines.append("MessageIndex.search returned: \(page.items.count) of \(page.total)")
        } catch {
            lines.append("MessageIndex failed: \(error)")
        }

        for table in ["sender_addresses", "senders", "message_global_data", "summaries"] {
            guard let info = try? db.prepare("PRAGMA table_info(\(table))") else { continue }
            var columns: [String] = []
            while (try? info.step()) == true {
                if let column = info.string(1) { columns.append(column) }
            }
            if !columns.isEmpty { lines.append("\(table): \(columns.joined(separator: ", "))") }
        }

        return lines.joined(separator: "\n")
    }

    public static func report(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        var lines: [String] = []
        lines.append("Scout diagnostic")
        lines.append("================")
        lines.append("")
        lines.append(contentsOf: mailReport(home: home))
        lines.append("")
        lines.append(contentsOf: messagesReport(home: home))
        lines.append("")
        lines.append("No message text, subjects or addresses are included in this file.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Mail

    private static func mailReport(home: URL) -> [String] {
        var lines = ["MAIL", "----"]
        let fm = FileManager.default
        let root = home.appending(path: "Library/Mail")

        guard StoreAccess.canRead(directory: root) else {
            lines.append("~/Library/Mail is not readable — Full Disk Access has not been granted.")
            return lines
        }
        lines.append("~/Library/Mail is readable.")

        let versions = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        lines.append("Top level: \(versions.joined(separator: ", "))")

        // How Mail stores messages here: one .emlx per message, or something else.
        var emlxCount = 0
        var mboxCount = 0
        var otherExtensions: Set<String> = []

        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker {
                switch url.pathExtension {
                case "emlx": emlxCount += 1
                case "mbox": mboxCount += 1
                case "": break
                default: otherExtensions.insert(url.pathExtension)
                }
                // Enough to characterise the store without walking a huge mailbox.
                if emlxCount > 20_000 { break }
            }
        }
        lines.append(".emlx files found: \(emlxCount)\(emlxCount > 20_000 ? "+ (stopped counting)" : "")")
        lines.append(".mbox folders found: \(mboxCount)")
        lines.append("Other extensions seen: \(otherExtensions.sorted().prefix(20).joined(separator: ", "))")

        // Mail's own index. If this exists, Scout can read it directly instead of relying on
        // Spotlight having indexed the message files.
        for version in versions where version.hasPrefix("V") {
            let index = root.appending(path: "\(version)/MailData/Envelope Index")
            guard fm.fileExists(atPath: index.path) else { continue }
            lines.append("")
            lines.append("Envelope Index at \(version)/MailData/Envelope Index")
            lines.append(contentsOf: schema(of: index))
        }

        return lines
    }

    /// Table names and their columns, so a query can be written against the real thing rather
    /// than a guess at it.
    private static func schema(of database: URL) -> [String] {
        guard let db = try? SQLiteDatabase.openReadOnly(database, immutable: true) else {
            return ["  could not open it read-only"]
        }

        var lines: [String] = []
        guard let tables = try? db.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name") else {
            return ["  could not read its table list"]
        }

        var names: [String] = []
        while (try? tables.step()) == true {
            if let name = tables.string(0) { names.append(name) }
        }
        lines.append("  tables: \(names.joined(separator: ", "))")

        // The handful that would carry a searchable message.
        let interesting = [
            "messages", "subjects", "addresses", "mailboxes", "message",
            "searchable_messages", "senders", "recipients", "summaries",
        ]
        for table in names where interesting.contains(table) {
            guard let info = try? db.prepare("PRAGMA table_info(\(table))") else { continue }
            var columns: [String] = []
            while (try? info.step()) == true {
                if let column = info.string(1) { columns.append(column) }
            }
            lines.append("  \(table): \(columns.joined(separator: ", "))")

            if let count = try? db.prepare("SELECT COUNT(*) FROM \(table)"), (try? count.step()) == true {
                lines.append("  \(table) rows: \(count.int64(0))")
            }
        }
        return lines
    }

    // MARK: - Messages

    private static func messagesReport(home: URL) -> [String] {
        var lines = ["MESSAGES", "--------"]
        let source = MessageIndex.defaultSource(home: home)

        guard StoreAccess.canRead(file: source) else {
            lines.append("chat.db is not readable — Full Disk Access has not been granted.")
            return lines
        }
        lines.append("chat.db is readable.")

        guard let db = try? SQLiteDatabase.openReadOnly(source, immutable: true) else {
            lines.append("chat.db could not be opened read-only.")
            return lines
        }

        if let total = try? db.prepare("SELECT COUNT(*) FROM message"), (try? total.step()) == true {
            lines.append("messages: \(total.int64(0))")
        }
        if let plain = try? db.prepare("SELECT COUNT(*) FROM message WHERE text IS NOT NULL AND text != ''"),
           (try? plain.step()) == true {
            lines.append("with plain text: \(plain.int64(0))")
        }

        // The decoder's hit rate on real blobs is the number worth knowing: if it is near zero,
        // the Messages lane is missing most of the history.
        guard let sample = try? db.prepare("""
            SELECT attributedBody FROM message
            WHERE (text IS NULL OR text = '') AND attributedBody IS NOT NULL
            ORDER BY ROWID DESC LIMIT 300
        """) else {
            lines.append("could not sample styled messages")
            return lines
        }

        var sampled = 0
        var recovered = 0
        while (try? sample.step()) == true {
            sampled += 1
            if let blob = sample.blob(0), TypedStreamText.extract(from: blob) != nil {
                recovered += 1
            }
        }
        lines.append("styled-only messages sampled: \(sampled)")
        lines.append("text recovered from them: \(recovered)")

        return lines
    }
}
