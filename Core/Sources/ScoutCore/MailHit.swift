import Foundation

/// One message found in Mail.
public struct MailHit: Identifiable, Sendable, Hashable {

    public let rowID: Int64
    public let subject: String
    /// The sender's name where Mail recorded one, otherwise their address.
    public let sender: String
    public let senderAddress: String?
    public let date: Date?
    /// The mailbox it sits in, e.g. "Archive" or "Sent".
    public let mailbox: String?
    /// RFC Message-ID. This is what opens the message, and it survives Mail moving the file.
    public let messageID: String?
    public let isUnread: Bool

    public var id: Int64 { rowID }

    public init(
        rowID: Int64,
        subject: String,
        sender: String,
        senderAddress: String?,
        date: Date?,
        mailbox: String?,
        messageID: String?,
        isUnread: Bool
    ) {
        self.rowID = rowID
        self.subject = subject
        self.sender = sender
        self.senderAddress = senderAddress
        self.date = date
        self.mailbox = mailbox
        self.messageID = messageID
        self.isUnread = isUnread
    }

    /// What opens the message in Mail. The `message:` scheme is Mail's own and finds the message
    /// wherever it now lives.
    public var openURL: URL? {
        guard let messageID, !messageID.isEmpty else { return nil }
        let trimmed = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        return URL(string: "message:%3C\(encoded)%3E")
    }

    /// Mail stores a mailbox as a URL — `imap://…@host/Archive`, `file:///…/Sent.mbox`. Only the
    /// last part means anything to a person.
    public static func mailboxName(fromURL url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        let lastComponent = url.split(separator: "/").last.map(String.init) ?? url
        let decoded = lastComponent.removingPercentEncoding ?? lastComponent
        let trimmed = decoded.hasSuffix(".mbox") ? String(decoded.dropLast(5)) : decoded
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Mail's Envelope Index writes dates as Unix seconds. Very old rows use the Apple reference
    /// date instead, and the two are far enough apart to tell by size alone.
    public static func date(fromEnvelopeTimestamp raw: Int64) -> Date? {
        guard raw > 0 else { return nil }
        return raw > 1_000_000_000
            ? Date(timeIntervalSince1970: TimeInterval(raw))
            : Date(timeIntervalSinceReferenceDate: TimeInterval(raw))
    }
}
