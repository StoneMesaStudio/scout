// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Testing
import Foundation
@testable import ScoutCore

private let home = URL(filePath: "/Users/tester")

@Suite struct ScopeTests {

    @Test func myFilesCoversTheFourPlacesPeopleActuallyUse() {
        let paths = SearchScope.directories(for: .myFiles, home: home).map(\.lastPathComponent)
        #expect(paths.contains("Documents"))
        #expect(paths.contains("Desktop"))
        #expect(paths.contains("Downloads"))
        #expect(paths.contains("com~apple~CloudDocs"))
    }

    @Test func wholeMacHasNoDirectoryList() {
        // An empty list is the signal to hand NSMetadataQuery the local-computer scope instead.
        #expect(SearchScope.directories(for: .wholeMac, home: home).isEmpty)
    }
}

@Suite struct ExclusionTests {

    private let exclusions = Exclusions.standard

    @Test func developerFoldersAreRemovedNotDemoted() {
        #expect(exclusions.excludes(URL(filePath: "/Users/tester/Sites/app/node_modules/x/service-worker"), home: home))
        #expect(exclusions.excludes(URL(filePath: "/Users/tester/Library/Developer/Xcode/DerivedData/x/f"), home: home))
    }

    @Test func aFileTheUserNamedBuildIsNotNoise() {
        // Only *containing* folders count, so "build notes.txt" survives.
        #expect(!exclusions.excludes(URL(filePath: "/Users/tester/Documents/build notes.txt"), home: home))
    }

    @Test func systemAndLibraryAreOutOfAFileSearch() {
        #expect(exclusions.excludes(URL(filePath: "/System/Library/Whatever"), home: home))
        #expect(exclusions.excludes(URL(filePath: "/Users/tester/Library/Caches/thing"), home: home))
        #expect(exclusions.excludes(URL(filePath: "/Applications/Mail.app"), home: home))
    }

    @Test func iCloudDriveSurvivesEvenThoughItLivesUnderLibrary() {
        // The container sits inside ~/Library, so a naive Library rule would erase it entirely.
        let file = SearchScope.iCloudDrive(home: home).appending(path: "Vehicles/Ford F350/Service Receipts")
        #expect(!Exclusions(excludeSystemInternals: false).excludes(file, home: home))
    }

    @Test func ordinaryDocumentsAreLeftAlone() {
        #expect(!exclusions.excludes(URL(filePath: "/Users/tester/Documents/Home/Generator service log.numbers"), home: home))
    }

    @Test func turningExclusionsOffShowsEverything() {
        #expect(!Exclusions.none.excludes(URL(filePath: "/Users/tester/Sites/a/node_modules/b"), home: home))
    }
}

@Suite struct AppMatchTests {

    private let index = AppIndex(entries: [
        .init(url: URL(filePath: "/System/Applications/Mail.app"), name: "Mail"),
        .init(url: URL(filePath: "/Applications/Xcode.app"), name: "Xcode"),
    ])

    @Test func typingAnAppNameExactlyPinsThatApp() {
        #expect(index.exactMatch(for: "mail")?.name == "Mail")
        #expect(index.exactMatch(for: "  Xcode ")?.name == "Xcode")
    }

    @Test func aPartialNameDoesNotPinAnything() {
        // "mai" must not put Mail above every file the person is actually looking for.
        #expect(index.exactMatch(for: "mai") == nil)
        #expect(index.exactMatch(for: "") == nil)
    }

    @Test func theAppsLaneStillMatchesPartially() {
        #expect(index.matches(for: "ma").map(\.name) == ["Mail"])
    }
}

@Suite struct BreadcrumbTests {

    @Test func iCloudPathsReadAsICloudDrive() {
        let file = SearchScope.iCloudDrive(home: home).appending(path: "Vehicles/Ford F350/receipt.pdf")
        let result = SearchResult(url: file, displayName: "receipt.pdf", kind: .file)
        #expect(result.breadcrumb(home: home) == "iCloud Drive › Vehicles › Ford F350")
    }

    @Test func longPathsElideInTheMiddle() {
        let file = URL(filePath: "/Users/tester/Documents/a/b/c/d/e/f.txt")
        let result = SearchResult(url: file, displayName: "f.txt", kind: .file)
        #expect(result.breadcrumb(home: home) == "Documents › … › d › e")
    }
}
