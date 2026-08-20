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
            print(panel.selfTest(query: query))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                print("--- after the search returned ---")
                print(self.panel.selfTestSummary())
                NSApp.terminate(nil)
            }
            return
        }

        installStatusItem()
        installHotKeys()

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
