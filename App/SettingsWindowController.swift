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

    private var window: NSWindow?

    func show() {
        if let window {
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
        window.contentView = NSHostingView(rootView: SettingsView())

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
