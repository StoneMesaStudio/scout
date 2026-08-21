import Testing
import Foundation
@testable import ScoutCore

/// Builds an Envelope Index shaped like Mail's own, so the query is exercised against the same
/// tables and joins it will meet on a real Mac.
private func makeEnvelopeIndex(
    at directory: URL,
    messages: [(id: Int64, subject: String, senderName: String, senderAddress: String, mailbox: String, received: Int64, messageID: String, read: Bool, deleted: Bool)]
) throws {
    let mailData = directory.appending(path: "V10/MailData", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: mailData, withIntermediateDirectories: true)

    let db = try SQLiteDatabase.openOrCreate(mailData.appending(path: "Envelope Index"))
    try db.execute("""
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE messages (
            ROWID INTEGER PRIMARY KEY, message_id TEXT, subject INTEGER, sender INTEGER,
            mailbox INTEGER, date_received INTEGER, date_sent INTEGER, read INTEGER, deleted INTEGER
        );
    """)

    for (index, message) in messages.enumerated() {
        let key = Int64(index + 1)
        let insertSubject = try db.prepare("INSERT INTO subjects (ROWID, subject) VALUES (?1, ?2)")
        insertSubject.bind(key, at: 1)
        insertSubject.bind(message.subject, at: 2)
        try insertSubject.step()

        let insertAddress = try db.prepare("INSERT INTO addresses (ROWID, address, comment) VALUES (?1, ?2, ?3)")
        insertAddress.bind(key, at: 1)
        insertAddress.bind(message.senderAddress, at: 2)
        insertAddress.bind(message.senderName, at: 3)
        try insertAddress.step()

        let insertMailbox = try db.prepare("INSERT INTO mailboxes (ROWID, url) VALUES (?1, ?2)")
        insertMailbox.bind(key, at: 1)
        insertMailbox.bind(message.mailbox, at: 2)
        try insertMailbox.step()

        let insert = try db.prepare("""
            INSERT INTO messages (ROWID, message_id, subject, sender, mailbox, date_received, date_sent, read, deleted)
            VALUES (?1, ?2, ?3, ?3, ?3, ?4, ?4, ?5, ?6)
        """)
        insert.bind(message.id, at: 1)
        insert.bind(message.messageID, at: 2)
        insert.bind(key, at: 3)
        insert.bind(message.received, at: 4)
        insert.bind(message.read ? 1 : 0, at: 5)
        insert.bind(message.deleted ? 1 : 0, at: 6)
        try insert.step()
    }
}

