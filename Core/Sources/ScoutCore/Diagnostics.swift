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
        for table in names where ["messages", "subjects", "addresses", "mailboxes", "message"].contains(table) {
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
