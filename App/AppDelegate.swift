// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import AppKit
import Carbon.HIToolbox
import Contacts
import Sparkle
import SwiftUI
import ScoutCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let panel = PanelController()
    private let welcome = WelcomeWindowController()
    private let settingsWindow = SettingsWindowController()
    private var hotKeyWatcher: Timer?

    /// Checks the website for a newer Scout once a day, and installs one when the user says so.
    ///
    /// Built in `applicationDidFinishLaunching` rather than here, so the command-line modes —
    /// `--shot`, `--diagnose`, `--probe` — never start an updater on their way past.
    private var updater: SPUStandardUpdaterController?

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
            // A trailing word, but not the next flag — `--style` sits in the same position.
            let trailing = CommandLine.arguments.count > index + 5 ? CommandLine.arguments[index + 5] : nil
            let query = (trailing?.hasPrefix("--") ?? true) ? nil : trailing
            // `--style iconOnly|iconAndText|textOnly`, for photographing the same panel three
            // ways when the question is which of them should be the default.
            let style = CommandLine.arguments.firstIndex(of: "--style")
                .flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil }
                .flatMap(SourceButtonStyle.init(rawValue:)) ?? .textOnly

            guard let scene = DemoData.Scene(rawValue: name) else {
                let known = DemoData.Scene.allCases.map(\.rawValue).joined(separator: ", ")
                try? "unknown scene \(name) — try one of: \(known)\n"
                    .write(to: destination.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }

            panel.beginShot(scene: scene, query: query, style: style, size: canvas)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let report = self.panel.captureShot(to: destination)
                try? report.write(to: destination.appendingPathExtension("txt"),
                                  atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }

        // `Scout --uninstall-preview <path>` writes what the uninstaller would say and do, and
        // removes nothing. The wording is the last thing somebody reads before an action with no
        // undo; it should be reviewable without arming the button to read it.
        if let index = CommandLine.arguments.firstIndex(of: "--uninstall-preview"),
           CommandLine.arguments.count > index + 1 {
            let report = Uninstaller.preview()
            try? report.write(to: URL(filePath: CommandLine.arguments[index + 1]),
                              atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
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

        updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )

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

        askAboutFoldersOnce()

        // Nothing about this app can see a hang on somebody else's Mac, and the one being chased
        // has never happened while anyone was looking. So it watches for itself.
        HangWatchdog.shared.start()
    }

    /// Put the Documents, Desktop and Downloads question at a moment when the user can see it.
    ///
    /// macOS asks for those three the first time something reads one, and Scout reads all three
    /// every time it searches. That sounds harmless and is not: the panel is a floating window and
    /// macOS draws its permission prompts in ordinary ones, so a prompt raised while somebody is
    /// typing goes *behind* the panel. Nothing appears to happen, so nothing gets answered, so the
    /// permission stays undecided and the next search asks again — and the prompt finally surfaces
    /// whenever the panel happens to go away, with nothing on screen to explain it. That is the
    /// "random" permission request, and it is the same trap `requestContactsAccess` documents.
    ///
    /// Asked here instead: once ever, at launch, with no panel in front of it. On a first run the
    /// welcome window is up, which is an ordinary window and a good place for it to land.
    ///
    /// Off the main thread because opening a folder the iCloud file provider has let go cold takes
    /// as long as it takes, and because the prompt itself waits for a human.
    private func askAboutFoldersOnce() {
        guard !ScoutSettings.shared.hasAskedForFolders else { return }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = ["Documents", "Desktop", "Downloads"].map { home.appending(path: $0) }

        Task {
            await Task.detached(priority: .utility) {
                for folder in folders {
                    let descriptor = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY)
                    if descriptor >= 0 { Darwin.close(descriptor) }
                }
            }.value
            // Set whatever the answers were. Asking a second time is the bug being fixed.
            ScoutSettings.shared.hasAskedForFolders = true
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
        // Sparkle's own action, aimed at its controller rather than at this class.
        let updates = menu.addItem(withTitle: "Check for Updates\u{2026}", action: nil, keyEquivalent: "")
        updates.target = updater
        updates.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))

        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove Scout\u{2026}", action: #selector(uninstall), keyEquivalent: "")
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

    /// The item Engst asks for by name. Scout has no Help menu — no menu bar at all — so the
    /// status-item menu is where it goes, next to Quit, which is where somebody leaving will look.
    @objc private func uninstall() {
        Uninstaller.run()
    }
}

// MARK: - Updates

/// Scout has no Dock icon and no menu bar of its own, which is exactly the case Sparkle warns
/// about: left alone, the "a new version is available" window opens behind whatever the person is
/// working in, and the only sign anything happened is a beach of nothing. So the app takes a Dock
/// icon for as long as that conversation lasts, and gives it back afterwards.
extension AppDelegate: SPUStandardUserDriverDelegate {

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            // The panel goes away first, and that is not politeness — it is the fourth time this
            // has bitten. The panel is a floating window, Sparkle's is an ordinary one, and a
            // floating window sits above an ordinary one no matter which app is in front. So the
            // update window opened *behind* the search panel and looked like nothing happened,
            // exactly as the Contacts and Reminders prompts did before they were routed around it.
            panel.hide()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            // Back to being nothing but a menu bar icon.
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
