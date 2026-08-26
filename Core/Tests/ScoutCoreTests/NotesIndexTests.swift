// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Compression
import Foundation
import Testing
@testable import ScoutCore

// MARK: - Building a Notes database shaped like the real one

/// One note as Notes would store it.
private struct FakeNote {
    var pk: Int64
    var title: String
    /// The text of the note. Notes keeps the title as the first line of the body too, so the
    /// fixtures do the same.
    var body: String?
    var modified: Double
    var identifier: String = UUID().uuidString
    var folder: Int64?
    var locked: Bool = false
    var deleted: Bool = false
    /// Set to put something in the blob that is not a gzipped note — which is what a
    /// password-protected note actually contains.
    var rawBlob: Data?
}

/// The two tables Notes keeps, with the column names it uses.
///
/// `modifiedColumn` is a parameter because Apple has renamed it more than once, and the whole
/// point of asking the database what columns it has is that the lane survives the next rename.
private func makeNotesDatabase(
    at url: URL,
    notes: [FakeNote],
    folders: [Int64: String] = [:],
    modifiedColumn: String = "ZMODIFICATIONDATE1"
) throws {
    let db = try SQLiteDatabase.openOrCreate(url)
    try db.execute("""
        CREATE TABLE ZICCLOUDSYNCINGOBJECT (
            Z_PK INTEGER PRIMARY KEY,
            ZTITLE1 TEXT,
            ZTITLE2 TEXT,
            ZIDENTIFIER TEXT,
            \(modifiedColumn) REAL,
            ZFOLDER INTEGER,
            ZACCOUNT4 INTEGER,
            ZNOTEDATA INTEGER,
            ZISPASSWORDPROTECTED INTEGER,
            ZMARKEDFORDELETION INTEGER
        );
        CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB);
    """)

    for (pk, name) in folders {
        let insert = try db.prepare("INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZTITLE2) VALUES (?1, ?2)")
        insert.bind(pk, at: 1)
        insert.bind(name, at: 2)
        try insert.step()
    }

    for note in notes {
        let insert = try db.prepare("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT
                (Z_PK, ZTITLE1, ZIDENTIFIER, \(modifiedColumn), ZFOLDER, ZNOTEDATA,
                 ZISPASSWORDPROTECTED, ZMARKEDFORDELETION)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        """)
        insert.bind(note.pk, at: 1)
        insert.bind(note.title, at: 2)
        insert.bind(note.identifier, at: 3)
        insert.bindDouble(note.modified, at: 4)
        insert.bind(note.folder ?? 0, at: 5)
        insert.bind(note.pk, at: 6)                       // the note-data link
        insert.bind(note.locked ? Int64(1) : Int64(0), at: 7)
        insert.bind(note.deleted ? Int64(1) : Int64(0), at: 8)
        try insert.step()

        let blob: Data? = note.rawBlob ?? note.body.map { gzip(noteProtobuf(text: $0)) }
        let data = try db.prepare("INSERT INTO ZICNOTEDATA (Z_PK, ZNOTE, ZDATA) VALUES (?1, ?2, ?3)")
        data.bind(note.pk, at: 1)
        data.bind(note.pk, at: 2)
        if let blob { data.bindBlob(blob, at: 3) }
        try data.step()
    }
}

// MARK: - Encoding the things Notes stores

private func varint(_ value: UInt64) -> [UInt8] {
    var value = value
    var bytes: [UInt8] = []
    repeat {
        var byte = UInt8(value & 0x7F)
        value >>= 7
        if value != 0 { byte |= 0x80 }
        bytes.append(byte)
    } while value != 0
    return bytes
}

private func lengthDelimited(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
    varint(UInt64(field << 3 | 2)) + varint(UInt64(payload.count)) + payload
}

/// `NoteStoreProto.document (2) → Document.note (3) → Note.text (2)`, the way Notes writes it —
/// version field and all, so the fixture is not simply the happy path with everything else removed.
private func noteProtobuf(text: String) -> Data {
    let note = lengthDelimited(2, Array(text.utf8))
    let document = varint(UInt64(2 << 3)) + varint(2) + lengthDelimited(3, note)
    return Data(lengthDelimited(2, document))
}

/// Gzip, with a trailer of zeroes: the decoder never reads the checksum, and a fixture that
/// needed a correct CRC32 would be testing the test.
private func gzip(_ data: Data) -> Data {
    var output = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
    output.append(deflate(data))
    output.append(Data(repeating: 0, count: 8))
    return output
}

private func deflate(_ data: Data) -> Data {
    let source = [UInt8](data)
    let capacity = max(1024, source.count * 2)
    let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    defer { destination.deallocate() }

    let written = source.withUnsafeBufferPointer { buffer in
        compression_encode_buffer(destination, capacity,
                                  buffer.baseAddress!, buffer.count,
                                  nil, COMPRESSION_ZLIB)
    }
    return Data(bytes: destination, count: written)
}

private func notesTemporaryDirectory() -> URL {
    let url = URL(filePath: NSTemporaryDirectory())
        .appending(path: "scout-notes-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Reading a note out of the blob

@Suite struct NoteBodyTests {

    @Test func textIsRecoveredFromAGzippedProtobuf() {
        let blob = gzip(noteProtobuf(text: "Insurance\nPolicy 4471 renews in March"))
        #expect(NotesIndex.body(from: blob) == "Insurance Policy 4471 renews in March")
    }

    @Test func aBlobThatIsNotGzipAtAllComesBackEmptyRatherThanAsNonsense() {
        // This is what a password-protected note holds: encrypted bytes, not compressed ones.
        #expect(NotesIndex.body(from: Data([0x51, 0x22, 0x9f, 0x03, 0x71])) == nil)
        #expect(NotesIndex.body(from: Data()) == nil)
    }

    @Test func attachmentsAndBlankLinesCollapseToSingleSpaces() {
        // U+FFFC is the placeholder Notes leaves where a picture, table or drawing sits.
        let blob = gzip(noteProtobuf(text: "Trip\n\n\u{FFFC}\n\nferry at 8"))
        #expect(NotesIndex.body(from: blob) == "Trip ferry at 8")
    }

    @Test func theTitleIsNotStoredTwice() {
        // Notes repeats the title as the first line of the body. Left in, every snippet would
        // open with the heading the reader is already looking at.
        #expect(NotesIndex.strippingTitle("Insurance", from: "Insurance Policy 4471") == "Policy 4471")
        #expect(NotesIndex.strippingTitle("Insurance", from: "Policy 4471") == "Policy 4471")
        #expect(NotesIndex.strippingTitle("", from: "Policy 4471") == "Policy 4471")
    }

    @Test func aProtobufWithTheTextSomewhereElseStillGivesUpItsWords() {
        // The fallback. If Apple moves the field, the lane degrades to finding the longest run
        // of readable text rather than going silent.
        let odd = Data(lengthDelimited(9, Array("the shed key is under the pot".utf8)))
        #expect(NoteProtobuf.text(in: odd) == "the shed key is under the pot")
    }

    @Test func randomBytesAreNotMistakenForANote() {
        #expect(NoteProtobuf.text(in: Data([0xFF, 0xFF, 0xFF, 0xFF])) == nil)
    }
}

// MARK: - The index

@Suite struct NotesIndexTests {

    private func makeIndex(
        _ notes: [FakeNote],
        folders: [Int64: String] = [:],
        modifiedColumn: String = "ZMODIFICATIONDATE1"
    ) throws -> (NotesIndex, URL) {
        let directory = notesTemporaryDirectory()
        let source = directory.appending(path: "NoteStore.sqlite")
        try makeNotesDatabase(at: source, notes: notes, folders: folders, modifiedColumn: modifiedColumn)
        return (NotesIndex(source: source, location: directory.appending(path: "index.sqlite")), source)
    }

    // 14 Mar 2026, as Core Data stores it: seconds since 2001.
    private let stamp: Double = 763_000_000

    @Test func aNoteIsFoundByAWordInsideIt() throws {
        let (index, _) = try makeIndex([
            FakeNote(pk: 1, title: "Insurance", body: "Insurance policy 4471 renews in March", modified: stamp, folder: 90),
            FakeNote(pk: 2, title: "Groceries", body: "Groceries milk bread", modified: stamp, folder: 90),
        ], folders: [90: "Household"])
        try index.sync()

        let hits = try index.search("policy").items
        #expect(hits.count == 1)
        #expect(hits.first?.title == "Insurance")
        #expect(hits.first?.folder == "Household")
    }

    @Test func aTitleMatchOutranksABodyMatch() throws {
        let (index, _) = try makeIndex([
            FakeNote(pk: 1, title: "Chimney sweep", body: "Chimney sweep booked for the 4th", modified: stamp),
            FakeNote(pk: 2, title: "House jobs", body: "House jobs gutters, chimney, gate", modified: stamp),
        ])
        try index.sync()
        #expect(try index.search("chimney").items.map(\.rowID) == [1, 2])
    }

    @Test func editingANoteReindexesIt() throws {
        // The trap the Messages index would have walked into: messages are only ever appended,
        // notes are edited in place, and a high-water mark on the row id would never look again.
        let (index, source) = try makeIndex([
            FakeNote(pk: 1, title: "Shed", body: "Shed key is under the pot", modified: stamp),
        ])
        try index.sync()
        #expect(try index.search("pot").items.count == 1)

        let db = try SQLiteDatabase.openOrCreate(source)
        let update = try db.prepare("UPDATE ZICNOTEDATA SET ZDATA = ?1 WHERE ZNOTE = 1")
        update.bindBlob(gzip(noteProtobuf(text: "Shed key is on the hook")), at: 1)
        try update.step()
        try db.execute("UPDATE ZICCLOUDSYNCINGOBJECT SET ZMODIFICATIONDATE1 = \(stamp + 60) WHERE Z_PK = 1")
        // Scout opens Notes' database `immutable=1`, which ignores the write-ahead log — the
        // only way to read a database another process has open. So an edit made from a second
        // connection is invisible until it is checkpointed, exactly as with Mail's index.
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")

        #expect(try index.sync() == 1)
        #expect(try index.search("pot").items.isEmpty)
        #expect(try index.search("hook").items.count == 1)
    }

    @Test func aDeletedNoteLeavesTheIndex() throws {
        // A result that opens nothing is worse than no result.
        let (index, source) = try makeIndex([
            FakeNote(pk: 1, title: "Shed", body: "Shed key is under the pot", modified: stamp),
        ])
        try index.sync()

        let db = try SQLiteDatabase.openOrCreate(source)
        try db.execute("DELETE FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = 1")
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")

        #expect(try index.sync() == 1)
        #expect(try index.search("pot").items.isEmpty)
    }

    @Test func notesInTheTrashAreNeverIndexed() throws {
        let (index, _) = try makeIndex([
            FakeNote(pk: 1, title: "Old", body: "Old chimney quote", modified: stamp, deleted: true),
            FakeNote(pk: 2, title: "New", body: "New chimney quote", modified: stamp),
        ])
        #expect(try index.sync() == 1)
        #expect(try index.search("chimney").items.map(\.rowID) == [2])
    }

    @Test func rowsWithNeitherATitleNorABodyAreNotNotes() throws {
        // Notes leaves these behind by the hundred — 193 of 420 rows on the Mac this was built
        // on. Nothing can ever match them, and counting them makes the lane look bigger than it
        // is. A note with only a title, or only a body, is a real note and stays.
        let (index, _) = try makeIndex([
            FakeNote(pk: 1, title: "", body: nil, modified: stamp),
            FakeNote(pk: 2, title: "Just a heading", body: nil, modified: stamp),
            FakeNote(pk: 3, title: "", body: "untitled but full of words", modified: stamp),
        ])
        #expect(try index.sync() == 2)
        #expect(try index.indexedCount() == 2)
        #expect(try index.search("heading").items.map(\.rowID) == [2])
        #expect(try index.search("words").items.map(\.rowID) == [3])
    }

    @Test func syncingTwiceReadsNothingTheSecondTime() throws {
        let (index, _) = try makeIndex([
            FakeNote(pk: 1, title: "Shed", body: "Shed key is under the pot", modified: stamp),
        ])
        #expect(try index.sync() == 1)
        #expect(try index.sync() == 0)
    }

    @Test func aLockedNoteIsFoundByItsTitleAndSaysSo() throws {
        // Notes encrypts the body, so the title is all there is. Saying "locked" is the
        // difference between "nothing in it matched" and "Scout cannot read what is in it".
        let (index, _) = try makeIndex([
            FakeNote(pk: 1, title: "Passwords", body: nil, modified: stamp,
                     locked: true, rawBlob: Data([0x51, 0x22, 0x9f, 0x03])),
        ])
        try index.sync()

        let hits = try index.search("passwords").items
        #expect(hits.count == 1)
        #expect(hits.first?.isLocked == true)
    }

    @Test func aRenamedColumnCostsNothing() throws {
        // Apple has renamed the modification date more than once. Asking the database what it
        // has is what keeps a rename from emptying the lane.
        let (index, _) = try makeIndex([
            FakeNote(pk: 1, title: "Shed", body: "Shed key is under the pot", modified: stamp),
        ], modifiedColumn: "ZMODIFICATIONDATE")
        try index.sync()
        #expect(try index.search("pot").items.count == 1)
    }

    @Test func aDatabaseThatIsNotNotesIsReportedAsSuch() throws {
        let directory = notesTemporaryDirectory()
        let source = directory.appending(path: "NoteStore.sqlite")
        let db = try SQLiteDatabase.openOrCreate(source)
        try db.execute("CREATE TABLE something (a INTEGER)")

        let index = NotesIndex(source: source, location: directory.appending(path: "index.sqlite"))
        #expect(throws: NotesIndex.Failure.self) { try index.sync() }
    }

    @Test func aMissingDatabaseReadsAsAPermissionProblem() {
        let index = NotesIndex(
            source: URL(filePath: "/nowhere/NoteStore.sqlite"),
            location: notesTemporaryDirectory().appending(path: "index.sqlite")
        )
        #expect(!index.sourceIsReadable)
        #expect(throws: NotesIndex.Failure.self) { try index.sync() }
    }

    @Test func aPartialLastWordStillMatchesWhileTyping() throws {
        let (index, _) = try makeIndex([
            FakeNote(pk: 1, title: "Insurance", body: "Insurance policy renews in March", modified: stamp),
        ])
        try index.sync()
        #expect(try index.search("polic").items.count == 1)
    }

    @Test func aNoteOpensInNotes() {
        let hit = NoteHit(rowID: 1, identifier: "3B0A0F0E-1111-2222-3333-444455556666",
                          title: "Shed", folder: nil, account: nil, modified: nil)
        #expect(hit.openURL?.absoluteString == "notes://showNote?identifier=3B0A0F0E-1111-2222-3333-444455556666")
    }

    @Test func aNoteWithNoIdentifierOpensNothingRatherThanTheWrongThing() {
        let hit = NoteHit(rowID: 1, identifier: nil, title: "Shed", folder: nil, account: nil, modified: nil)
        #expect(hit.openURL == nil)
    }
}
