import Foundation

/// Scout's own full-text index of Apple Notes.
///
/// Notes has no read API. What it has is a Core Data database in a group container, and a note
/// body that is a gzipped protobuf rather than text — which is why nothing outside Notes.app can
/// search notes today, Spotlight included, and why this lane has to build an index of its own.
///
/// Two traps, both of which cost a rebuild to find:
///
/// - **Notes get edited; messages do not.** The Messages index rides a high-water mark on the row
///   id and never looks back. Doing that here would index a note once and then never notice it
///   changed. So this compares modification dates for every note on each sync — cheap, because
///   reading the dates does not touch the compressed bodies — and reads bodies only for the notes
///   that actually moved. Notes deleted since last time are removed from the index rather than
///   left behind as results that open nothing.
/// - **Apple renames columns between releases.** The database is asked what columns it has and
///   the first name that exists is used, so a rename costs a missing subtitle instead of an empty
///   lane.
///
/// Reading the group container needs Full Disk Access, the same as Mail and Messages.
public final class NotesIndex {

    public enum Failure: Error, CustomStringConvertible {
        case notAccessible
        case unexpectedDatabase

        public var description: String {
            switch self {
            case .notAccessible:
                "Scout needs Full Disk Access to read your notes."
            case .unexpectedDatabase:
                "The Notes database is not in the shape Scout expects."
            }
        }
    }

    /// Where macOS keeps Apple Notes.
    public static func defaultSource(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    }

    /// Where Scout keeps its own index.
    public static func defaultIndexLocation(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appending(path: "Library/Application Support/Scout/notes.sqlite")
    }

    /// A note longer than this is indexed up to here. Nothing in Notes comes close in practice;
    /// the cap exists so one pathological note cannot take the index with it.
    static let maximumBodyLength = 200_000

    private let source: URL
    private let location: URL
    private var index: SQLiteDatabase?

    public init(source: URL = NotesIndex.defaultSource(), location: URL = NotesIndex.defaultIndexLocation()) {
        self.source = source
        self.location = location
    }

    /// True when the Notes database can be opened at all — the plain-language version of "has
    /// Full Disk Access been granted yet".
    public var sourceIsReadable: Bool {
        StoreAccess.canRead(file: source)
    }

    // MARK: - Building

