import AppKit
import Carbon.HIToolbox
import SwiftUI
import ScoutCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let panel = PanelController()
    private let welcome = WelcomeWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `Scout --diagnose <path>` writes the report and quits, so the check can be run without
        // anyone having to find a menu item.
        if let index = CommandLine.arguments.firstIndex(of: "--diagnose") {
            let destination = CommandLine.arguments.count > index + 1
                ? URL(filePath: CommandLine.arguments[index + 1])
                : FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop/Scout Diagnostic.txt")
            try? Diagnostics.report().write(to: destination, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
            return
        }

        installStatusItem()
        installHotKeys()

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
        menu.addItem(withTitle: "Diagnose Mail & Messages…", action: #selector(runDiagnostic), keyEquivalent: "")
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
        let report = Diagnostics.report()
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Desktop/Scout Diagnostic.txt")
        try? report.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Hotkeys

    /// ⌘-Space is the shortcut this app exists to take over, but macOS hands it to Spotlight
    /// until the user turns that off in System Settings. ⌥-Space is registered alongside it so
    /// Scout works from the first launch, before anyone has changed a system setting.
    private func installHotKeys() {
        let center = HotKeyCenter.shared
        center.register(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)) { [weak self] in
            self?.panel.toggle()
        }
        center.register(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            self?.panel.toggle()
        }
    }

    @objc private func showPanel() {
        panel.show()
    }

    @objc private func showWelcome() {
        welcome.show()
    }

    @objc private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
