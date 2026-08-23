import Testing
import Foundation
@testable import ScoutCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func daysAgo(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }

private func file(_ path: String, modified: Date? = nil) -> SearchResult {
    let url = URL(filePath: path)
    return SearchResult(url: url, displayName: url.lastPathComponent, kind: .file, modified: modified)
}

private func folder(_ path: String, modified: Date? = nil) -> SearchResult {
    let url = URL(filePath: path)
    return SearchResult(url: url, displayName: url.lastPathComponent, kind: .folder, modified: modified)
}

@Suite struct FileKindTests {

    @Test func aPdfIsAPdfAndNotJustADocument() {
        // PDF conforms to composite content, so an order-of-checks mistake would file it wrongly.
        #expect(FileKind.of(file("/x/invoice.pdf")) == .pdf)
    }

    @Test func theCommonKindsAreRecognisedByExtension() {
        #expect(FileKind.of(file("/x/photo.jpg")) == .image)
        #expect(FileKind.of(file("/x/sheet.xlsx")) == .spreadsheet)
        #expect(FileKind.of(file("/x/deck.key")) == .presentation)
        #expect(FileKind.of(file("/x/notes.txt")) == .document)
        #expect(FileKind.of(file("/x/clip.mp4")) == .media)
        #expect(FileKind.of(file("/x/backup.zip")) == .archive)
        #expect(FileKind.of(folder("/x/Receipts")) == .folder)
    }
}

@Suite struct FileFilterTests {

    @Test func anEmptyFilterChangesNothing() {
        let results = [file("/a/one.pdf"), file("/b/two.jpg")]
        #expect(FileFilter().apply(to: results).count == 2)
    }

    @Test func aKindFilterIsAWallNotAPreference() {
        // The whole point: what fails the filter is gone, not merely ranked lower.
        let results = [file("/a/one.pdf"), file("/b/two.jpg")]
        var filter = FileFilter()
        filter.toggle(kind: .pdf)
        #expect(filter.apply(to: results).map(\.displayName) == ["one.pdf"])
    }

    @Test func severalKindsAreAnOrNotAnAnd() {
        let results = [file("/a/one.pdf"), file("/b/two.jpg"), file("/c/three.txt")]
        var filter = FileFilter()
        filter.toggle(kind: .pdf)
        filter.toggle(kind: .image)
        #expect(filter.apply(to: results).count == 2)
    }

    @Test func aFolderFilterKeepsOnlyWhatIsInside() {
        let results = [file("/Users/t/Documents/Ford/a.pdf"), file("/Users/t/Documents/BMW/b.pdf")]
        var filter = FileFilter()
        filter.toggle(folder: URL(filePath: "/Users/t/Documents/Ford"))
        #expect(filter.apply(to: results).map(\.displayName) == ["a.pdf"])
    }

    @Test func aSimilarlyNamedSiblingFolderIsNotInside() {
        // "/Ford" must not swallow "/Ford F350 Old" through a bare prefix comparison.
        let results = [file("/Users/t/Ford F350 Old/a.pdf")]
        var filter = FileFilter()
        filter.toggle(folder: URL(filePath: "/Users/t/Ford"))
        #expect(filter.apply(to: results).isEmpty)
    }

    @Test func aDateWindowDropsAnythingOlder() {
        let results = [file("/a/new.pdf", modified: daysAgo(2)), file("/a/old.pdf", modified: daysAgo(400))]
        var filter = FileFilter()
        filter.toggle(window: .thisMonth)
        #expect(filter.apply(to: results, now: now).map(\.displayName) == ["new.pdf"])
    }

    @Test func tappingTheSameChipTwiceTurnsItOff() {
        var filter = FileFilter()
        filter.toggle(kind: .pdf)
        filter.toggle(kind: .pdf)
        #expect(filter.isEmpty)
    }
}

@Suite struct FilterSuggestionTests {

    @Test func onlyFoldersHoldingMoreThanOneMatchAreOffered() {
        // Narrowing to a folder with one result in it is the same as clicking the result.
        let results = [
            file("/Users/t/Documents/Ford/a.pdf"),
            file("/Users/t/Documents/Ford/b.pdf"),
            file("/Users/t/Documents/Alone/c.pdf"),
        ]
        let suggestions = FilterSuggestions.from(results, now: now)
        #expect(suggestions.folders.map(\.name) == ["Ford"])
        #expect(suggestions.folders.first?.count == 2)
    }

