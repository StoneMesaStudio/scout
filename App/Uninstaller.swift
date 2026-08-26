// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import AppKit
import ServiceManagement
import ScoutCore

/// Takes Scout off the Mac: the indexes, the settings, the login item, and the app itself.
///
/// Reachable from Settings and from the menu-bar menu. `ScoutCore.Uninstall` decides what exists
/// and deletes it; everything here is the part that needs a person to agree first.
@MainActor
enum Uninstaller {

    static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "studio.stonemesa.scout" }

    static func leftovers() -> [Uninstall.Leftover] {
        Uninstall.leftovers(bundleIdentifier: bundleIdentifier)
    }

    /// Ask, then do it.
    ///
    /// Two dialogs: one to agree, and one to say what is left — because the second names the three
    /// grants no app is allowed to undo for itself and offers the one place to go and finish.
    static func run() {
        NSApp.activate(ignoringOtherApps: true)

        let found = leftovers()
        guard confirm(found) else { return }

        // Off the login list first. Doing it afterwards means unregistering a bundle macOS can no
        // longer find at the path it was registered from.
        try? SMAppService.mainApp.unregister()

        let survived = Uninstall.remove(found)
        let app = Bundle.main.bundleURL

        // `recycle` calls back on a queue of its own choosing, so the hop to the main actor is
        // real work, not ceremony — everything after this point puts up a window.
        NSWorkspace.shared.recycle([app]) { _, error in
            let trashed = error == nil
            Task { @MainActor in finish(trashed: trashed, at: app, survived: survived) }
        }
    }

    // MARK: - What the dialogs say

    /// Written once and used twice, so `--uninstall-preview` cannot drift from the real thing.
    static func confirmation(_ found: [Uninstall.Leftover]) -> (title: String, body: String) {
        var lines = ["Scout will move to the Trash. This cannot be undone."]

        if !found.isEmpty {
            let total = found.reduce(0) { $0 + $1.bytes }
            let inventory = found
                .map { "\($0.title.localizedLowercase) (\(Uninstall.readable($0.bytes)))" }
                .formatted(.list(type: .and))
            lines.append("It will also delete \(inventory) — \(Uninstall.readable(total)) in all.")
        }

        lines.append("""
            Scout cannot switch off the permissions you granted it. \
            \(Uninstall.permissionsOnlyTheUserCanRemove.formatted(.list(type: .and))) will keep \
            listing Scout in System Settings until you remove it there yourself.
            """)

        return ("Remove Scout from this Mac?", lines.joined(separator: "\n\n"))
    }

    static func closing(trashed: Bool, at app: URL, survived: [Uninstall.Leftover]) -> (title: String, body: String) {
        var lines: [String] = []

        if !trashed {
            lines.append("Drag it there yourself: \(app.path(percentEncoded: false))")
        }
        if !survived.isEmpty {
            let names = survived.map(\.title.localizedLowercase).formatted(.list(type: .and))
            lines.append("Scout could not delete its \(names). They are still where they were.")
        }
        lines.append("""
            \(Uninstall.permissionsOnlyTheUserCanRemove.formatted(.list(type: .and))) still list \
            Scout. Open each one and remove it to finish.
            """)

        return (trashed ? "Scout is in the Trash" : "Scout could not move itself to the Trash",
                lines.joined(separator: "\n\n"))
    }

    // MARK: - Putting them on screen

    private static func confirm(_ found: [Uninstall.Leftover]) -> Bool {
        let words = confirmation(found)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = words.title
        alert.informativeText = words.body

        let remove = alert.addButton(withTitle: "Remove Scout")
        remove.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")

        // Return cancels. An uninstaller is the last dialog that should answer itself with the
        // destructive verb.
        remove.keyEquivalent = ""
        cancel.keyEquivalent = "\r"

        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func finish(trashed: Bool, at app: URL, survived: [Uninstall.Leftover]) {
        let words = closing(trashed: trashed, at: app, survived: survived)
        let alert = NSAlert()
        alert.messageText = words.title
        alert.informativeText = words.body
        alert.addButton(withTitle: "Open Privacy & Security")
        alert.addButton(withTitle: "Quit")

        if alert.runModal() == .alertFirstButtonReturn,
           let settings = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(settings)
        }
        NSApp.terminate(nil)
    }

    /// `Scout --uninstall-preview <path>` writes what the dialogs would say and deletes nothing.
    ///
    /// The wording is the whole design here — it is the last thing a person reads before an
    /// action with no undo — and it should be reviewable without arming the button to read it.
    static func preview() -> String {
        let found = leftovers()
        let ask = confirmation(found)
        let done = closing(trashed: true, at: Bundle.main.bundleURL, survived: [])

        var report = "WOULD REMOVE\n------------\n"
        if found.isEmpty {
            report += "(nothing — Scout has written nothing outside its bundle)\n"
        }
        for item in found {
            report += "\(item.title.padding(toLength: 20, withPad: " ", startingAt: 0))"
            report += "\(Uninstall.readable(item.bytes).padding(toLength: 10, withPad: " ", startingAt: 0))"
            report += "\(item.url.path(percentEncoded: false))\n"
        }
        report += "\(Bundle.main.bundleURL.path(percentEncoded: false)) → Trash\n"
        report += "the login item, if it is registered\n"
        report += "\nFIRST DIALOG\n------------\n\(ask.title)\n\n\(ask.body)\n"
        report += "\n[ Remove Scout ]   [ Cancel ]  ← Cancel is what Return does\n"
        report += "\nSECOND DIALOG\n-------------\n\(done.title)\n\n\(done.body)\n"
        report += "\n[ Open Privacy & Security ]   [ Quit ]\n"
        return report
    }
}
