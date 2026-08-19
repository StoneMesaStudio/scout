import Foundation

/// The Mail lane.
///
/// Mail's messages are already in the Spotlight index — the same importer that lets Finder find
/// an attachment indexes subjects, senders and body text. Scout asks for them directly rather
/// than parsing Mail's own storage, which means no second index to keep in step.
///
/// Reading them needs Full Disk Access; without it the query simply returns nothing, which is why
/// `isIndexReadable` exists to tell an empty mailbox from a missing permission.
@MainActor
public final class MailSearcher {

    public var onResults: (([MailHit]) -> Void)?

    private let query = NSMetadataQuery()
    private let home: URL

    private final class TokenBox: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
    }
    private nonisolated let tokens = TokenBox()

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        query.notificationBatchingInterval = 0.15
        query.sortDescriptors = []

        let center = NotificationCenter.default
        for name in [
            NSNotification.Name.NSMetadataQueryGatheringProgress,
            NSNotification.Name.NSMetadataQueryDidFinishGathering,
            NSNotification.Name.NSMetadataQueryDidUpdate,
        ] {
            let token = center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish() }
            }
            tokens.tokens.append(token)
        }
    }

    deinit {
        let center = NotificationCenter.default
        for token in tokens.tokens { center.removeObserver(token) }
    }

    /// Where Mail keeps downloaded messages.
    public static func mailDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Mail", directoryHint: .isDirectory)
    }

    /// False when Mail's storage cannot be read at all — the plain-language version of "Full Disk
    /// Access has not been granted".
    public var isIndexReadable: Bool {
        StoreAccess.canRead(directory: Self.mailDirectory(home: home))
    }

    public func stop() {
        query.stop()
    }

    public func search(_ text: String) {
        query.stop()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            onResults?([])
            return
        }

        query.predicate = Self.predicate(for: trimmed)
        query.searchScopes = [Self.mailDirectory(home: home)]
        query.start()
    }

    /// Subject and sender first, body text second — the same order of importance the results are
    /// shown in.
    public nonisolated static func predicate(for text: String) -> NSPredicate {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
        let wildcard = "*\(escaped)*"

        let terms = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemSubjectKey, wildcard),
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemAuthorsKey, wildcard),
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemRecipientsKey, wildcard),
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemTextContentKey, wildcard),
        ])

        // Restricted to mail messages, so a PDF sitting in the Mail folder cannot appear here.
        let isMail = NSPredicate(format: "%K == %@", NSMetadataItemContentTypeKey, "com.apple.mail.emlx")
        return NSCompoundPredicate(andPredicateWithSubpredicates: [isMail, terms])
    }

    private func publish() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var hits: [MailHit] = []
        hits.reserveCapacity(query.resultCount)

        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            hits.append(Self.hit(from: item, url: URL(filePath: path)))
        }

        // Newest first: mail is nearly always searched for the most recent time something
        // was said.
        onResults?(hits.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) })
    }

    private static func hit(from item: NSMetadataItem, url: URL) -> MailHit {
        let subject = (item.value(forAttribute: NSMetadataItemSubjectKey) as? String)
            ?? (item.value(forAttribute: NSMetadataItemTitleKey) as? String)
            ?? (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
            ?? "(no subject)"

        let authors = item.value(forAttribute: NSMetadataItemAuthorsKey) as? [String] ?? []
        let recipients = item.value(forAttribute: NSMetadataItemRecipientsKey) as? [String] ?? []

        let date = (item.value(forAttribute: NSMetadataItemContentCreationDateKey) as? Date)
            ?? (item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date)

        // No Foundation constant for this one; the raw Spotlight attribute name is stable.
        let attachments = item.value(forAttribute: "kMDItemAttachmentNames") as? [String] ?? []

        return MailHit(
            url: url,
            subject: subject,
            correspondents: authors.isEmpty ? recipients : authors,
            date: date,
            mailbox: MailHit.mailbox(from: url),
            messageID: item.value(forAttribute: NSMetadataItemIdentifierKey) as? String,
            hasAttachment: !attachments.isEmpty
        )
    }
}
