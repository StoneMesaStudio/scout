import Foundation
import ScoutCore

/// Invented results, for screenshots.
///
/// The alternative was to photograph the panel searching John's actual Mac, which would put real
/// mail subjects, real correspondents and real file paths on a public web page. Nothing here
/// exists: the people, the addresses, the messages and the files are all made up, and the app
/// reads nothing at all while it is drawing them.
enum DemoData {

    static let query = "insurance"

    private static let now = Date(timeIntervalSince1970: 1_787_000_000)
    private static func daysAgo(_ days: Int) -> Date { now.addingTimeInterval(-86_400 * Double(days)) }

    /// Under the real home folder, so the breadcrumb reads "Documents › Household › Insurance"
    /// the way it will on anybody's Mac. The folders do not exist; only the shape of the path is
    /// borrowed.
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static func files() -> [SearchResult] {
        [
            ("Insurance", "Documents/Household", 61, "public.folder"),
            ("Insurance Policy 2026.pdf", "Documents/Household/Insurance", 12, "com.adobe.pdf"),
            ("Home Insurance Inventory.csv", "Documents/Household/Insurance", 61, "public.comma-separated-values-text"),
            ("Umbrella Insurance Summary.pages", "Documents/Household/Insurance", 240, "com.apple.iwork.pages.sffpages"),
        ].map { name, folder, days, type in
            SearchResult(
                url: home.appending(path: "\(folder)/\(name)"),
                displayName: name,
                kind: type == "public.folder" ? .folder : .file,
                contentType: type,
                modified: daysAgo(days)
            )
        }
    }

    static func mail() -> [MailHit] {
        [
            ("Your policy renewal is ready", "Meridian Mutual", 3, "INBOX", true),
            ("Re: Insurance question — flood rider", "Dana Whitlock", 9, "INBOX", false),
            ("Insurance documents attached", "Dana Whitlock", 14, "Archive", false),
        ].enumerated().map { index, item in
            MailHit(rowID: Int64(index + 1), subject: item.0, sender: item.1,
                    senderAddress: nil, date: daysAgo(item.2), mailbox: item.3,
                    messageID: nil, isUnread: item.4)
        }
    }

    static func notes() -> [NoteHit] {
        [
            ("Insurance", "Household", 6, "policy 4471 · renews in March · agent Dana Whitlock"),
            ("House jobs", "Household", 21, "…gutters, chimney, and ask about the insurance rider…"),
            ("Truck", "Vehicles", 130, "…insurance card in the glovebox, registration in the folder…"),
        ].enumerated().map { index, item in
            NoteHit(rowID: Int64(index + 1), identifier: UUID().uuidString, title: item.0,
                    folder: item.1, account: "iCloud", modified: daysAgo(item.2), snippet: item.3)
        }
    }

    static func reminders() -> [ReminderHit] {
        [
            ("Call about the insurance renewal", "Household", -2, false),
            ("Photograph the shed for the insurance inventory", "Household", 5, false),
            ("Send insurance the roof invoice", "Household", 30, true),
        ].enumerated().map { index, item in
            ReminderHit(identifier: UUID().uuidString, title: item.0, list: item.1,
                        due: daysAgo(item.2), isCompleted: item.3, note: nil)
        }
    }

    static func contacts() -> [ContactHit] {
        [
            ContactHit(identifier: "demo-1", name: "Dana Whitlock",
                       organization: "Meridian Mutual Insurance", phone: "(505) 555-0142",
                       email: "d.whitlock@example.com"),
        ]
    }
}
