import AppKit
import Contacts
import Foundation
import Observation
import ScoutCore

/// One thing macOS makes the user allow before Scout can do part of its job.
struct Permission: Identifiable {

    enum State: Equatable {
        case granted
        case notGranted
        /// Never asked. Only some permissions can be asked for from inside an app.
        case notAsked

        var isGranted: Bool { self == .granted }
    }

    /// What pressing the button does.
    enum Action {
        /// macOS will show its own prompt.
        case ask
        /// No API exists to request it; all an app can do is open the right pane.
        case openSettings(String)
    }

    let id: String
    let title: String
    /// What stops working without it, in the user's terms.
    let purpose: String
    let symbol: String
    var state: State
    let action: Action
    /// When Scout first saw this granted.
    var grantedOn: Date?

    var buttonTitle: String {
        switch action {
        case .ask: state.isGranted ? "Allowed" : "Allow…"
        case .openSettings: state.isGranted ? "Open settings" : "Open settings…"
        }
    }
}

/// Reads the real state of every permission Scout uses, and remembers when each was first granted.
///
/// macOS has no single place to ask "what am I allowed to do", and several of these cannot be
/// requested from inside an app at all. So this checks each one the only way that is honest —
/// by trying — and keeps the answers in one list the user can act on.
@MainActor
@Observable
final class PermissionCenter {

    private(set) var permissions: [Permission] = []

    private let store: UserDefaults
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private static let grantedKey = "permissionGrantDates"

    init(store: UserDefaults = .standard) {
        self.store = store
        refresh()
    }

    // MARK: - Reading the truth

    func refresh() {
        permissions = [fullDiskAccess, contacts, fileFolders, spotlightShortcut]
            .map(withGrantDate)
    }

    private var fullDiskAccess: Permission {
        // Mail and Messages are the two stores behind this switch, and the only honest test is
        // to try reading one of them.
        let readable = StoreAccess.canRead(directory: home.appending(path: "Library/Mail"))
            || StoreAccess.canRead(file: home.appending(path: "Library/Messages/chat.db"))

        return Permission(
            id: "fullDisk",
            title: "Full Disk Access",
            purpose: "Lets Scout search your mail and messages. Nothing leaves this Mac.",
            symbol: "externaldrive",
            state: readable ? .granted : .notGranted,
            action: .openSettings("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
        )
    }

    private var contacts: Permission {
        let state: Permission.State = switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: .granted
        case .notDetermined: .notAsked
        default: .notGranted
        }

        return Permission(
            id: "contacts",
            title: "Contacts",
            purpose: "Lets Scout find a person by name, number or address.",
            symbol: "person.crop.circle",
            state: state,
            // Once refused, macOS will not ask again — only the settings pane can undo it.
            action: state == .notGranted
                ? .openSettings("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Contacts")
                : .ask
        )
    }

    /// Documents, Desktop and Downloads are each their own permission, prompted the first time
    /// something reads them.
    private var fileFolders: Permission {
        let missing = Self.protectedFolders.filter {
            !StoreAccess.canRead(directory: home.appending(path: $0))
        }

        return Permission(
            id: "files",
            title: "Documents, Desktop & Downloads",
            purpose: missing.isEmpty
                ? "Scout can search all three."
                : "Still waiting on: \(missing.joined(separator: ", ")).",
            symbol: "folder",
            state: missing.isEmpty ? .granted : .notAsked,
            action: .ask
        )
    }

    private var spotlightShortcut: Permission {
        let taken = SpotlightShortcut.isEnabled
        return Permission(
            id: "commandSpace",
            title: "The ⌘-Space shortcut",
            purpose: taken
                ? "macOS still gives ⌘-Space to Spotlight. Untick “Show Spotlight search” under Spotlight. ⌥-Space works meanwhile."
                : "⌘-Space opens Scout. ⌥-Space works too.",
            symbol: "command",
            state: taken ? .notGranted : .granted,
            action: .openSettings("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        )
    }

    private static let protectedFolders = ["Documents", "Desktop", "Downloads"]

    // MARK: - Acting

    /// Trigger whatever macOS will let us trigger. Everything else opens the pane that can.
    func act(on permission: Permission) async {
        switch permission.action {
        case .openSettings(let string):
            if let url = URL(string: string) { NSWorkspace.shared.open(url) }

        case .ask where permission.id == "contacts":
            _ = try? await CNContactStore().requestAccess(for: .contacts)

        case .ask where permission.id == "files":
            // There is no API to request these; reading the folder is what makes macOS ask.
            for folder in Self.protectedFolders {
                _ = try? FileManager.default.contentsOfDirectory(
                    atPath: home.appending(path: folder).path
                )
            }

        case .ask:
            break
        }
        refresh()
    }

    // MARK: - Remembering

    /// Stamp the first time each permission is seen granted, so the panel can say when rather
    /// than only whether.
    private func withGrantDate(_ permission: Permission) -> Permission {
        var permission = permission
        var dates = store.dictionary(forKey: Self.grantedKey) as? [String: Date] ?? [:]

        if permission.state.isGranted {
            if let existing = dates[permission.id] {
                permission.grantedOn = existing
            } else {
                let now = Date()
                dates[permission.id] = now
                store.set(dates, forKey: Self.grantedKey)
                permission.grantedOn = now
            }
        } else if dates[permission.id] != nil {
            // Turned off again — forget the date rather than showing a stale one.
            dates[permission.id] = nil
            store.set(dates, forKey: Self.grantedKey)
        }

        return permission
    }
}
