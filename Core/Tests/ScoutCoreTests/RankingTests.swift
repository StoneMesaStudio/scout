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
        #expect(NameMatch.classify(name: "Ford F350 Service Receipts", query: "service") == .wordPrefix)
        #expect(NameMatch.classify(name: "webservices.log", query: "service") == .substring)
        #expect(NameMatch.classify(name: "Ford F350 Service Receipts", query: "service")
                > NameMatch.classify(name: "webservices.log", query: "service"))
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

    @Test func orderIsStableAcrossIdenticalSearches() {
        let items = [
            result("/Users/tester/Documents/service a.txt", modified: daysAgo(5)),
            result("/Users/tester/Documents/service b.txt", modified: daysAgo(5)),
        ]
        #expect(ranker.rank(items, query: "service", now: now).map(\.displayName)
                == ranker.rank(items.reversed(), query: "service", now: now).map(\.displayName))
    }
}
