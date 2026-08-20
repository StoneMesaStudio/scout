import Foundation
import SQLite3

/// A very small SQLite wrapper — just enough to read the Messages database and keep an index of
/// our own, without taking on a dependency for two files' worth of work.
///
/// Not `Sendable` on purpose: an SQLite connection belongs to whoever opened it.
final class SQLiteDatabase {

    // LocalizedError as well as CustomStringConvertible: anything that reports a failure through
    // `localizedDescription` would otherwise show "error 2" instead of what SQLite actually said.
    enum Error: Swift.Error, CustomStringConvertible, LocalizedError {
        case open(String)
        case prepare(String)
        case step(String)

        var description: String {
            switch self {
            case .open(let m): "Could not open the database: \(m)"
            case .prepare(let m): "Could not prepare the statement: \(m)"
            case .step(let m): "Could not run the statement: \(m)"
            }
        }

        var errorDescription: String? { description }
    }

    private let handle: OpaquePointer

    /// Open read-only. `immutable` skips the write-ahead log, which is the only way to read a
    /// database another process has open without needing write access to its side files — at the
    /// cost of missing the newest rows still sitting in that log.
    static func openReadOnly(_ url: URL, immutable: Bool = false) throws -> SQLiteDatabase {
        var uri = "file:\(url.path)?mode=ro"
        if immutable { uri += "&immutable=1" }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw Error.open(message)
        }
        return SQLiteDatabase(handle: handle)
    }

    /// Open (creating if needed) a database we own and write to.
    static func openOrCreate(_ url: URL) throws -> SQLiteDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw Error.open(message)
        }

        let database = SQLiteDatabase(handle: handle)
        // Write-ahead logging lets a reader and a writer work at once, and a busy timeout makes
        // the loser of a race wait rather than fail. Without both, two copies of Scout — or the
        // app and a diagnostic run — collide on the index and one reports "database is locked".
        try? database.execute("PRAGMA journal_mode=WAL")
        sqlite3_busy_timeout(handle, 5_000)
        return database
    }

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw Error.step(lastErrorMessage)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Error.prepare(lastErrorMessage)
        }
        return SQLiteStatement(handle: statement, database: self)
    }

    /// Does a table exist? Used to tell "this is not the database we expected" from "it is empty".
    func hasTable(_ name: String) -> Bool {
        guard let statement = try? prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1") else {
            return false
        }
        statement.bind(name, at: 1)
        return (try? statement.step()) == true
    }
}

/// One prepared statement. Stepping returns false when there are no more rows.
final class SQLiteStatement {

    private let handle: OpaquePointer
    /// Held so the connection cannot be closed while a statement is still alive.
    private let database: SQLiteDatabase

    init(handle: OpaquePointer, database: SQLiteDatabase) {
        self.handle = handle
        self.database = database
    }

    deinit {
        sqlite3_finalize(handle)
    }

    // SQLITE_TRANSIENT: tell SQLite to copy the bytes, because the Swift string may not outlive
    // the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func bind(_ value: String, at index: Int32) {
        sqlite3_bind_text(handle, index, value, -1, Self.transient)
    }

    func bind(_ value: Int64, at index: Int32) {
        sqlite3_bind_int64(handle, index, value)
    }

    func bindBlob(_ value: Data, at index: Int32) {
        value.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
        }
    }

    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteDatabase.Error.step(database.lastErrorMessage)
        }
    }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func string(_ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: cString)
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    func bool(_ column: Int32) -> Bool {
        sqlite3_column_int64(handle, column) != 0
    }

    func blob(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(handle, column) else { return nil }
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }
}
