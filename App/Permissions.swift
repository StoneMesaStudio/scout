// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import AppKit
import Contacts
import EventKit
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

    /// The last answer about Documents, Desktop and Downloads, and whether it has been asked for
    /// at all yet.
    ///
    /// These three are not like the others. There is no API that reports whether they are allowed
    /// — the only way to find out is to read one, and reading one that has not been answered yet
    /// *is* the request: macOS puts up the prompt. So this page used to manufacture a prompt every
    /// two seconds, for each folder still outstanding, for as long as it was open. The screen whose
    /// whole job is to show you your permissions was the thing pestering you for them.
    ///
    /// So the answer is remembered, and asked for again only when the user does something that
    /// means they want it asked.
    private var missingFolders: [String] = PermissionCenter.protectedFolders
    private var hasCheckedFolders = false

    init(store: UserDefaults = .standard) {
        self.store = store
        refresh()
    }

    // MARK: - Reading the truth

    func refresh() {
        permissions = [fullDiskAccess, contacts, reminders, fileFolders, spotlightShortcut]
            .map(withGrantDate)
    }

    private var fullDiskAccess: Permission {
        // Mail, Messages and Notes are the three stores behind this switch, and the only honest
        // test is to try reading one of them.
        // Cheapest first, because this runs on a timer: two single-file opens before the one
        // that enumerates a mail archive. None of the three can prompt — macOS never asks for Full
        // Disk Access, it just refuses until the switch is on.
        let readable = StoreAccess.canRead(file: home.appending(path: "Library/Messages/chat.db"))
            || StoreAccess.canRead(file: NotesIndex.defaultSource(home: home))
            || StoreAccess.canRead(directory: home.appending(path: "Library/Mail"))

        return Permission(
            id: "fullDisk",
            title: "Full Disk Access",
            purpose: "Lets Scout search your mail, messages and notes. Nothing leaves this Mac.",
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

    private var reminders: Permission {
        let state: Permission.State = switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .notGranted
        }

        return Permission(
            id: "reminders",
            title: "Reminders",
            purpose: "Lets Scout find a reminder by what it says, what list it is in, or the note on it.",
            symbol: "checklist",
            state: state,
            // Once refused, macOS will not ask again — only the settings pane can undo it.
            action: state == .notGranted
                ? .openSettings("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Reminders")
                : .ask
        )
    }

    /// Documents, Desktop and Downloads are each their own permission, prompted the first time
    /// something reads them.
    /// Built from the remembered answer. Never reads the folders — see `missingFolders`.
    private var fileFolders: Permission {
        let purpose: String = if !hasCheckedFolders {
            "Scout will ask the first time it searches them."
        } else if missingFolders.isEmpty {
            "Scout can search all three."
        } else {
            "Still waiting on: \(missingFolders.joined(separator: ", "))."
        }

        return Permission(
            id: "files",
            title: "Documents, Desktop & Downloads",
            purpose: purpose,
            symbol: "folder",
            state: hasCheckedFolders && missingFolders.isEmpty ? .granted : .notAsked,
            action: .ask
        )
    }

    /// Read the three folders, which is both the check and the request.
    ///
    /// Only ever called from something the user did — opening this page, pressing Check again, or
    /// pressing Allow. Never from the timer.
    func checkFolders() {
        missingFolders = Self.protectedFolders.filter {
            !StoreAccess.canRead(directory: home.appending(path: $0))
        }
        hasCheckedFolders = true
        refresh()
    }

    private var spotlightShortcut: Permission {
        let taken = SpotlightShortcut.isEnabled
        return Permission(
            id: "commandSpace",
            title: "The ⌘-Space shortcut",
            purpose: taken
                ? "⌥-Space works either way. To hand over ⌘-Space too: Keyboard Shortcuts… › Spotlight › untick “Show Spotlight search”. Scout stays off that shortcut until then, because claiming it too would open both at once."
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

        case .ask where permission.id == "reminders":
            _ = try? await EKEventStore().requestFullAccessToReminders()

        case .ask where permission.id == "files":
            // There is no API to request these; reading the folder is what makes macOS ask.
            checkFolders()
            return

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