    @Test func onlyKindsActuallyPresentAreOffered() {
        let suggestions = FilterSuggestions.from([file("/a/one.pdf"), folder("/a/Two")], now: now)
        #expect(suggestions.kinds.contains(.pdf))
        #expect(suggestions.kinds.contains(.folder))
        #expect(!suggestions.kinds.contains(.presentation))
    }

    @Test func dateWindowsThatWouldMatchNothingAreNotOffered() {
        let suggestions = FilterSuggestions.from([file("/a/old.pdf", modified: daysAgo(400))], now: now)
        #expect(suggestions.windows.isEmpty)
    }

    @Test func folderChipsAreOrderedByHowMuchTheyWouldNarrow() {
        let results =
            (1...3).map { file("/Users/t/Big/\($0).pdf") } +
            (1...2).map { file("/Users/t/Small/\($0).pdf") }
        let suggestions = FilterSuggestions.from(results, now: now)
        #expect(suggestions.folders.map(\.name) == ["Big", "Small"])
    }
}

@Suite struct SettingsPaneTests {

    @Test func onlyRealPanesPassTheNameCheck() {
        #expect(SettingsPaneIndex.isSettingsPane("com.apple.Keyboard-Settings.extension"))
        #expect(SettingsPaneIndex.isSettingsPane("com.apple.BluetoothSettings"))
        #expect(!SettingsPaneIndex.isSettingsPane("com.apple.Profiles-Settings.intents"))
        #expect(!SettingsPaneIndex.isSettingsPane("com.apple.AccessibilitySettingsWidgetExtension"))
    }

    @Test func keywordsFindPanesThatDoNotSayTheWord() {
        // "full disk access" is the thing people search for; the pane is called something else.
        let index = SettingsPaneIndex(panes: SettingsPaneIndex.builtIn)
        #expect(index.matches(for: "full disk access").first?.name == "Privacy & Security")
    }

    @Test func nameMatchesComeBeforeKeywordMatches() {
        let index = SettingsPaneIndex(panes: [
            .init(identifier: "a", name: "Network"),
            .init(identifier: "b", name: "Wi-Fi", keywords: ["network"]),
        ])
        #expect(index.matches(for: "network").map(\.name) == ["Network", "Wi-Fi"])
    }

    @Test func aPaneOpensThroughTheSystemSettingsScheme() {
        let pane = SettingsPaneIndex.Pane(identifier: "com.apple.Keyboard-Settings.extension", name: "Keyboard")
        #expect(pane.url?.absoluteString == "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }
}

@Suite struct AppOrderingTests {

    private let index = AppIndex(entries: [
        .init(url: URL(filePath: "/Applications/Mail.app"), name: "Mail", lastUsed: daysAgo(1)),
        .init(url: URL(filePath: "/Applications/Mailbutler.app"), name: "Mailbutler", lastUsed: daysAgo(200)),
        .init(url: URL(filePath: "/Applications/Gmail Helper.app"), name: "Gmail Helper", lastUsed: daysAgo(3)),
    ])

    @Test func theBestNameMatchLeadsTheAppsLane() {
        #expect(index.matches(for: "mail").map(\.name) == ["Mail", "Mailbutler", "Gmail Helper"])
    }

    @Test func anEmptyQueryShowsWhatYouActuallyUse() {
        #expect(index.matches(for: "").map(\.name) == ["Mail", "Gmail Helper", "Mailbutler"])
    }
}

@Suite struct ContactHitTests {

    @Test func theDetailLineLeadsWithHowYouWouldReachThem() {
        let hit = ContactHit(
            identifier: "ABC",
            name: "Jose Ramirez",
            organization: "Capitol Ford",
            phone: "+1 916-555-0142",
            email: "jose@example.com"
        )
        #expect(hit.detail == "+1 916-555-0142 · jose@example.com · Capitol Ford")
    }

    @Test func aContactWithNothingButANameSaysNothingElse() {
        let hit = ContactHit(identifier: "ABC", name: "Jose", organization: nil, phone: nil, email: nil)
        #expect(hit.detail.isEmpty)
    }

    @Test func aCardOpensInContacts() {
        let hit = ContactHit(identifier: "ABC-123", name: "Jose", organization: nil, phone: nil, email: nil)
        #expect(hit.openURL?.absoluteString == "addressbook://ABC-123")
    }
}

@Suite struct LaneTests {

