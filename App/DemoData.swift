import Foundation
import ScoutCore

/// Invented results, for screenshots.
///
/// The alternative was to photograph the panel searching John's actual Mac, which would put real
/// mail subjects, real correspondents and real file paths on a public web page. Nothing here
/// exists: the people, the addresses, the messages and the files are all made up, and the app
/// reads nothing at all while it is drawing them.
///
/// Two things are *not* invented, on purpose. The Apps and System sections read the real
/// `AppIndex` and `SettingsPaneIndex`, because what is in `/Applications` is not private and a
/// faked app row would show an icon no one has. And the excluded-match count in `filters` is a
/// real count: those rows sit under a `node_modules` path, and `Exclusions` removes them for the
/// same reason it removes them on anybody's Mac.
enum DemoData {

    /// One picture. Each scene says a different thing about the app, which is the only reason for
    /// there to be more than one of them.
    enum Scene: String, CaseIterable {
        /// Everything at once: five sources answering one word, each in its own band.
        case sections
        /// A person, their mail and their texts — three sources, five switched off.
        case person
        /// One source opened out on its own from its heading.
        case solo
        /// A filter that actually removes things, and the count of what the exclusions took.
        case filters
        /// What is inside the notes and the reminders, which is the thing nothing else on a Mac
        /// will search.
        case notes
        /// The two sources that read the real Mac rather than invented data. Not on the website —
        /// it is here so a word can be tried against the app and settings indexes and looked at.
        case apps
    }

    /// What the panel is set to before the shutter opens.
    struct Setup {
        var query: String
        var lanes: Set<SearchLane>
        var solo: SearchLane?
        var scope: SearchScope = .myFiles
        var filter = FileFilter()
        var files: [SearchResult] = []
        var mail: [MailHit] = []
        var messages: [MessageHit] = []
        var notes: [NoteHit] = []
        var reminders: [ReminderHit] = []
        var contacts: [ContactHit] = []
        /// How many each source matched altogether. Larger than what is shown, because "3 of 62"
        /// is the part of the design worth photographing — a bare 3 looks like all there is.
        var totals: [SearchLane: Int] = [:]
    }

    // A fixed clock, so re-shooting a year from now does not silently change every date on the
    // website to something a year staler.
    private static let now = Date(timeIntervalSince1970: 1_787_000_000)
    private static func daysAgo(_ days: Int) -> Date { now.addingTimeInterval(-86_400 * Double(days)) }

    /// Under the real home folder, so the breadcrumb reads "Documents › Household › Insurance"
    /// the way it will on anybody's Mac. The folders do not exist; only the shape of the path is
    /// borrowed.
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static func setup(for scene: Scene, query override: String? = nil) -> Setup {
        var setup = built(for: scene)
        if let override, !override.isEmpty { setup.query = override }
        return setup
    }

    private static func built(for scene: Scene) -> Setup {
        switch scene {
        case .sections:
            // Two or three rows a source rather than the ten the cap allows. Five bands is the
            // whole point of the picture, and at ten rows each the fifth is a screen and a half
            // below the first.
            Setup(
                query: "insurance",
                lanes: Set(SearchLane.allCases),
                solo: nil,
                files: Array(insuranceFiles().prefix(3)),
                mail: Array(insuranceMail().prefix(2)),
                notes: Array(notes().prefix(2)),
                reminders: Array(reminders().prefix(2)),
                contacts: [dana],
                totals: [.contacts: 1, .mail: 62, .notes: 41, .reminders: 17]
            )

        case .person:
            Setup(
                query: "dana",
                lanes: [.contacts, .mail, .messages],
                solo: nil,
                mail: danaMail(),
                messages: danaMessages(),
                contacts: [dana],
                totals: [.contacts: 1, .mail: 24, .messages: 310]
            )

        case .solo:
            Setup(
                query: "insurance",
                lanes: [.mail],
                solo: .mail,
                mail: insuranceMail(),
                totals: [.mail: 62]
            )

        case .filters:
            Setup(
                query: "insurance",
                lanes: [.files],
                solo: nil,
                scope: .wholeMac,
                filter: FileFilter(kinds: [.pdf]),
                files: insuranceFiles() + pdfFiles() + excludedFiles()
            )

        case .notes:
            Setup(
                query: "insurance",
                lanes: [.notes, .reminders],
                solo: nil,
                notes: allNotes(),
                reminders: allReminders(),
                totals: [.notes: 41, .reminders: 17]
            )

        case .apps:
            // No invented files here on purpose: these two sources read the real Mac, and a file
            // list that ignored the word being typed would be the one dishonest thing in the set.
            Setup(
                query: "sound",
                lanes: [.apps, .system],
                solo: nil
            )
        }
    }

