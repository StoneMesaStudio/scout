import SwiftUI

/// Scout has no windows of its own at launch — it lives in the menu bar and shows a panel when
/// the hotkey fires. `LSUIElement` in Info.plist keeps it out of the Dock and the app switcher;
/// the Settings scene exists so ⌘, has somewhere to go.
@main
struct ScoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