    @Test func everyLaneHasItsOwnNumber() {
        #expect(SearchLane.allCases.map(\.defaultShortcut) == ["1", "2", "3", "4", "5", "6", "7", "8"])
    }

    /// The first six numbers are muscle memory for anyone who never reorders. Notes and Reminders
    /// were added at the end so ⌘5 still means Apps — this test is what stops a tidy-minded
    /// reordering of the enum from quietly breaking that for everyone.
    @Test func theOriginalSixKeepTheirNumbersByDefault() {
        #expect(SearchLane.files.defaultShortcut == "1")
        #expect(SearchLane.contacts.defaultShortcut == "2")
        #expect(SearchLane.mail.defaultShortcut == "3")
        #expect(SearchLane.messages.defaultShortcut == "4")
        #expect(SearchLane.apps.defaultShortcut == "5")
        #expect(SearchLane.system.defaultShortcut == "6")
        #expect(SearchLane.notes.defaultShortcut == "7")
        #expect(SearchLane.reminders.defaultShortcut == "8")
    }

    @Test func asavedOrderIsHonouredExactly() {
        let saved = ["notes", "files", "mail"]
        let ordered = SearchLane.ordered(from: saved)
        #expect(ordered.prefix(3) == [.notes, .files, .mail])
    }

    @Test func aSourceAddedLaterArrivesAtTheEndOfYourOwnOrder() {
        // The whole set, arranged by hand, from a version that had no Reminders.
        let saved = ["notes", "files", "mail", "messages", "apps", "system", "contacts"]
        #expect(SearchLane.ordered(from: saved).last == .reminders)
        #expect(SearchLane.ordered(from: saved).count == SearchLane.allCases.count)
    }

    @Test func nonsenseInTheSavedOrderIsIgnoredRatherThanLosingASource() {
        #expect(SearchLane.ordered(from: ["telepathy", "files", "files"]).count == SearchLane.allCases.count)
        #expect(SearchLane.ordered(from: []).first == .files)
    }

    @Test func onlyFilesHasScopes() {
        #expect(SearchLane.files.hasScopes)
        #expect(!SearchLane.contacts.hasScopes)
        #expect(!SearchLane.mail.hasScopes)
    }
}

@Suite struct ContactIndexTests {

    private func contact(_ name: String, organization: String? = nil, phone: String? = nil, email: String? = nil) -> ContactRecord {
        let hit = ContactHit(identifier: name, name: name, organization: organization, phone: phone, email: email)
        return ContactRecord(
            hit: hit,
            searchable: [name, organization, phone, email].compactMap(\.self),
            phoneDigits: [(phone ?? "").filter(\.isNumber)].filter { !$0.isEmpty },
            nameFields: [name],
            workFields: [organization].compactMap(\.self)
        )
    }

    private var index: ContactIndex {
        ContactIndex(records: [
            contact("Hernandez Jose", organization: "EFR 112 EMT-B"),
            contact("Sabutis Joseph"),
            contact("Joseph 72 Colinas", phone: "1 (505) 652-2909"),
            contact("Johnson Derek", organization: "Presbyterian general Surgery"),
            contact("Joyce David"),
            contact("Bauer Joan", email: "bauerjoan@mac.com"),
            contact("JLC Plumbing", email: "jose@jlcplumbing.com"),
        ])
    }

    @Test func onlyNamesThatActuallyContainTheQueryComeBack() {
        // Apple's own name predicate returned Joan, John and Joyce for "Jose" — it matches names
        // that merely sound alike — while missing the actual Joses.
        let names = index.search("Jose").items.map(\.name)
        #expect(names.contains("Hernandez Jose"))
        #expect(names.contains("Sabutis Joseph"))
        #expect(!names.contains("Bauer Joan"))
        #expect(!names.contains("Johnson Derek"))
        #expect(!names.contains("Joyce David"))
    }

    @Test func namesLeadOverEverythingElse() {
        // Both Joses match a whole word of their name, so they tie and sort by name — either
        // order is right, but they both belong above a company or an address match.
        let top = index.search("Jose").items.prefix(2).map(\.name)
        #expect(top.contains("Hernandez Jose"))
        #expect(top.contains("Joseph 72 Colinas"))
    }

