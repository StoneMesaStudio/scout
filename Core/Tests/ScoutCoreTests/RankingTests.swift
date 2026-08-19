import Testing
import Foundation
@testable import ScoutCore

// The fixed clock and fake home keep every expectation here reproducible on any Mac.
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let home = URL(filePath: "/Users/tester")

private func daysAgo(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }

private func result(
    _ path: String,
    name: String? = nil,
    kind: SearchResult.Kind = .file,
    modified: Date? = nil,
    lastUsed: Date? = nil,
    size: Int64? = nil
) -> SearchResult {
    let url = URL(filePath: path)
    return SearchResult(
        url: url,
        displayName: name ?? url.lastPathComponent,
        kind: kind,
        modified: modified,
        lastUsed: lastUsed,
        size: size
    )
}

@Suite struct NameMatchTests {

    @Test func exactNameBeatsEverythingElse() {
        #expect(NameMatch.classify(name: "Service", query: "service") == .exact)
        #expect(NameMatch.classify(name: "Service.pdf", query: "service") == .exact)
    }

    @Test func aWordInsideTheNameOutranksALooseSubstring() {
        // The distinction that puts real records above library noise.
        #expect(NameMatch.classify(name: "Ford F350 Service Receipts", query: "service") == .wordExact)
        #expect(NameMatch.classify(name: "webservices.log", query: "service") == .substring)
        #expect(NameMatch.classify(name: "Ford F350 Service Receipts", query: "service")
                > NameMatch.classify(name: "webservices.log", query: "service"))
    }

    @Test func awholeWordBeatsAWordThatMerelyStartsWithIt() {
        #expect(NameMatch.classify(name: "2023 Warranty.pdf", query: "warranty")
                > NameMatch.classify(name: "Warranties and receipts", query: "warranty"))
    }

    @Test func anApostropheDoesNotHideAWord() {
        // "Traveler's Insurance CAT.pdf" must match "insurance" as a whole word.
        #expect(NameMatch.classify(name: "Traveler's Insurance CAT.pdf", query: "insurance") == .wordExact)
    }

    @Test func aNameThatDoesNotContainTheQueryIsAContentMatch() {
        #expect(NameMatch.classify(name: "warranty booklet.pdf", query: "service") == .contentOnly)
    }

    @Test func caseAndAccentsDoNotMatter() {
        #expect(NameMatch.classify(name: "SÉRVICE", query: "service") == .exact)
    }
}

@Suite struct RankerTests {

    private let ranker = Ranker(home: home)

