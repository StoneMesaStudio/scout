import Testing
import Foundation
@testable import ScoutCore

private func temporaryDirectory() -> URL {
    let url = URL(filePath: NSTemporaryDirectory())
        .appending(path: "scout-bodies-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a message file shaped the way Mail writes one: a byte count, the message, then a plist.
private func writeMessage(
    at directory: URL,
    named name: String,
    messageID: String,
    headers: String = "",
    body: String
) throws {
    let mailbox = directory.appending(path: "V10/Account/Archive.mbox/Data/Messages", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: mailbox, withIntermediateDirectories: true)

    let message = """
    From: someone@example.com\r
    Subject: a subject\r
    Message-ID: \(messageID)\r
    \(headers)\r
    \r
    \(body)
    """
    let file = "\(message.utf8.count)\n\(message)\n<?xml version=\"1.0\"?><plist></plist>"
    try file.write(to: mailbox.appending(path: "\(name).emlx"), atomically: true, encoding: .utf8)
}

@Suite struct MailBodyLimitTests {

    /// Rows read under one pair of limits are not comparable to rows read under another, so
    /// widening either has to invalidate everything. Half an index at 64 KB and half at 256 KB is
    /// a search that covers some messages further than others with no way to tell which.
    @Test func changingTheLimitsEmptiesTheIndex() throws {
        let directory = temporaryDirectory()
        let location = directory.appending(path: "bodies.sqlite")
        try writeMessage(at: directory, named: "1", messageID: "<a@example.com>", body: "the chimney quote")

        let first = MailBodyIndex(mailDirectory: directory, location: location)
        _ = try first.sync()
        #expect(try first.progress().indexed == 1)

        // Stand in for a future change to `readLimit` by ageing what the index recorded.
        let database = try SQLiteDatabase.openOrCreate(location)
        try database.execute("UPDATE limits SET value = 1 WHERE key = 'read'")

        let second = MailBodyIndex(mailDirectory: directory, location: location)
        #expect(try second.progress().indexed == 0)
    }

    @Test func anUnchangedIndexIsLeftAlone() throws {
        let directory = temporaryDirectory()
        let location = directory.appending(path: "bodies.sqlite")
        try writeMessage(at: directory, named: "1", messageID: "<a@example.com>", body: "the chimney quote")

        let first = MailBodyIndex(mailDirectory: directory, location: location)
        _ = try first.sync()

        let second = MailBodyIndex(mailDirectory: directory, location: location)
        #expect(try second.progress().indexed == 1)
    }

    /// The window is what it is on purpose; a change to it is a change to how much of the archive
    /// is searchable, and it should not happen by accident.
    @Test func theLimitsAreWhatWeThinkTheyAre() {
        #expect(MailBodyIndex.readLimit == 256 * 1024)
        #expect(MailBodyIndex.bodyLimit == 48_000)
    }
}

@Suite struct MailHeaderTests {

    private let headers = """
    From: Bob <bob@example.com>\r
    Subject: a long subject that\r
     folds onto a second line\r
    Message-ID: <abc123@example.com>\r
    Content-Type: text/html; charset=utf-8
    """

    @Test func aHeaderIsReadByName() {
        #expect(MailBodyIndex.header("Message-ID", in: headers) == "<abc123@example.com>")
    }

    @Test func headerNamesAreNotCaseSensitive() {
        // Mail servers write these however they like.
        #expect(MailBodyIndex.header("message-id", in: headers) == "<abc123@example.com>")
        #expect(MailBodyIndex.header("CONTENT-TYPE", in: headers)?.hasPrefix("text/html") == true)
    }

    @Test func aFoldedHeaderIsJoinedBackTogether() {
        #expect(MailBodyIndex.header("Subject", in: headers) == "a long subject that folds onto a second line")
    }

    @Test func aMissingHeaderIsNil() {
        #expect(MailBodyIndex.header("Reply-To", in: headers) == nil)
    }

    @Test func messageIDsAreComparedWithoutTheirBrackets() {
        // Mail records them one way in one table and the other way in another.
        #expect(MailBodyIndex.normalize("<abc123@example.com>") == "abc123@example.com")
        #expect(MailBodyIndex.normalize(" abc123@example.com \n") == "abc123@example.com")
    }
}

@Suite struct MailBodyTextTests {

    @Test func plainTextComesThroughAsItIs() {
        let text = MailBodyIndex.readableText(from: "the truck is out of service", isHTML: false, quotedPrintable: false)
        #expect(text == "the truck is out of service")
    }

    @Test func htmlTagsAreRemovedButTheWordsSurvive() {
        let html = "<html><body><p>the truck is <b>out of service</b></p></body></html>"
        let text = MailBodyIndex.readableText(from: html, isHTML: true, quotedPrintable: false)
        #expect(text.contains("out of service"))
        #expect(!text.contains("<b>"))
    }

    @Test func scriptAndStyleContentIsThrownAway() {
        let html = "<html><style>.a{color:red}</style><script>var x=1</script><p>real words</p></html>"
        let text = MailBodyIndex.readableText(from: html, isHTML: true, quotedPrintable: false)
        #expect(text.contains("real words"))
        #expect(!text.contains("color"))
        #expect(!text.contains("var"))
    }

    @Test func quotedPrintableIsDecoded() {
        // Soft line breaks and =XX escapes are how accented characters survive email.
        let raw = "caf=C3=A9 service=\r\n today"
        let text = MailBodyIndex.readableText(from: raw, isHTML: false, quotedPrintable: true)
        #expect(text.contains("café"))
        #expect(text.contains("service today"))
    }

    @Test func longUnbrokenRunsAreDropped() {
        // Base64 attachments are megabytes of nothing anyone would search for.
        let base64 = String(repeating: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo", count: 4)
        let text = MailBodyIndex.readableText(from: "real words \(base64) more words", isHTML: false, quotedPrintable: false)
        #expect(text == "real words more words")
    }

    @Test func theStoredTextIsCapped() {
        let huge = String(repeating: "word ", count: 20_000)
        let text = MailBodyIndex.readableText(from: huge, isHTML: false, quotedPrintable: false)
        #expect(text.count <= MailBodyIndex.bodyLimit)
    }
}

@Suite struct MailBodyIndexTests {

    @Test func aMessageIsParsedOutOfItsFile() throws {
        let directory = temporaryDirectory()
        try writeMessage(at: directory, named: "1", messageID: "<abc@example.com>",
                         body: "the truck is out of service until Thursday")

        let file = directory.appending(path: "V10/Account/Archive.mbox/Data/Messages/1.emlx")
        let parsed = MailBodyIndex.parse(file)
        #expect(parsed?.messageID == "abc@example.com")
        #expect(parsed?.body.contains("out of service") == true)
    }

    @Test func indexingIsIncremental() throws {
        let directory = temporaryDirectory()
        try writeMessage(at: directory, named: "1", messageID: "<a@x>", body: "first message about service")

        let index = MailBodyIndex(
            mailDirectory: directory,
            location: directory.appending(path: "bodies.sqlite")
        )
        #expect(try index.sync().indexed == 1)
        // Nothing new to do the second time.
        #expect(try index.sync().indexed == 1)

        try writeMessage(at: directory, named: "2", messageID: "<b@x>", body: "second message about service")
        #expect(try index.sync().indexed == 2)
    }

    @Test func aBudgetLeavesTheRestForNextTime() throws {
        let directory = temporaryDirectory()
        for number in 1...5 {
            try writeMessage(at: directory, named: "\(number)", messageID: "<\(number)@x>", body: "service")
        }
        let index = MailBodyIndex(
            mailDirectory: directory,
            location: directory.appending(path: "bodies.sqlite")
        )
        let first = try index.sync(budget: 2)
        #expect(first.indexed == 2)
        #expect(first.remaining == 3)
        #expect(!first.isComplete)

        _ = try index.sync(budget: 2)
        #expect(try index.sync(budget: 2).isComplete)
    }

    @Test func aFileWithNoMessageIDIsNotRetriedForever() throws {
        // Recorded as seen even though nothing could be read out of it.
        let directory = temporaryDirectory()
        let mailbox = directory.appending(path: "V10/Account/Archive.mbox/Data/Messages", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mailbox, withIntermediateDirectories: true)
        try "12\nnot a message at all".write(to: mailbox.appending(path: "1.emlx"), atomically: true, encoding: .utf8)

        let index = MailBodyIndex(
            mailDirectory: directory,
            location: directory.appending(path: "bodies.sqlite")
        )
        #expect(try index.sync().indexed == 1)
        #expect(try index.sync().remaining == 0)
    }

    @Test func anInaccessibleMailFolderReadsAsAPermissionProblem() {
        let index = MailBodyIndex(
            mailDirectory: URL(filePath: "/nowhere/Mail"),
            location: temporaryDirectory().appending(path: "bodies.sqlite")
        )
        #expect(throws: MailIndex.Failure.self) { try index.sync() }
    }
}

@Suite struct MailFullTextTests {

    /// The whole point: a word that appears only in the body of a message, found through the
    /// Envelope Index by way of Scout's own body index.
    @Test func aWordOnlyInTheBodyFindsTheMessage() throws {
        let directory = temporaryDirectory()
        try makeEnvelopeIndex(at: directory, messages: [
            (1, "Quote attached", "Bob", "bob@example.com", "imap://x/Archive", 1_770_000_000, "<abc@example.com>", true, false),
        ])
        try writeMessage(at: directory, named: "1", messageID: "<abc@example.com>",
                         body: "the estimate for Jose is attached")

        let bodies = MailBodyIndex(
            mailDirectory: directory,
            location: directory.appending(path: "bodies.sqlite")
        )
        try bodies.sync()

        let withoutBodies = MailIndex(mailDirectory: directory)
        #expect(try withoutBodies.search("jose").items.isEmpty)

        let withBodies = MailIndex(
            mailDirectory: directory,
            bodyIndexLocation: directory.appending(path: "bodies.sqlite")
        )
        let page = try withBodies.search("jose")
        #expect(page.items.count == 1)
        #expect(page.items.first?.subject == "Quote attached")
    }
}