    @Test func anEmailAddressCountsButRanksBelowANameOrCompany() {
        // JLC Plumbing here only matches through its address, so it comes last.
        #expect(index.search("Jose").items.map(\.name).last == "JLC Plumbing")
    }

    @Test func aPhoneNumberTypedTheWayPeopleTypeItStillMatches() {
        // Spaces, dashes and brackets are how anyone would type part of a number.
        let index = ContactIndex(records: [contact("Joseph 72 Colinas", phone: "1 (505) 652-2909")])
        #expect(index.search("505 652").items.count == 1)
        #expect(index.search("505-652").items.count == 1)
        #expect(index.search("6522909").items.count == 1)
    }

    @Test func aNumberInTheTextIsStillFoundByText() {
        // A postcode is digits, but it lives in an address, not a phone number.
        let record = ContactRecord(
            hit: ContactHit(identifier: "A", name: "Ann Reed", organization: nil, phone: "(212) 555-0100", email: nil),
            searchable: ["Ann Reed", "12 Vine St Santa Fe NM 87501"],
            phoneDigits: ["2125550100"],
            nameFields: ["Ann", "Reed"]
        )
        #expect(ContactIndex(records: [record]).search("87501").items.count == 1)
    }

    @Test func aCardWithNoNameDoesNotFloatToTheTop() {
        // "No name" is a placeholder Scout writes, not something anyone is called.
        let nameless = ContactRecord(
            hit: ContactHit(identifier: "X", name: "No name", organization: nil,
                            phone: nil, email: "noreply@school.edu"),
            searchable: ["noreply@school.edu"],
            phoneDigits: []
        )
        let index = ContactIndex(records: [nameless, contact("Nora Vance")])
        #expect(index.search("no").items.first?.name == "Nora Vance")
    }

    @Test func aStreetNameIsNotRankedAsAPersonsName() {
        let street = ContactRecord(
            hit: ContactHit(identifier: "A", name: "Aaron Fox", organization: nil, phone: nil, email: nil),
            searchable: ["Aaron", "Fox", "5 Brewster Ave"],
            phoneDigits: [],
            nameFields: ["Aaron", "Fox"]
        )
        let employer = ContactRecord(
            hit: ContactHit(identifier: "D", name: "Dana West", organization: "Ironbrew Coffee", phone: nil, email: nil),
            searchable: ["Dana", "West", "Ironbrew Coffee"],
            phoneDigits: [],
            nameFields: ["Dana", "West"],
            workFields: ["Ironbrew Coffee"]
        )
        #expect(ContactIndex(records: [street, employer]).search("brew").items.first?.name == "Dana West")
    }

    @Test func aCompanyIsSearchableToo() {
        #expect(index.search("presbyterian").items.map(\.name) == ["Johnson Derek"])
    }

    @Test func partOfAPhoneNumberFindsThePerson() {
        // Typed without punctuation, the way anyone would remember the last few digits.
        #expect(index.search("6522909").items.map(\.name) == ["Joseph 72 Colinas"])
    }

    @Test func oneLetterIsNotASearch() {
        #expect(index.search("J").items.isEmpty)
    }

    @Test func aCompanyCardIsFoundByThePersonsNameOnIt() {
        // "JLC Plumbing" is filed under the company but has Jose in the first-name field.
        // Contacts finds it for "Jose"; Scout was missing it because it only searched the name
        // it displays.
        let record = ContactRecord(
            hit: ContactHit(identifier: "JLC", name: "JLC Plumbing", organization: "JLC Plumbing",
                            phone: "(505) 795-6188", email: nil),
            searchable: ["Jose", "JLC Plumbing", "(505) 795-6188"],
            phoneDigits: ["5057956188"],
            nameFields: ["Jose"],
            workFields: ["JLC Plumbing"]
        )
        let index = ContactIndex(records: [record])
        #expect(index.search("Jose").items.map(\.name) == ["JLC Plumbing"])
    }

    @Test func aPageSaysHowManyThereWereAltogether() {
        let many = (1...30).map { contact("Jose \($0)") }
        let page = ContactIndex(records: many).search("Jose", limit: 5)
        #expect(page.items.count == 5)
        #expect(page.total == 30)
        #expect(page.hiddenCount == 25)
    }

    @Test func accentsAndCaseDoNotMatter() {
        let index = ContactIndex(records: [contact("José Ramírez")])
        #expect(index.search("jose").items.count == 1)
    }
}