    // MARK: - Files

    private static func file(
        _ name: String, _ folder: String, _ days: Int, _ type: String
    ) -> SearchResult {
        SearchResult(
            url: home.appending(path: "\(folder)/\(name)"),
            displayName: name,
            kind: type == "public.folder" ? .folder : .file,
            contentType: type,
            modified: daysAgo(days)
        )
    }

    private static let pdf = "com.adobe.pdf"

    private static func insuranceFiles() -> [SearchResult] {
        [
            file("Insurance", "Documents/Household", 61, "public.folder"),
            file("Insurance Policy 2026.pdf", "Documents/Household/Insurance", 12, pdf),
            file("Home Insurance Inventory.csv", "Documents/Household/Insurance", 61,
                 "public.comma-separated-values-text"),
            file("Umbrella Insurance Summary.pages", "Documents/Household/Insurance", 240,
                 "com.apple.iwork.pages.sffpages"),
        ]
    }

    /// Enough PDFs that narrowing to PDFs is worth photographing. A filter demonstrated on one
    /// surviving row does not look like a filter.
    private static func pdfFiles() -> [SearchResult] {
        [
            file("Auto Insurance Card.pdf", "Documents/Household/Insurance", 34, pdf),
            file("Flood Rider Insurance.pdf", "Documents/Household/Insurance", 78, pdf),
            file("Insurance Claim — Hail 2025.pdf", "Documents/Household/Insurance", 149, pdf),
            file("Renters Insurance (old).pdf", "Documents/Archive", 402, pdf),
        ]
    }

    /// Rows the exclusions genuinely remove, so the count in the notice is counted rather than
    /// written down.
    private static func excludedFiles() -> [SearchResult] {
        (1...37).map { index in
            file("insurance-form.tsx", "Developer/quotes/node_modules/@forms/pack-\(index)", 90,
                 "public.source-code")
        }
    }

    private static func mailFiles() -> [SearchResult] {
        [
            file("Mail merge — renewal notices.numbers", "Documents/Work", 4,
                 "com.apple.iwork.numbers.sffnumbers"),
            file("Mailing list 2026.csv", "Documents/Work", 19,
                 "public.comma-separated-values-text"),
            file("Mail archive.zip", "Downloads", 96, "public.zip-archive"),
        ]
    }

    // MARK: - Mail

    private static func insuranceMail() -> [MailHit] {
        [
            ("Your policy renewal is ready", "Meridian Mutual", 3, "INBOX", true),
            ("Re: Insurance question — flood rider", "Dana Whitlock", 9, "INBOX", false),
            ("Insurance documents attached", "Dana Whitlock", 14, "Archive", false),
            ("Insurance premium — autopay confirmation", "Meridian Mutual", 21, "INBOX", false),
            ("Fwd: Umbrella insurance quote", "Rae Okonjo", 26, "Archive", false),
            ("Your insurance card is enclosed", "Meridian Mutual", 39, "Archive", false),
            ("Re: Insurance — roof inspection date", "Dana Whitlock", 44, "Archive", false),
            ("Insurance inventory — photos received", "Meridian Mutual", 58, "Archive", false),
            ("Renewal packet: home insurance 2026", "Meridian Mutual", 67, "Archive", false),
            ("Insurance claim 4471 — closed", "Claims Center", 81, "Archive", false),
            ("Re: Adding the truck to the insurance", "Dana Whitlock", 96, "Archive", false),
            ("Insurance discount — bundled policies", "Meridian Mutual", 118, "Archive", false),
        ].enumerated().map { index, item in
            MailHit(rowID: Int64(index + 1), subject: item.0, sender: item.1,
                    senderAddress: nil, date: daysAgo(item.2), mailbox: item.3,
                    messageID: nil, isUnread: item.4)
        }
    }