private func temporaryDirectory() -> URL {
    let url = URL(filePath: NSTemporaryDirectory())
        .appending(path: "scout-mail-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let received: Int64 = 1_770_000_000

@Suite struct MailHitTests {

    @Test func theMailboxNameComesOutOfItsURL() {
        #expect(MailHit.mailboxName(fromURL: "imap://john%40me.com@imap.mail.me.com/Archive") == "Archive")
        #expect(MailHit.mailboxName(fromURL: "file:///Users/t/Mail/Sent.mbox") == "Sent")
        #expect(MailHit.mailboxName(fromURL: nil) == nil)
    }

    @Test func aMessageIDOpensThroughMailsOwnScheme() {
        // Preferred over anything path-based, because Mail moves messages between mailboxes.
        let hit = MailHit(
            rowID: 1, subject: "60,000 mile service", sender: "Bob's Auto",
            senderAddress: "bob@example.com", date: nil, mailbox: "Archive",
            messageID: "<abc123@example.com>", isUnread: false
        )
        #expect(hit.openURL?.scheme == "message")
    }

    @Test func withoutAMessageIDThereIsNothingToOpen() {
        let hit = MailHit(
            rowID: 1, subject: "x", sender: "y", senderAddress: nil,
            date: nil, mailbox: nil, messageID: nil, isUnread: false
        )
        #expect(hit.openURL == nil)
    }

    @Test func modernAndAncientTimestampsBothReadAsTheRightDate() {
        // Mail writes Unix seconds now; very old rows use the Apple reference date instead.
        let unix = MailHit.date(fromEnvelopeTimestamp: 1_770_000_000)
        let apple = MailHit.date(fromEnvelopeTimestamp: 1_770_000_000 - 978_307_200)
        #expect(unix != nil)
        #expect(abs(unix!.timeIntervalSince(apple!)) < 1)
        #expect(MailHit.date(fromEnvelopeTimestamp: 0) == nil)
    }
}

@Suite struct MailIndexTests {

    private func makeIndex(
        _ messages: [(id: Int64, subject: String, senderName: String, senderAddress: String, mailbox: String, received: Int64, messageID: String, read: Bool, deleted: Bool)]
    ) throws -> MailIndex {
        let directory = temporaryDirectory()
        try makeEnvelopeIndex(at: directory, messages: messages)
        return MailIndex(mailDirectory: directory)
    }

    @Test func aMessageIsFoundByItsSubject() throws {
        let index = try makeIndex([
            (1, "F350 60,000 mile service", "Bob's Auto", "bob@example.com", "imap://x/Archive", received, "<a@b>", true, false),
            (2, "Dinner Thursday", "Jennifer", "j@example.com", "imap://x/INBOX", received, "<c@d>", true, false),
        ])
        let hits = try index.search("service").items
        #expect(hits.count == 1)
        #expect(hits.first?.sender == "Bob's Auto")
        #expect(hits.first?.mailbox == "Archive")
    }

    @Test func aPersonIsFoundByNameEvenWhenTheSubjectSaysNothing() throws {
        // The search that started this: a name that is certainly in the mail, found by sender.
        let index = try makeIndex([
            (1, "Quote attached", "Jose Ramirez", "jose@example.com", "imap://x/Archive", received, "<a@b>", true, false),
        ])
        #expect(try index.search("jose").items.count == 1)
    }

    @Test func anAddressIsSearchableToo() throws {
        let index = try makeIndex([
            (1, "Hello", "Someone", "jose@capitolford.com", "imap://x/Archive", received, "<a@b>", true, false),
        ])
        #expect(try index.search("capitolford").items.count == 1)
    }

    @Test func deletedMessagesStayDeleted() throws {
        let index = try makeIndex([
            (1, "service", "A", "a@b.com", "imap://x/Archive", received, "<a@b>", true, true),
        ])
        #expect(try index.search("service").items.isEmpty)
    }

    @Test func newestFirst() throws {
        let index = try makeIndex([
            (1, "service one", "A", "a@b.com", "imap://x/Archive", received, "<a@b>", true, false),
            (2, "service two", "B", "b@b.com", "imap://x/Archive", received + 86_400, "<c@d>", true, false),
        ])
        #expect(try index.search("service").items.map(\.rowID) == [2, 1])
    }

    @Test func unreadIsCarriedThrough() throws {
        let index = try makeIndex([
            (1, "service", "A", "a@b.com", "imap://x/Archive", received, "<a@b>", false, false),
        ])
        #expect(try index.search("service").items.first?.isUnread == true)
    }

    @Test func aMessageWithNoSubjectSaysSoRatherThanShowingNothing() throws {
        let index = try makeIndex([
            (1, "", "Jose", "jose@example.com", "imap://x/Archive", received, "<a@b>", true, false),
        ])
        #expect(try index.search("jose").items.first?.subject == "(no subject)")
    }

    @Test func theNewestMailVersionFolderWins() throws {
        // Mail versions its storage — V10 today, V11 after some future macOS.
        let directory = temporaryDirectory()
        try makeEnvelopeIndex(at: directory, messages: [
            (1, "old", "A", "a@b.com", "imap://x/Archive", received, "<a@b>", true, false),
        ])
        let newer = directory.appending(path: "V11/MailData", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        _ = try SQLiteDatabase.openOrCreate(newer.appending(path: "Envelope Index"))

        #expect(MailIndex(mailDirectory: directory).locateIndex()?.path.contains("/V11/") == true)
    }

    @Test func sqlWildcardsAreSearchedForRatherThanObeyed() {
        // Someone looking for "50%_off" wants those characters, not every message.
        #expect(MailIndex.escapeForLike("50%_off") == "50\\%\\_off")
    }

    @Test func aMissingMailFolderReadsAsAPermissionProblem() {
        let index = MailIndex(mailDirectory: URL(filePath: "/nowhere/Mail"))
        #expect(!index.isAccessible)
        #expect(throws: MailIndex.Failure.self) { try index.search("anything") }
    }
}

@Suite struct MailOrderingTests {

    @Test func mailInTheTrashSortsBelowMailThatIsNot() throws {
        // Deleting something is not the same as not wanting to find it — but a folder of things
        // already thrown away should not be the first answer either.
        let directory = temporaryDirectory()
        try makeEnvelopeIndex(at: directory, messages: [
            (1, "service today", "A", "a@b.com", "imap://x/Deleted Messages", received + 86_400, "<a@b>", true, false),
            (2, "service last week", "B", "b@b.com", "imap://x/Archive", received, "<c@d>", true, false),
        ])
        let hits = try MailIndex(mailDirectory: directory).search("service").items
        #expect(hits.map(\.mailbox) == ["Archive", "Deleted Messages"])
    }
}
