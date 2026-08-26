// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Testing
import Foundation
@testable import ScoutCore

/// Builds a chat.db shaped like the real one, so the index is exercised against the same schema
/// and the same join it will meet on a real Mac.
private func makeChatDatabase(at url: URL, messages: [(id: Int64, text: String?, blob: Data?, handle: String, chat: String, date: Int64, fromMe: Bool)]) throws {
    let db = try SQLiteDatabase.openOrCreate(url)
    try db.execute("""
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, display_name TEXT, chat_identifier TEXT);
        CREATE TABLE message (
            ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, date INTEGER,
            is_from_me INTEGER, cache_has_attachments INTEGER, handle_id INTEGER
        );
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
    """)

    for (index, message) in messages.enumerated() {
        let handleID = Int64(index + 1)
        try db.execute("INSERT INTO handle (ROWID, id) VALUES (\(handleID), '\(message.handle)')")
        try db.execute("INSERT INTO chat (ROWID, display_name, chat_identifier) VALUES (\(handleID), '', '\(message.chat)')")

        let insert = try db.prepare("""
            INSERT INTO message (ROWID, text, attributedBody, date, is_from_me, cache_has_attachments, handle_id)
            VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6)
        """)
        insert.bind(message.id, at: 1)
        if let text = message.text { insert.bind(text, at: 2) }
        if let blob = message.blob { insert.bindBlob(blob, at: 3) }
        insert.bind(message.date, at: 4)
        insert.bind(message.fromMe ? 1 : 0, at: 5)
        insert.bind(handleID, at: 6)
        try insert.step()

        try db.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (\(handleID), \(message.id))")
    }
}

/// A minimal typedstream blob shaped the way Messages writes one: the class name, some
/// bookkeeping, then a length byte and the UTF-8 body.
private func makeAttributedBody(_ text: String) -> Data {
    var bytes: [UInt8] = Array("NSMutableString".utf8)
    bytes += [0x01, 0x94, 0x84, 0x01]
    bytes += [0x2B, UInt8(text.utf8.count)]
    bytes += Array(text.utf8)
    return Data(bytes)
}

private func temporaryDirectory() -> URL {
    let url = URL(filePath: NSTemporaryDirectory())
        .appending(path: "scout-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct TypedStreamTests {

    @Test func textIsRecoveredFromAStyledBody() {
        let blob = makeAttributedBody("the truck is out of service til Thursday")
        #expect(TypedStreamText.extract(from: blob) == "the truck is out of service til Thursday")
    }

    @Test func longMessagesUseATwoByteLength() {
        let text = String(repeating: "service ", count: 40)
        var bytes: [UInt8] = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01]
        let count = text.utf8.count
        bytes += [0x81, UInt8(count & 0xFF), UInt8(count >> 8)]
        bytes += Array(text.utf8)
        #expect(TypedStreamText.extract(from: Data(bytes)) == text)
    }

    @Test func nonsenseReturnsNothingRatherThanGuessing() {
        #expect(TypedStreamText.extract(from: Data([0x00, 0x01, 0x02])) == nil)
        #expect(TypedStreamText.extract(from: Data()) == nil)
    }
}

@Suite struct MessageQueryTests {

    @Test func everyWordIsQuotedSoPunctuationCannotBreakTheQuery() {
        #expect(MessageIndex.ftsQuery(for: "service") == "\"service\"*")
        #expect(MessageIndex.ftsQuery(for: "bob's auto") == "\"bob's\" \"auto\"*")
    }

    @Test func aPhoneNumberIsNotReadAsOperators() {
        #expect(MessageIndex.ftsQuery(for: "916-555-0142") == "\"916-555-0142\"*")
    }
}

@Suite struct MessageIndexTests {

    private func makeIndex(_ messages: [(id: Int64, text: String?, blob: Data?, handle: String, chat: String, date: Int64, fromMe: Bool)]) throws -> MessageIndex {
        let directory = temporaryDirectory()
        let source = directory.appending(path: "chat.db")
        try makeChatDatabase(at: source, messages: messages)
        return MessageIndex(source: source, location: directory.appending(path: "index.sqlite"))
    }

    // 14 Mar 2026, as Messages stores it: nanoseconds since 2001.
    private let stamp: Int64 = 763_000_000 * 1_000_000_000