    private static func danaMail() -> [MailHit] {
        [
            ("Re: Insurance question — flood rider", "Dana Whitlock", 9, "INBOX", true),
            ("Insurance documents attached", "Dana Whitlock", 14, "Archive", false),
            ("Re: Insurance — roof inspection date", "Dana Whitlock", 44, "Archive", false),
            ("Dana Whitlock shared “Policy 4471”", "Meridian Mutual", 52, "INBOX", false),
        ].enumerated().map { index, item in
            MailHit(rowID: Int64(index + 1), subject: item.0, sender: item.1,
                    senderAddress: nil, date: daysAgo(item.2), mailbox: item.3,
                    messageID: nil, isUnread: item.4)
        }
    }

    // MARK: - Messages

    private static func danaMessages() -> [MessageHit] {
        [
            ("The adjuster can come Thursday morning if that works", 2, false, "Dana Whitlock"),
            ("Dana — does the shed count as a structure?", 5, true, "Dana Whitlock"),
            ("Sending the new card over now", 11, false, "Dana Whitlock"),
            ("told Dana we'd take the higher deductible", 30, true, "Rae Okonjo"),
            ("Dana's office moved — it's on Marquette now", 74, false, "Rae Okonjo"),
        ].enumerated().map { index, item in
            MessageHit(rowID: Int64(index + 1), text: item.0, date: daysAgo(item.1),
                       isFromMe: item.2, counterpart: item.3,
                       chatIdentifier: nil, hasAttachment: false)
        }
    }

    // MARK: - The rest

    /// Most of these match on the body rather than the title, which is the whole point: a note
    /// called "House jobs" is the one that mentions the rider.
    private static func allNotes() -> [NoteHit] {
        [
            ("Insurance", "Household", 6, "policy 4471 · renews in March · agent Dana Whitlock"),
            ("House jobs", "Household", 21, "…gutters, chimney, and ask about the insurance rider…"),
            ("Truck", "Vehicles", 130, "…insurance card in the glovebox, registration in the folder…"),
            ("Shed inventory", "Household", 34, "…mower, ladders, the good tools — for the insurance list…"),
            ("Moving day", "Archive", 88, "…transfer the insurance the week before, not the day of…"),
            ("Boat", "Vehicles", 151, "…insurance is seasonal, cancel it in October…"),
            ("Questions for Rae", "Work", 205, "…whether the studio insurance covers equipment off-site…"),
        ].enumerated().map { index, item in
            NoteHit(rowID: Int64(index + 1), identifier: UUID().uuidString, title: item.0,
                    folder: item.1, account: "iCloud", modified: daysAgo(item.2), snippet: item.3)
        }
    }

    private static func notes() -> [NoteHit] { Array(allNotes().prefix(3)) }

    /// Outstanding ones first — 99% of a real reminders list is finished, so sorting by date
    /// alone would bury everything anybody is looking for.
    private static func allReminders() -> [ReminderHit] {
        [
            ("Call about the insurance renewal", "Household", -2, false),
            ("Photograph the shed for the insurance inventory", "Household", 5, false),
            ("Ask Dana about insurance for the trailer", "Household", 12, false),
            ("Send insurance the roof invoice", "Household", 30, true),
            ("Cancel the boat insurance for the winter", "Vehicles", 61, true),
            ("Insurance: add the new laptop to the schedule", "Work", 119, true),
        ].enumerated().map { index, item in
            ReminderHit(identifier: UUID().uuidString, title: item.0, list: item.1,
                        due: daysAgo(item.2), isCompleted: item.3, note: nil)
        }
    }

    private static func reminders() -> [ReminderHit] { Array(allReminders().prefix(3)) }

    private static let dana = ContactHit(
        identifier: "demo-1", name: "Dana Whitlock",
        organization: "Meridian Mutual Insurance", phone: "(505) 555-0142",
        email: "d.whitlock@example.com"
    )
}
