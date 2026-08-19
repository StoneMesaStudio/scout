import Foundation

/// One message found in Mail.
public struct MailHit: Identifiable, Sendable, Hashable {

    /// The `.emlx` file on disk.
    public let url: URL
    public let subject: String
    public let correspondents: [String]
    public let date: Date?
    /// The mailbox the message sits in, e.g. "Archive" or "Sent".
    public let mailbox: String?
    /// RFC Message-ID, when the index recorded one. Preferred for opening, because it survives
    /// Mail moving the file.
    public let messageID: String?
    public let hasAttachment: Bool

    public var id: URL { url }

    public init(
        url: URL,
        subject: String,
        correspondents: [String],
        date: Date?,
        mailbox: String?,
        messageID: String?,
        hasAttachment: Bool
    ) {
        self.url = url
        self.subject = subject
        self.correspondents = correspondents
        self.date = date
        self.mailbox = mailbox
        self.messageID = messageID
        self.hasAttachment = hasAttachment
    }

    /// What opens the message in Mail. The `message:` scheme is Mail's own and finds the message
    /// wherever it now lives; opening the file is the fallback.
    public var openURL: URL {
        if let messageID, !messageID.isEmpty {
            let trimmed = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
               let url = URL(string: "message:%3C\(encoded)%3E") {
                return url
            }
        }
        return url
    }

    /// Mail stores messages at `…/V10/<account>/<Mailbox>.mbox/…`, so the mailbox name is the
    /// last `.mbox` component in the path.
    public static func mailbox(from url: URL) -> String? {
        url.pathComponents
            .last { $0.hasSuffix(".mbox") }
            .map { String($0.dropLast(".mbox".count)) }
    }
}
