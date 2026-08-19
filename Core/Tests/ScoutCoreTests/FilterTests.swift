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
        #expect(SearchLane.allCases.map(\.shortcut) == ["1", "2", "3", "4", "5", "6"])
    }

    @Test func onlyFilesHasScopes() {
        #expect(SearchLane.files.hasScopes)
        #expect(!SearchLane.contacts.hasScopes)
        #expect(!SearchLane.mail.hasScopes)
    }
}