    @Test func aMessageIsFoundByItsWords() throws {
        let index = try makeIndex([
            (1, "truck is out of service til Thursday", nil, "+19165550142", "chat1", stamp, false),
            (2, "dinner at seven?", nil, "+19165550143", "chat2", stamp, false),
        ])
        try index.sync()

        let hits = try index.search("service").items
        #expect(hits.count == 1)
        #expect(hits.first?.counterpart == "+19165550142")
        #expect(hits.first?.chatIdentifier == "chat1")
    }

    @Test func messagesStoredOnlyAsStyledBlobsAreStillFound() throws {
        // The reason Messages search feels broken: on recent macOS the plain text column is
        // often empty and everything lives in the blob.
        let index = try makeIndex([
            (1, nil, makeAttributedBody("the service guy's number"), "+19165550142", "chat1", stamp, false),
        ])
        try index.sync()
        #expect(try index.search("service").items.count == 1)
    }

    @Test func aPartialLastWordStillMatchesWhileTyping() throws {
        let index = try makeIndex([
            (1, "out of service til Thursday", nil, "+1", "chat1", stamp, false),
        ])
        try index.sync()
        #expect(try index.search("serv").items.count == 1)
    }

    @Test func newestFirst() throws {
        let index = try makeIndex([
            (1, "service one", nil, "+1", "chat1", stamp, false),
            (2, "service two", nil, "+2", "chat2", stamp + 86_400_000_000_000, false),
        ])
        try index.sync()
        #expect(try index.search("service").items.map(\.rowID) == [2, 1])
    }

    @Test func syncingTwiceAddsNothingTheSecondTime() throws {
        let index = try makeIndex([
            (1, "service one", nil, "+1", "chat1", stamp, false),
        ])
        #expect(try index.sync() == 1)
        #expect(try index.sync() == 0)
    }

    @Test func messagesWithNoTextAtAllAreSkipped() throws {
        // A bare photo or a tapback has nothing in it to find.
        let index = try makeIndex([
            (1, nil, nil, "+1", "chat1", stamp, false),
            (2, "service", nil, "+1", "chat1", stamp, false),
        ])
        #expect(try index.sync() == 1)
    }

    @Test func aMessageInTwoConversationsIsIndexedOnce() throws {
        // The join multiplies rows per chat; inserting the same message twice fails the whole
        // sync on a constraint, which is how a real 33,000-message history refused to index.
        let directory = temporaryDirectory()
        let source = directory.appending(path: "chat.db")
        try makeChatDatabase(at: source, messages: [
            (1, "service call", nil, "+1", "chat1", stamp, false),
        ])
        let extra = try SQLiteDatabase.openOrCreate(source)
        try extra.execute("INSERT INTO chat (ROWID, display_name, chat_identifier) VALUES (99, '', 'chat2')")
        try extra.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (99, 1)")

        let index = MessageIndex(source: source, location: directory.appending(path: "index.sqlite"))
        #expect(try index.sync() == 1)
        #expect(try index.search("service").items.count == 1)
    }

    @Test func aMissingDatabaseReadsAsAPermissionProblem() {
        let index = MessageIndex(
            source: URL(filePath: "/nowhere/chat.db"),
            location: temporaryDirectory().appending(path: "index.sqlite")
        )
        #expect(!index.sourceIsReadable)
        #expect(throws: MessageIndex.Failure.self) { try index.sync() }
    }

    @Test func aConversationOpensInMessages() {
        let hit = MessageHit(
            rowID: 1, text: "x", date: .now, isFromMe: false,
            counterpart: "Jennifer", chatIdentifier: "+19165550142", hasAttachment: false
        )
        #expect(hit.openURL?.absoluteString == "imessage://+19165550142")
    }

    @Test func oldMessagesStoredInSecondsStillReadAsTheRightDate() {
        // Rows written by very old versions of Messages are in whole seconds, not nanoseconds.
        let seconds = MessageHit.date(fromAppleTimestamp: 763_000_000)
        let nanoseconds = MessageHit.date(fromAppleTimestamp: 763_000_000 * 1_000_000_000)
        #expect(abs(seconds.timeIntervalSince(nanoseconds)) < 1)
    }
}
