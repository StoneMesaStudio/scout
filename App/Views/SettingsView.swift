import SwiftUI

/// A placeholder until the real settings screen arrives — but it carries the one instruction
/// Scout cannot carry out for itself.
struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scout")
                .font(.system(size: 20, weight: .semibold))

            Text("Press ⌥-Space to search. To use ⌘-Space instead, turn off Spotlight's own shortcut:")
                .fixedSize(horizontal: false, vertical: true)

            Text("System Settings › Keyboard › Keyboard Shortcuts › Spotlight — untick “Show Spotlight search”.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Keyboard Shortcuts") {
                let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
                if let url { NSWorkspace.shared.open(url) }
            }
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
    }
}
