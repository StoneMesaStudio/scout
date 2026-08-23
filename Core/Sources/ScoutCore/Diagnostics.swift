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

    /// What Notes and Reminders actually look like on this Mac.
    ///
    /// Shapes and counts only — never a note title, a reminder, or a word out of either. The
    /// questions worth asking are whether Apple's column names are where Scout expects them,
    /// whether the compressed bodies decode, and whether the identifiers are the shape the deep
    /// links need.
    public static func probeNotesAndReminders(
        _ term: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> String {
        var lines = ["Notes & Reminders probe for \"\(term)\"", "================================", ""]

        // ---- Notes ----
        lines.append("NOTES")
        let source = NotesIndex.defaultSource(home: home)
        lines.append("store readable: \(StoreAccess.canRead(file: source) ? "yes" : "no — needs Full Disk Access")")

        if let db = try? SQLiteDatabase.openReadOnly(source, immutable: true) {
            let columns = db.columns(of: "ZICCLOUDSYNCINGOBJECT")
            lines.append("ZICCLOUDSYNCINGOBJECT columns: \(columns.count)")
            for name in ["ZTITLE1", "ZTITLE2", "ZIDENTIFIER", "ZMODIFICATIONDATE1", "ZFOLDER",
                         "ZNOTEDATA", "ZISPASSWORDPROTECTED", "ZMARKEDFORDELETION"] {
                lines.append("  \(name): \(columns.contains(name) ? "present" : "MISSING")")
            }
            let accounts = columns.filter { $0.hasPrefix("ZACCOUNT") }.sorted()
            lines.append("  account columns: \(accounts.joined(separator: ", "))")

            func count(_ label: String, _ sql: String) {
                guard let statement = try? db.prepare(sql) else {
                    lines.append("\(label): could not run — \(db.lastErrorMessage)")
                    return
                }
                lines.append("\(label): \((try? statement.step()) == true ? String(statement.int64(0)) : "?")")
            }
            count("note rows", "SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZNOTEDATA IS NOT NULL")
            count("marked for deletion", "SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZNOTEDATA IS NOT NULL AND ZMARKEDFORDELETION = 1")
            count("password protected", "SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZNOTEDATA IS NOT NULL AND ZISPASSWORDPROTECTED = 1")
            count("ZICNOTEDATA rows", "SELECT COUNT(*) FROM ZICNOTEDATA")
            count("body blobs stored", "SELECT COUNT(*) FROM ZICNOTEDATA WHERE ZDATA IS NOT NULL")

            // Which way round the note-to-body link actually goes. Mail taught this lesson once
            // already: a join on the wrong column does not fail, it silently returns nothing.
            count("joined on d.ZNOTE = n.Z_PK (what Scout does)", """
                SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT n
                JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK
                WHERE n.ZNOTEDATA IS NOT NULL AND d.ZDATA IS NOT NULL
            """)
            count("joined on d.Z_PK = n.ZNOTEDATA (the other way)", """
                SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT n
                JOIN ZICNOTEDATA d ON d.Z_PK = n.ZNOTEDATA
                WHERE d.ZDATA IS NOT NULL
            """)
            count("notes whose body row exists but is empty", """
                SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT n
                JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK
                WHERE n.ZNOTEDATA IS NOT NULL AND d.ZDATA IS NULL
            """)

            // Husks: rows Notes leaves behind with no title and no body. They can never match
            // anything, and counting them makes the lane look bigger than it is.
            count("husks (no title, no body)", """
                SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT n
                LEFT JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK
                WHERE n.ZNOTEDATA IS NOT NULL AND d.ZDATA IS NULL
                  AND (n.ZTITLE1 IS NULL OR n.ZTITLE1 = '')
            """)

            // The one that matters: does the gzip-and-protobuf decode actually work here, or is
            // the lane about to index a few thousand empty bodies?
            if let sample = try? db.prepare("SELECT ZDATA FROM ZICNOTEDATA WHERE ZDATA IS NOT NULL LIMIT 200") {
                var tried = 0, gunzipped = 0, decoded = 0, characters = 0
                while (try? sample.step()) == true {
                    guard let blob = sample.blob(0) else { continue }
                    tried += 1
                    guard let inflated = Gzip.inflate(blob) else { continue }
                    gunzipped += 1
                    guard let text = NoteProtobuf.text(in: inflated) else { continue }
                    decoded += 1
                    characters += text.count
                }
                lines.append("sampled bodies: \(tried), un-gzipped: \(gunzipped), text recovered: \(decoded)")
                lines.append("  average recovered length: \(decoded > 0 ? characters / decoded : 0) characters")
            }

            // Identifier shape, because the deep link is built out of it.
            if let sample = try? db.prepare("SELECT ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT WHERE ZNOTEDATA IS NOT NULL AND ZIDENTIFIER IS NOT NULL LIMIT 5") {
                var shapes: [String] = []
                while (try? sample.step()) == true {
                    let value = sample.string(0) ?? ""
                    shapes.append("len \(value.count), uuid: \(UUID(uuidString: value) != nil ? "yes" : "no")")
                }
                lines.append("identifier shape: \(shapes.joined(separator: "; "))")
            }
        } else {
            lines.append("could not open the Notes database")
        }

        let notes = NotesIndex(source: source)
        do {
            let changed = try notes.sync()
            let page = try notes.search(term, limit: 40)
            lines.append("NotesIndex.sync changed: \(changed)")
            lines.append("NotesIndex holds: \(try notes.indexedCount()) notes")
            lines.append("NotesIndex.search returned: \(page.items.count) of \(page.total)")
            lines.append("  openable in Notes: \(page.items.filter { $0.openURL != nil }.count)")
            lines.append("  locked: \(page.items.filter(\.isLocked).count)")
            lines.append("  with a folder: \(page.items.filter { $0.folder != nil }.count)")
            lines.append("  with a date: \(page.items.filter { $0.modified != nil }.count)")
            // A preview, not proof of where the match was: FTS5 hands back the head of the body
            // when the match was in the title.
            lines.append("  with a body preview: \(page.items.filter { $0.snippet != nil }.count)")

            // The number that says whether the lane is really searching notes or only naming
            // them: how many went in with a title and nothing else.
            if let db = try? SQLiteDatabase.openReadOnly(NotesIndex.defaultIndexLocation(home: home)),
               let counter = try? db.prepare("SELECT COUNT(*) FROM notes WHERE body = ''"),
               (try? counter.step()) == true {
                lines.append("indexed with no searchable text at all: \(counter.int64(0))")
            }
        } catch {
            lines.append("NotesIndex failed: \(error)")
        }

        // ---- Reminders ----
        lines.append("")
        lines.append("REMINDERS")
        let searcher = ReminderSearcher()
        lines.append("access: \(searcher.access)")

        let records = await searcher.loadAll()
        lines.append("reminders read: \(records.count)")
        lines.append("  with a title: \(records.filter { !$0.title.isEmpty }.count)")
        lines.append("  with a list: \(records.filter { !$0.list.isEmpty }.count)")
        lines.append("  with notes on them: \(records.filter { !$0.body.isEmpty }.count)")
        lines.append("  completed: \(records.filter(\.hit.isCompleted).count)")
        lines.append("  with a due date: \(records.filter { $0.hit.due != nil }.count)")
        lines.append("  identifiers that are UUIDs (so the deep link works): \(records.filter { $0.hit.openURL != nil }.count)")

        let page = ReminderIndex(records: records).search(term, limit: 40)
        lines.append("ReminderIndex.search returned: \(page.items.count) of \(page.total)")

        return lines.joined(separator: "\n")
    }

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

        // Which column message_global_data actually keys on.
        for (label, sql) in [
            ("g.message_id = m.ROWID", "SELECT COUNT(*) FROM messages m JOIN message_global_data g ON g.message_id = m.ROWID WHERE g.message_id_header IS NOT NULL AND ?1 IS NOT NULL"),
            ("g.message_id = m.message_id", "SELECT COUNT(*) FROM messages m JOIN message_global_data g ON g.message_id = m.message_id WHERE g.message_id_header IS NOT NULL AND ?1 IS NOT NULL"),
            ("g.ROWID = m.ROWID", "SELECT COUNT(*) FROM messages m JOIN message_global_data g ON g.ROWID = m.ROWID WHERE g.message_id_header IS NOT NULL AND ?1 IS NOT NULL"),
        ] {
            count("join on \(label)", sql)
        }

        if let sample = try? db.prepare("SELECT typeof(message_id), length(message_id) FROM message_global_data LIMIT 1"),
           (try? sample.step()) == true {
            lines.append("message_global_data.message_id type: \(sample.string(0) ?? "?"), length \(sample.int64(1))")
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

        // Index a slice of the archive and search it, so the body join is exercised on real mail
        // rather than only on a fixture. Counts only.
        let bodies = MailBodyIndex(mailDirectory: MailIndex.defaultDirectory(home: home))
        if let progress = try? bodies.sync(budget: 4_000) {
            lines.append("")
            lines.append("BODY INDEX")
            lines.append("indexed so far: \(progress.indexed), remaining: \(progress.remaining)")

            let withBodies = MailIndex(
                mailDirectory: MailIndex.defaultDirectory(home: home),
                bodyIndexLocation: bodies.databaseLocation
            )
            if let page = try? withBodies.search(term, limit: 10) {
                lines.append("mail search including bodies: \(page.items.count) of \(page.total)")
            }

            // How many indexed bodies contain the word at all, and how many of those tie back to
            // a message — the two numbers that tell a join failure from a not-yet-indexed word.
            if let bodyDB = try? SQLiteDatabase.openReadOnly(bodies.databaseLocation) {
                if let counter = try? bodyDB.prepare("SELECT COUNT(*) FROM bodies WHERE bodies MATCH ?1") {
                    counter.bind(MailIndex.ftsQuery(for: term), at: 1)
                    lines.append("indexed bodies containing it: \((try? counter.step()) == true ? String(counter.int64(0)) : "?")")
                }
                if let counter = try? bodyDB.prepare("SELECT COUNT(*) FROM bodies") {
                    lines.append("bodies stored: \((try? counter.step()) == true ? String(counter.int64(0)) : "?")")
                }
            }
        }

        lines.append(contentsOf: emlxShape(home: home))
        lines.append(contentsOf: contactShape())

        // How Mail writes a Message-ID, so the body index can be keyed to match.
        if let sample = try? db.prepare("SELECT message_id FROM messages WHERE message_id IS NOT NULL LIMIT 3") {
            var shapes: [String] = []
            while (try? sample.step()) == true {
                let value = sample.string(0) ?? ""
                shapes.append("len \(value.count), angle brackets: \(value.hasPrefix("<") ? "yes" : "no")")
            }
            lines.append("message_id shape: \(shapes.joined(separator: "; "))")
        }

        if let sample = try? db.prepare("""
            SELECT message_id_header FROM message_global_data
            WHERE message_id_header IS NOT NULL AND message_id_header != '' LIMIT 3
        """) {
            var shapes: [String] = []
            while (try? sample.step()) == true {
                let value = sample.string(0) ?? ""
                shapes.append("len \(value.count), brackets: \(value.hasPrefix("<") ? "yes" : "no"), has @: \(value.contains("@") ? "yes" : "no")")
            }
            lines.append("message_id_header shape: \(shapes.joined(separator: "; "))")
        }

        if let counter = try? db.prepare("SELECT COUNT(*) FROM message_global_data WHERE message_id_header IS NOT NULL AND message_id_header != ''"),
           (try? counter.step()) == true {
            lines.append("messages with an RFC Message-ID recorded: \(counter.int64(0))")
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

    /// What a message file looks like on disk, and whether it can be tied back to the index.
    /// Counts and shapes only — no header values, no body text.
    private static func emlxShape(home: URL) -> [String] {
        var lines = ["", "MESSAGE FILES"]
        let fm = FileManager.default
        let root = MailIndex.defaultDirectory(home: home)

        var sampled: [URL] = []
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in walker where url.pathExtension == "emlx" {
                sampled.append(url)
                if sampled.count >= 40 { break }
            }
        }
        lines.append("sampled: \(sampled.count)")
        guard !sampled.isEmpty else { return lines }

        var startsWithByteCount = 0
        var hasMessageID = 0
        var numericFilenames = 0
        var totalBytes = 0

        for url in sampled {
            numericFilenames += Int(url.deletingPathExtension().lastPathComponent) != nil ? 1 : 0
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            totalBytes += data.count

            let head = String(decoding: data.prefix(8_192), as: UTF8.self)
            if let firstLine = head.split(separator: "\n", maxSplits: 1).first,
               Int(firstLine.trimmingCharacters(in: .whitespaces)) != nil {
                startsWithByteCount += 1
            }
            if head.range(of: "\nMessage-ID:", options: [.caseInsensitive]) != nil
                || head.hasPrefix("Message-ID:") {
                hasMessageID += 1
            }
        }

        lines.append("filenames that are a number: \(numericFilenames)")
        lines.append("files starting with a byte count: \(startsWithByteCount)")
        lines.append("files with a Message-ID header: \(hasMessageID)")
        lines.append("average size: \(sampled.isEmpty ? 0 : totalBytes / sampled.count) bytes")
        return lines
    }

    /// Whether Contacts hands over the note field at all. Counts only — no note text.
    private static func contactShape() -> [String] {
        let searcher = ContactSearcher()
        guard searcher.access == .allowed else { return ["", "CONTACT CARDS", "not allowed to read contacts"] }

        let records = searcher.loadAll()
        let withNotes = records.filter { $0.hasNote }.count
        return [
            "",
            "CONTACT CARDS",
            "cards: \(records.count)",
            "cards whose note came back non-empty: \(withNotes)",
        ]
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
