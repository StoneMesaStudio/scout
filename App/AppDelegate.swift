import AppKit
import Carbon.HIToolbox
import SwiftUI
import ScoutCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let panel = PanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        installHotKeys()
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

        let menu = NSMenu()
        menu.addItem(withTitle: "Search…", action: #selector(showPanel), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Scout", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        statusItem = item
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

    @objc private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