    @Test func theRealServiceRecordsBeatTheDeveloperJunk() {
        // The search that started the app: "service" used to return three copies of a
        // node_modules folder before it returned the actual vehicle records.
        let records = result(
            "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/Vehicles/Ford F350/Service Receipts",
            kind: .folder,
            modified: daysAgo(1)
        )
        let junk = result(
            "/Users/tester/Sites/app/node_modules/@sveltejs/adapter/service-worker",
            kind: .folder,
            modified: daysAgo(44)
        )

        #expect(ranker.score(records, query: "service", now: now)
                > ranker.score(junk, query: "service", now: now))
    }

    @Test func aPerfectMatchInACacheStillLosesToAGoodOneInDocuments() {
        // Location is a multiplier, not a bonus — this is the case it exists for.
        let cached = result("/Users/tester/Library/Caches/whatever/service", kind: .folder, modified: daysAgo(1))
        let real = result("/Users/tester/Documents/Home/Generator service log.numbers", modified: daysAgo(1))

        #expect(ranker.score(real, query: "service", now: now)
                > ranker.score(cached, query: "service", now: now))
    }

    @Test func recentlyTouchedOutranksAnAncientTwin() {
        let fresh = result("/Users/tester/Documents/Service Notes.txt", modified: daysAgo(2))
        let stale = result("/Users/tester/Documents/Archive/Service Notes.txt", modified: daysAgo(2_000))

        #expect(ranker.score(fresh, query: "service", now: now)
                > ranker.score(stale, query: "service", now: now))
    }

    @Test func somethingThePersonActuallyOpenedGetsCredit() {
        let opened = result("/Users/tester/Documents/A/Service.pdf", modified: daysAgo(30), lastUsed: daysAgo(3))
        let untouched = result("/Users/tester/Documents/A/Service.pdf".replacingOccurrences(of: "/A/", with: "/B/"), modified: daysAgo(30))

        #expect(ranker.score(opened, query: "service", now: now)
                > ranker.score(untouched, query: "service", now: now))
    }

    @Test func aPickedResultClimbsAboveEverything() {
        let picked = result("/Users/tester/Documents/Old/service memo.txt", modified: daysAgo(900))
        let otherwiseBetter = result("/Users/tester/Documents/Service.pdf", modified: daysAgo(1))

        let ranked = ranker.rank(
            [otherwiseBetter, picked],
            query: "service",
            now: now,
            learnedPicks: [picked.url]
        )
        #expect(ranked.first?.url == picked.url)
    }

    @Test func identicalCopiesCollapseIntoOneRow() {
        let copies = (1...3).map {
            result("/Users/tester/Sites/p\($0)/service-worker", kind: .folder, modified: daysAgo(44), size: 4_096)
        }
        let ranked = ranker.rank(copies, query: "service", now: now)

        #expect(ranked.count == 1)
        #expect(ranked[0].duplicateCount == 3)
        #expect(ranked[0].duplicates.count == 2)
    }

    @Test func filesThatOnlyShareANameStaySeparate() {
        let a = result("/Users/tester/Documents/one/notes.txt", size: 10)
        let b = result("/Users/tester/Documents/two/notes.txt", size: 999)

        #expect(ranker.rank([a, b], query: "notes", now: now).count == 2)
    }

    @Test func equallyGoodMatchesComeBackNewestFirst() {
        // Folders of date-prefixed receipts used to come back oldest-first, because ties were
        // broken on the filename and the filename starts with the date.
        let items = [
            result("/Users/tester/Documents/2010-08-15 Budget Water.pdf", modified: daysAgo(4_000)),
            result("/Users/tester/Documents/2024-07-12 Budget Water.pdf", modified: daysAgo(400)),
        ]
        #expect(ranker.rank(items, query: "budget", now: now).first?.displayName
                == "2024-07-12 Budget Water.pdf")
    }

    @Test func beingRecentCannotPromoteAWorseMatch() {
        // Recency reorders equally good matches; it must never lift a substring match above a
        // whole-word one.
        let better = result("/Users/tester/Documents/Service Records.pdf", modified: daysAgo(3_000))
        let worse = result("/Users/tester/Documents/webservices.log", modified: daysAgo(0))
        #expect(ranker.score(better, query: "service", now: now)
                > ranker.score(worse, query: "service", now: now))
    }

    @Test func orderIsStableAcrossIdenticalSearches() {
        let items = [
            result("/Users/tester/Documents/service a.txt", modified: daysAgo(5)),
            result("/Users/tester/Documents/service b.txt", modified: daysAgo(5)),
        ]
        #expect(ranker.rank(items, query: "service", now: now).map(\.displayName)
                == ranker.rank(items.reversed(), query: "service", now: now).map(\.displayName))
    }
}

@Suite struct FilenameDateTests {

    @Test func aLeadingIsoDateIsRecognised() {
        #expect(Ranker.leadingDate(in: "2024-07-12 NK Home - Invoice.pdf") == "2024-07-12")
    }

    @Test func anythingElseIsNotADate() {
        #expect(Ranker.leadingDate(in: "2024 receipts.pdf") == nil)
        #expect(Ranker.leadingDate(in: "Invoice 2024-07-12.pdf") == nil)
        #expect(Ranker.leadingDate(in: "short.pdf") == nil)
    }

    @Test func batchCopiedReceiptsComeBackNewestFirst() {
        // A folder of receipts imported in one go carries copy dates, not real ones, so the date
        // in the filename is what the order should follow.
        let shared = Date(timeIntervalSince1970: 1_700_000_000)
        let ranker = Ranker(home: URL(filePath: "/Users/tester"))
        let items = ["2012-04-17 AJ Madison - Invoice.pdf", "2024-07-12 NK Home - Invoice.pdf"]
            .map {
                SearchResult(
                    url: URL(filePath: "/Users/tester/Documents/Receipts/\($0)"),
                    displayName: $0,
                    kind: .file,
                    modified: shared
                )
            }

        #expect(ranker.rank(items, query: "invoice").first?.displayName.hasPrefix("2024") == true)
    }

    @Test func theFilenameDateWinsOverAMisleadingModificationDate() {
        // Re-saving a 2012 receipt must not float it above a 2024 one.
        let ranker = Ranker(home: URL(filePath: "/Users/tester"))
        let old = SearchResult(
            url: URL(filePath: "/Users/tester/Documents/Receipts/2012-04-17 AJ Madison - Invoice.pdf"),
            displayName: "2012-04-17 AJ Madison - Invoice.pdf",
            kind: .file,
            modified: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let recent = SearchResult(
            url: URL(filePath: "/Users/tester/Documents/Receipts/2024-07-12 NK Home - Invoice.pdf"),
            displayName: "2024-07-12 NK Home - Invoice.pdf",
            kind: .file,
            modified: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(ranker.rank([old, recent], query: "invoice").first?.displayName.hasPrefix("2024") == true)
    }
}
