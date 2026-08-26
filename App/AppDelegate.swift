// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import AppKit
import Carbon.HIToolbox
import Contacts
import SwiftUI
import ScoutCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let panel = PanelController()
    private let welcome = WelcomeWindowController()
    private let settingsWindow = SettingsWindowController()
    private var hotKeyWatcher: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `Scout --diagnose <path>` writes the report and quits, so the check can be run without
        // anyone having to find a menu item.
        if let index = CommandLine.arguments.firstIndex(of: "--diagnose") {
            let destination = CommandLine.arguments.count > index + 1
                ? URL(filePath: CommandLine.arguments[index + 1])
                : FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop/Scout Diagnostic.txt")
            var report = Diagnostics.report()
            report += "\n\nSHORTCUT\n--------\n"
            report += "Spotlight still holds ⌘-Space: \(SpotlightShortcut.isEnabled ? "yes" : "no")\n"
            refreshHotKeys()
            report += "Scout has claimed ⌘-Space: \(HotKeyCenter.shared.isRegistered(Self.commandSpace) ? "yes" : "no")\n"
            report += "Scout has claimed ⌥-Space: \(HotKeyCenter.shared.isRegistered(Self.optionSpace) ? "yes" : "no")\n"
            report += "\nCONTACTS\n--------\n"
            report += "authorization status: \(CNContactStore.authorizationStatus(for: .contacts).rawValue)"
            report += "  (0 = never asked, 2 = denied, 3 = allowed, 4 = limited)\n"
            try? report.write(to: destination, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
            return
        }

        // `Scout --selftest <query>` lays the panel out offscreen and prints what it measured,
        // so a layout that silently collapses can be caught without anyone watching the screen.
        if let index = CommandLine.arguments.firstIndex(of: "--selftest") {
            let query = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "service"
            // A path to write to, because launching through LaunchServices — which is the only
            // way the app carries its own permissions — leaves nowhere for stdout to go.
            let destination = CommandLine.arguments.count > index + 2
                ? URL(filePath: CommandLine.arguments[index + 2])
                : nil
            _ = panel.selfTest(query: query)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                let report = self.panel.selfTestSummary()
                if let destination {
                    try? report.write(to: destination, atomically: true, encoding: .utf8)
                } else {
                    print(report)
                }
                NSApp.terminate(nil)
            }
            return
        }

        // `Scout --shot <scene> <path> [width height [word]]` photographs one of the pictures on
        // the website, on invented data. The trailing word replaces the scene's own, which is how
        // a search term gets tried against the real app and settings indexes without a rebuild.
        if let index = CommandLine.arguments.firstIndex(of: "--shot"),
           CommandLine.arguments.count > index + 2 {
            let name = CommandLine.arguments[index + 1]
            let destination = URL(filePath: CommandLine.arguments[index + 2])
            let width = CommandLine.arguments.count > index + 3 ? Double(CommandLine.arguments[index + 3]) ?? 900 : 900
            let height = CommandLine.arguments.count > index + 4 ? Double(CommandLine.arguments[index + 4]) ?? 720 : 720
            let canvas = NSSize(width: width, height: height)
            let query = CommandLine.arguments.count > index + 5 ? CommandLine.arguments[index + 5] : nil

            guard let scene = DemoData.Scene(rawValue: name) else {
                let known = DemoData.Scene.allCases.map(\.rawValue).joined(separator: ", ")
                try? "unknown scene \(name) — try one of: \(known)\n"
                    .write(to: destination.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }

            panel.beginShot(scene: scene, query: query, size: canvas)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let report = self.panel.captureShot(to: destination)
                try? report.write(to: destination.appendingPathExtension("txt"),
                                  atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }

        // `Scout --probe-notes <term> <path>` does the same for the two newest lanes, which read
        // stores a terminal cannot open either.
        if let index = CommandLine.arguments.firstIndex(of: "--probe-notes"),
           CommandLine.arguments.count > index + 2 {
            let term = CommandLine.arguments[index + 1]
            let destination = URL(filePath: CommandLine.arguments[index + 2])
            Task {
                let report = await Diagnostics.probeNotesAndReminders(term)
                try? report.write(to: destination, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--probe"),
           CommandLine.arguments.count > index + 2 {
            let report = Diagnostics.probe(CommandLine.arguments[index + 1])
            try? report.write(to: URL(filePath: CommandLine.arguments[index + 2]), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
            return
        }

        installStatusItem()
        installHotKeys()

        // Begin reading the mail archive straight away rather than waiting for a search.
        panel.startBackgroundIndexing()

        // The panel asks for Settings this way rather than reaching for the app delegate.
        NotificationCenter.default.addObserver(
            forName: SettingsWindowController.openNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Read out of the notification before the actor hop: a Notification is not Sendable,
            // but the two values inside it are.
            let tab = note.userInfo?[SettingsWindowController.tabKey] as? SettingsView.Tab ?? .general
            let request = note.userInfo?[SettingsWindowController.requestKey] as? String
            MainActor.assumeIsolated {
                self?.settingsWindow.show(tab: tab, requesting: request)
            }
        }

        // First run: nothing about a menu-bar app with no Dock icon tells a new user it started,
        // let alone that ⌘-Space still belongs to Spotlight.
        if !ScoutSettings.shared.hasSeenWelcome {
            ScoutSettings.shared.hasSeenWelcome = true
            welcome.show()
        }
    }

    // MARK: - Menu bar

    /// The menu bar shows an icon only — no title text. It is the app's entire visible presence
    /// when the panel is closed.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: "Scout"
        )
        item.button?.image?.isTemplate = true

        // Clicking the icon opens the panel; the menu is on right-click. Hanging a menu off the
        // left button would put a list of housekeeping commands between the user and the one
        // thing they clicked it for.
        item.button?.action = #selector(statusItemClicked)
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Search…", action: #selector(showPanel), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Getting Started…", action: #selector(showWelcome), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Diagnose Sources…", action: #selector(runDiagnostic), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Scout", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func statusItemClicked() {
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true

        guard let item = statusItem else { return }

        if rightClick {
            // Attaching the menu, popping it, then detaching keeps the left button free.
            item.menu = buildMenu()
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            panel.toggle()
        }
    }

    @objc private func runDiagnostic() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Desktop/Scout Diagnostic.txt")
        // Reminders can only be read asynchronously, so the report is assembled off the main
        // thread and written once — rather than written twice and appearing to change by itself.
        Task {
            var report = Diagnostics.report()
            report += "\n\n" + (await Diagnostics.probeNotesAndReminders("the"))
            try? report.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Hotkeys

    /// ⌥-Space always opens Scout. ⌘-Space only once Spotlight has let go of it.
    ///
    /// macOS will happily give the same shortcut to two apps at once — it does not refuse the
    /// registration, it just fires both. Claiming ⌘-Space while Spotlight still has it means one
    /// press opens Scout *and* Spotlight, on top of each other. So Scout waits its turn, and
    /// takes the shortcut the moment the box is unticked.
    private func installHotKeys() {
        refreshHotKeys()

        // Nothing notifies an app when that setting changes, so the only way to pick it up is to
        // look again. A dictionary read every few seconds costs nothing.
        hotKeyWatcher = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { self.refreshHotKeys() }
        }
    }

    private func refreshHotKeys() {
        let center = HotKeyCenter.shared

        center.register(name: Self.optionSpace, keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            self?.panel.toggle()
        }

        if SpotlightShortcut.isEnabled {
            center.unregister(Self.commandSpace)
        } else {
            center.register(name: Self.commandSpace, keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)) { [weak self] in
                self?.panel.toggle()
            }
        }
    }

    private static let commandSpace = "commandSpace"
    private static let optionSpace = "optionSpace"

    @objc private func showPanel() {
        panel.show()
    }

    @objc private func showWelcome() {
        welcome.show()
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }
}
