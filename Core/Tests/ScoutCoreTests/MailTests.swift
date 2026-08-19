import Testing
import Foundation
@testable import ScoutCore

@Suite struct MailHitTests {

    private let messagePath = "/Users/tester/Library/Mail/V10/ACC/Archive.mbox/1234/Data/5/Messages/5.emlx"

    @Test func theMailboxNameComesOutOfThePath() {
        #expect(MailHit.mailbox(from: URL(filePath: messagePath)) == "Archive")
    }

    @Test func aMessageWithNoMailboxInItsPathSaysSoRatherThanGuessing() {
        #expect(MailHit.mailbox(from: URL(filePath: "/tmp/loose.emlx")) == nil)
    }

    @Test func aMessageIDOpensThroughMailsOwnScheme() {
        // Preferred over the file, because Mail moves messages between mailboxes.
        let hit = MailHit(
            url: URL(filePath: messagePath),
            subject: "60,000 mile service",
            correspondents: ["Bob's Auto"],
            date: nil,
            mailbox: "Archive",
            messageID: "<abc123@example.com>",
            hasAttachment: true
        )
        #expect(hit.openURL.scheme == "message")
    }

    @Test func withoutAMessageIDTheFileItselfIsOpened() {
        let hit = MailHit(
            url: URL(filePath: messagePath),
            subject: "x", correspondents: [], date: nil, mailbox: nil,
            messageID: nil, hasAttachment: false
        )
        #expect(hit.openURL.isFileURL)
    }
}

@Suite struct MailPredicateTests {

    @Test func onlyMailMessagesCanMatch() {
        // A PDF sitting inside the Mail folder is not a search result in the Mail lane.
        let predicate = MailSearcher.predicate(for: "service").predicateFormat
        #expect(predicate.contains("com.apple.mail.emlx"))
    }

    @Test func subjectSenderAndBodyAreAllSearched() {
        let predicate = MailSearcher.predicate(for: "service").predicateFormat
        #expect(predicate.contains("kMDItemSubject"))
        #expect(predicate.contains("kMDItemAuthors"))
        #expect(predicate.contains("kMDItemTextContent"))
    }

    @Test func typedWildcardsAreEscapedRatherThanObeyed() {
        // Someone searching for "10*" wants the characters, not every message.
        let predicate = MailSearcher.predicate(for: "10*").predicateFormat
        #expect(predicate.contains("\\\\*"))
    }
}

@Suite struct FilePredicateTests {

    @Test func namesAndDocumentTextAreBothSearched() {
        let predicate = SpotlightSearcher.predicate(for: "service").predicateFormat
        #expect(predicate.contains("kMDItemDisplayName"))
        #expect(predicate.contains("kMDItemTextContent"))
    }

    @Test func typedWildcardsAreEscaped() {
        #expect(SpotlightSearcher.predicate(for: "a*b").predicateFormat.contains("\\\\*"))
    }
}
