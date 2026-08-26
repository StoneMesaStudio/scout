// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Foundation
import Testing
@testable import ScoutCore

/// A pretend home folder, so nothing here can touch a real one.
private func makeHome() throws -> URL {
    let home = URL(filePath: NSTemporaryDirectory())
        .appending(path: "scout-uninstall-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func write(_ bytes: Int, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: bytes).write(to: url)
}

private let identifier = "studio.stonemesa.scout"

@Suite struct UninstallTests {

    @Test func theIndexesAreFoundAndAddedUp() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try write(4_000, to: home.appending(path: "Library/Application Support/Scout/mail-bodies.sqlite"))
        try write(1_000, to: home.appending(path: "Library/Application Support/Scout/notes.sqlite"))

        let found = Uninstall.leftovers(bundleIdentifier: identifier, home: home)
        #expect(found.count == 1)
        #expect(found.first?.title == "Search indexes")
        // Allocated size rounds up to the block size, so the floor is what can be asserted.
        #expect((found.first?.bytes ?? 0) >= 5_000)
    }

    @Test func nothingWrittenMeansNothingToRemove() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // A person who has never granted Full Disk Access has no indexes at all. Offering to
        // delete files that do not exist reads as an app that has not looked.
        #expect(Uninstall.leftovers(bundleIdentifier: identifier, home: home).isEmpty)
    }

    @Test func settingsAndSavedStateAreFoundSeparately() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try write(120, to: home.appending(path: "Library/Preferences/\(identifier).plist"))
        try write(60, to: home.appending(path: "Library/Saved Application State/\(identifier).savedState/data"))

        let titles = Uninstall.leftovers(bundleIdentifier: identifier, home: home).map(\.title)
        #expect(titles.contains("Settings"))
        #expect(titles.contains("Saved window state"))
    }

    @Test func removingTakesEverythingAndReportsAnEmptyRemainder() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try write(4_000, to: home.appending(path: "Library/Application Support/Scout/mail-bodies.sqlite"))
        try write(120, to: home.appending(path: "Library/Preferences/\(identifier).plist"))

        let found = Uninstall.leftovers(bundleIdentifier: identifier, home: home)
        #expect(found.count == 2)

        let survived = Uninstall.remove(found)
        #expect(survived.isEmpty)
        #expect(Uninstall.leftovers(bundleIdentifier: identifier, home: home).isEmpty)
    }

    @Test func oneFailureDoesNotStopTheRest() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try write(4_000, to: home.appending(path: "Library/Application Support/Scout/mail-bodies.sqlite"))
        let found = Uninstall.leftovers(bundleIdentifier: identifier, home: home)

        // A path that is gone by the time the sweep reaches it — the shape of a cache macOS
        // cleared underneath us. It must not take the 349 MB of index down with it.
        let ghost = Uninstall.Leftover(title: "Caches", detail: "",
                                       url: home.appending(path: "Library/Caches/\(identifier)"),
                                       bytes: 0)
        let survived = Uninstall.remove([ghost] + found)
        #expect(survived.isEmpty)
        #expect(Uninstall.leftovers(bundleIdentifier: identifier, home: home).isEmpty)
    }

    @Test func theGrantsAreNamedBecauseTheAppCannotTakeThemBack() {
        // There is no API to revoke a TCC grant. An uninstaller that stayed quiet about that
        // would leave three System Settings panes listing an app that is in the Trash.
        #expect(Uninstall.permissionsOnlyTheUserCanRemove == ["Full Disk Access", "Contacts", "Reminders"])
    }
}
