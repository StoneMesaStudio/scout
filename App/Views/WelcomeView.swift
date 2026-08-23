import AppKit
import SwiftUI

/// Shown once, the first time Scout runs.
///
/// It exists because the two things Scout cannot do for itself — take ⌘-Space, and read mail and
/// messages — both live in System Settings. Left unexplained, a new user presses ⌘-Space, gets
/// Spotlight, and concludes the app is broken.
struct WelcomeView: View {

    var onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.accentColor)

                Text("Scout is running")
                    .font(.system(size: 24, weight: .semibold))

                Text("Press ⌥-Space anywhere to search. It works right now — the rest of this page is optional.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 22)

            Step(
                number: 1,
                title: "Give ⌘-Space to Scout",
                detail: "macOS hands ⌘-Space to Spotlight until you say otherwise. In Keyboard Shortcuts, choose Spotlight and untick “Show Spotlight search”. Scout leaves the shortcut alone until then — otherwise one press would open both — and takes it over on its own the moment you do.",
                button: "Open Keyboard Shortcuts",
                url: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
            )

            Step(
                number: 2,
                title: "Let Scout read mail and messages",
                detail: "Only needed for the Mail, Messages and Notes lanes. Turn on Scout in Full Disk Access. Everything stays on this Mac.",
                button: "Open Full Disk Access",
                url: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
            )

            Spacer(minLength: 12)

            HStack {
                Text("Scout lives in the menu bar. Its settings are there too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onFinish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 460, height: 430)
    }
}

private struct Step: View {
    let number: Int
    let title: String
    let detail: String
    let button: String
    let url: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.16), in: Circle())
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(button) {
                    if let url = URL(string: url) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.link)
                .font(.system(size: 12.5))
            }
        }
        .padding(.bottom, 18)
    }
}

/// A plain window for the welcome page. Scout has no Dock icon and no main window, so there is no
/// scene to hang this off — it is created directly when it is needed.
@MainActor
final class WelcomeWindowController {

    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = "Scout"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: WelcomeView { [weak self] in
            self?.window?.close()
        })

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
