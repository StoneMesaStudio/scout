import AppKit
import SwiftUI

/// A plain window for Settings.
///
/// SwiftUI's own `Settings` scene is opened through the responder chain, and Scout has no windows
/// and hides itself when the panel closes — so there was nothing in the chain to receive the
/// message and the command quietly did nothing. Owning the window outright removes the guesswork.
@MainActor
final class SettingsWindowController {

    static let openNotification = Notification.Name("ScoutOpenSettings")
    /// Which page to open, and optionally a permission to ask about on arrival.
    static let tabKey = "tab"
    static let requestKey = "request"

    private var window: NSWindow?

    func show(tab: SettingsView.Tab = .general, requesting permission: String? = nil) {
        let root = SettingsView(initialTab: tab, requestOnAppear: permission)

        if let window {
            // Replacing the root view is what makes a second visit able to land on a different
            // page, rather than wherever the window was left.
            window.contentView = NSHostingView(rootView: root)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 470),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Scout Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: root)

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