    /// Bring the index up to date, and report how many notes were added, changed or removed.
    @discardableResult
    public func sync() throws -> Int {
        let index = try openIndex()
        let notes = try openSource()
        let layout = try Layout(reading: notes)

        let live = try liveNotes(in: notes, layout: layout)
        let known = try indexedNotes(in: index)

        let changed = live.filter { pk, modified in
            guard let existing = known[pk] else { return true }
            // Dates are Core Data doubles; a note saved twice in the same second is a miss worth
            // taking over re-reading every body on every sync.
            return abs(existing - modified) > 0.5
        }
        let removed = known.keys.filter { live[$0] == nil }

        guard !changed.isEmpty || !removed.isEmpty else { return 0 }

        try index.execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? index.execute("ROLLBACK") } }

        if !removed.isEmpty {
            let delete = try index.prepare("DELETE FROM notes WHERE rowid = ?1")
            for pk in removed {
                delete.reset()
                delete.bind(pk, at: 1)
                try delete.step()
            }
        }

        if !changed.isEmpty {
            let insert = try index.prepare("""
                INSERT OR REPLACE INTO notes(rowid, title, body, identifier, folder, account, modified, is_locked)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            """)
            // In batches, because SQLite has a hard limit on how many values one IN list can hold
            // and a first sync on a big account goes well past it.
            for batch in Array(changed.keys).chunked(into: 400) {
                for row in try read(from: notes, layout: layout, pks: batch) {
                    insert.reset()
                    insert.bind(row.rowID, at: 1)
                    insert.bind(row.title, at: 2)
                    insert.bind(row.body, at: 3)
                    insert.bind(row.identifier ?? "", at: 4)
                    insert.bind(row.folder ?? "", at: 5)
                    insert.bind(row.account ?? "", at: 6)
                    insert.bindDouble(row.modified, at: 7)
                    insert.bind(row.isLocked ? Int64(1) : Int64(0), at: 8)
                    try insert.step()
                }
            }
        }

        try index.execute("COMMIT")
        committed = true
        return changed.count + removed.count
    }

    /// Throw the index away and build it again — for when the shape of what we store changes.
    public func rebuild() throws {
        index = nil
        try? FileManager.default.removeItem(at: location)
        try sync()
    }

    /// How many notes are in the index right now.
    public func indexedCount() throws -> Int {
        let statement = try openIndex().prepare("SELECT COUNT(*) FROM notes")
        return try statement.step() ? Int(statement.int64(0)) : 0
    }

    // MARK: - Searching

    /// Best match first, with a title match worth several body matches — someone searching
    /// "insurance" wants the note called Insurance ahead of the twelve that mention it.
    public func search(_ query: String, limit: Int = 60) throws -> SearchPage<NoteHit> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return .empty }

        let index = try openIndex()
        let match = MessageIndex.ftsQuery(for: trimmed)

        let statement = try index.prepare("""
            SELECT rowid, title, identifier, folder, account, modified, is_locked,
                   snippet(notes, 1, '', '', '…', 10)
            FROM notes
            WHERE notes MATCH ?1
            ORDER BY bm25(notes, 8.0, 1.0)
            LIMIT ?2
        """)
        statement.bind(match, at: 1)
        statement.bind(Int64(limit), at: 2)

        var hits: [NoteHit] = []
        while try statement.step() {
            let folder = statement.string(3)
            let account = statement.string(4)
            let identifier = statement.string(2)
            let snippet = statement.string(7)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = statement.string(1) ?? ""

            hits.append(NoteHit(
                rowID: statement.int64(0),
                identifier: (identifier?.isEmpty ?? true) ? nil : identifier,
                title: title.isEmpty ? "Untitled note" : title,
                folder: (folder?.isEmpty ?? true) ? nil : folder,
                account: (account?.isEmpty ?? true) ? nil : account,
                modified: NoteHit.date(fromCoreData: statement.double(5)),
                snippet: (snippet?.isEmpty ?? true) ? nil : snippet,
                isLocked: statement.bool(6)
            ))
        }

        var total = hits.count
        if hits.count == limit {
            let counter = try index.prepare("SELECT COUNT(*) FROM notes WHERE notes MATCH ?1")
            counter.bind(match, at: 1)
            total = try counter.step() ? Int(counter.int64(0)) : hits.count
        }
        return SearchPage(items: hits, total: total)
    }

    // MARK: - Reading Notes' own database

    /// Which of Apple's column names this copy of Notes actually uses.
    struct Layout {
        let modified: String
        let title: String
        let identifier: String?
        let folder: String?
        let locked: String?
        let deleted: String?
        let account: String?
        /// The column on a *folder* row that holds its name, which is not the one notes use.
        let folderTitle: String?

        static let object = "ZICCLOUDSYNCINGOBJECT"
        static let data = "ZICNOTEDATA"

        init(reading database: SQLiteDatabase) throws {
            guard database.hasTable(Self.object), database.hasTable(Self.data) else {
                throw Failure.unexpectedDatabase
            }
            let columns = database.columns(of: Self.object)

            func first(_ candidates: [String]) -> String? {
                candidates.first { columns.contains($0) }
            }

            guard let modified = first(["ZMODIFICATIONDATE1", "ZMODIFICATIONDATE", "ZMODIFICATIONDATE2"]),
                  let title = first(["ZTITLE1", "ZTITLE", "ZTITLE2"]),
                  columns.contains("ZNOTEDATA")
            else {
                throw Failure.unexpectedDatabase
            }

            self.modified = modified
            self.title = title
            identifier = first(["ZIDENTIFIER"])
            folder = first(["ZFOLDER"])
            locked = first(["ZISPASSWORDPROTECTED"])
            deleted = first(["ZMARKEDFORDELETION"])
            // Notes has carried ZACCOUNT1 … ZACCOUNT8 over the years; the highest-numbered one
            // present is the current link. Matched on digits only — the table also holds
            // ZACCOUNTDATA and ZACCOUNTNAMEFORACCOUNTLISTSORTING, and a prefix match happily
            // picked the sort string and then joined a note to whatever row id it collided with.
            account = columns
                .filter { name in
                    name.hasPrefix("ZACCOUNT")
                        && name.dropFirst("ZACCOUNT".count).allSatisfy(\.isNumber)
                }
                .sorted { ($0.count, $0) > ($1.count, $1) }
                .first
            folderTitle = first(["ZTITLE2", "ZNAME", "ZTITLE1"])
        }

        /// A subselect returning the name of whatever row `column` points at, or an empty
        /// string literal when this copy of Notes has no such column.
        func name(of column: String?, alias: String) -> String {
            guard let column, let folderTitle else { return "''" }
            return "(SELECT COALESCE(\(alias).\(folderTitle), '') FROM \(Self.object) \(alias) WHERE \(alias).Z_PK = n.\(column))"
        }

        /// Notes deleted but not yet purged still sit in the table. They open nothing, so they
        /// have no business in a search.
        var notDeleted: String {
            guard let deleted else { return "1 = 1" }
            return "(n.\(deleted) IS NULL OR n.\(deleted) = 0)"
        }
    }

    /// Every live note's row id and modification date. No bodies — this runs on every sync and
    /// decompressing thousands of blobs to find the handful that changed would defeat the point.
    ///
    /// A note with neither a title nor a stored body is skipped. Notes leaves a great many of
    /// these behind — 193 of the 420 rows on John's Mac, none with a title, none touched in a
    /// year. They can never match anything, and counting them would have had Settings claim 420
    /// notes indexed when 227 is the true number.
    private func liveNotes(in database: SQLiteDatabase, layout: Layout) throws -> [Int64: Double] {
        let statement = try database.prepare("""
            SELECT n.Z_PK, n.\(layout.modified)
            FROM \(Layout.object) n
            LEFT JOIN \(Layout.data) d ON d.ZNOTE = n.Z_PK
            WHERE n.ZNOTEDATA IS NOT NULL AND \(layout.notDeleted)
              AND ((n.\(layout.title) IS NOT NULL AND n.\(layout.title) != '') OR d.ZDATA IS NOT NULL)
        """)

        var result: [Int64: Double] = [:]
        while try statement.step() {
            result[statement.int64(0)] = statement.double(1)
        }
        return result
    }

    private func indexedNotes(in index: SQLiteDatabase) throws -> [Int64: Double] {
        let statement = try index.prepare("SELECT rowid, modified FROM notes")
        var result: [Int64: Double] = [:]
        while try statement.step() {
            result[statement.int64(0)] = statement.double(1)
        }
        return result
    }

    struct Row {
        let rowID: Int64
        let identifier: String?
        let title: String
        let body: String
        let folder: String?
        let account: String?
        let modified: Double
        let isLocked: Bool
    }

    /// The notes themselves, bodies and all.
    private func read(from database: SQLiteDatabase, layout: Layout, pks: [Int64]) throws -> [Row] {
        guard !pks.isEmpty else { return [] }
        let placeholders = pks.indices.map { "?\($0 + 1)" }.joined(separator: ", ")

        // A folder's name lives in a different column from a note's title, on the same table.
        // Looked up as subselects rather than joins so a missing link yields an empty string
        // instead of dropping the note out of the result altogether.
        let folderName = layout.name(of: layout.folder, alias: "f")
        let accountName = layout.name(of: layout.account, alias: "a")

        let statement = try database.prepare("""
            SELECT n.Z_PK,
                   n.\(layout.title),
                   n.\(layout.modified),
                   \(layout.identifier.map { "n.\($0)" } ?? "''"),
                   \(layout.locked.map { "n.\($0)" } ?? "0"),
                   \(folderName),
                   \(accountName),
                   d.ZDATA
            FROM \(Layout.object) n
            LEFT JOIN \(Layout.data) d ON d.ZNOTE = n.Z_PK
            WHERE n.Z_PK IN (\(placeholders))
        """)
        for (offset, pk) in pks.enumerated() {
            statement.bind(pk, at: Int32(offset + 1))
        }

        var rows: [Row] = []
        while try statement.step() {
            let title = statement.string(1) ?? ""
            let identifier = statement.string(3)
            let folder = statement.string(5)
            let account = statement.string(6)
            // A locked note's body is encrypted rather than compressed, so it does not decode and
            // its title is all Scout can honestly offer. `isLocked` is read from Notes' own column
            // and never inferred from a failed decode — calling a note locked because we could not
            // read it would be the same lie as reporting an unsearched mailbox as empty.
            let body = statement.blob(7).flatMap(Self.body(from:)) ?? ""

            rows.append(Row(
                rowID: statement.int64(0),
                identifier: (identifier?.isEmpty ?? true) ? nil : identifier,
                title: title,
                body: Self.strippingTitle(title, from: body),
                folder: (folder?.isEmpty ?? true) ? nil : folder,
                account: (account?.isEmpty ?? true) ? nil : account,
                modified: statement.double(2),
                isLocked: statement.bool(4)
            ))
        }
        return rows
    }

    /// Blob to plain text: ungzip, walk the protobuf, then flatten.
    ///
    /// Whitespace is collapsed on the way in. The full text is never shown — only a snippet
    /// around the match — and a snippet cut out of a note full of newlines and attachment
    /// placeholders reads like a ransom note otherwise.
    static func body(from blob: Data) -> String? {
        guard let inflated = Gzip.inflate(blob), let text = NoteProtobuf.text(in: inflated) else {
            return nil
        }
        // U+FFFC stands in for every attachment, table and drawing in the note.
        let cleaned = text
            .replacingOccurrences(of: "\u{FFFC}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return cleaned.count > maximumBodyLength ? String(cleaned.prefix(maximumBodyLength)) : cleaned
    }

    /// Notes keeps the title as the first line of the body as well. Dropping the repeat keeps
    /// snippets showing what the note says rather than what its heading already said.
    static func strippingTitle(_ title: String, from body: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, body.hasPrefix(title) else { return body }
        return String(body.dropFirst(title.count)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Plumbing

    private func openIndex() throws -> SQLiteDatabase {
        if let index { return index }

        let database = try SQLiteDatabase.openOrCreate(location)
        try database.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS notes USING fts5(
                title,
                body,
                identifier UNINDEXED,
                folder UNINDEXED,
                account UNINDEXED,
                modified UNINDEXED,
                is_locked UNINDEXED,
                tokenize = 'unicode61 remove_diacritics 2'
            )
        """)
        index = database
        return database
    }

    private func openSource() throws -> SQLiteDatabase {
        guard sourceIsReadable else { throw Failure.notAccessible }
        do {
            // Notes keeps its database open with a write-ahead log, so this is opened immutable
            // for the same reason Messages is: it is the only way to read someone else's live
            // database without write access to its side files.
            return try SQLiteDatabase.openReadOnly(source, immutable: true)
        } catch {
            throw Failure.notAccessible
        }
    }
}

extension Array {
    /// Fixed-size slices, for the places SQLite will not take an unbounded list.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
