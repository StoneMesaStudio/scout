import AppKit
import SwiftUI
import ScoutCore

/// Shown in place of results when a lane cannot answer yet, and why.
///
/// Mail, Messages and Notes all need Full Disk Access — a permission macOS gives no way to
/// request from inside an app. All Scout can do is say plainly what is missing and open the right
/// settings pane, rather than showing an empty list that looks like "nothing found".
struct LaneStatusView: View {

    let status: LaneStatus
    let lane: SearchLane
    /// Called when the notice can do something about the problem itself.
    var onRequestAccess: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 5) {
                Text(headline)
                    .font(.system(size: 13.5, weight: .medium))

                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let askTitle {
                    Button(askTitle) { onRequestAccess?() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .padding(.top, 1)
                } else if let permissionPane {
                    Button(permissionPane.title) {
                        if let url = URL(string: permissionPane.url) { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .padding(.top, 1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    /// The two permissions an app is allowed to ask about itself get a button that asks.
    private var askTitle: String? {
        switch status {
        case .contactsNotAsked: "Allow Contacts…"
        case .remindersNotAsked: "Allow Reminders…"
        default: nil
        }
    }

    /// The settings pane that would fix this, when one would.
    private var permissionPane: (title: String, url: String)? {
        switch status {
        case .needsFullDiskAccess:
            ("Open Full Disk Access",
             "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
        case .contactsDenied:
            ("Open Contacts permissions",
             "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Contacts")
        case .remindersDenied:
            ("Open Reminders permissions",
             "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Reminders")
        default:
            nil
        }
    }

    private var symbol: String {
        switch status {
        case .contactsNotAsked, .contactsDenied, .remindersNotAsked, .remindersDenied: "lock"
        case .needsFullDiskAccess: "lock"
        case .building: "clock"
        case .failed: "exclamationmark.triangle"
        case .ready: "checkmark"
        }
    }

    private var tint: Color {
        switch status {
        case .needsFullDiskAccess, .contactsNotAsked, .contactsDenied,
             .remindersNotAsked, .remindersDenied, .building: .secondary
        case .failed: .orange
        case .ready: .secondary
        }
    }

    /// The user's word for what the lane reads. "Scout can't read your Notes yet" is a sentence
    /// about an app; "your notes" is a sentence about their things.
    private static func store(for lane: SearchLane) -> String {
        switch lane {
        case .mail: "mail"
        case .notes: "notes"
        default: "messages"
        }
    }

    private var headline: String {
        switch status {
        case .contactsNotAsked:
            "Scout hasn’t asked for your contacts yet"
        case .contactsDenied:
            "Scout isn’t allowed to read your contacts"
        case .remindersNotAsked:
            "Scout hasn’t asked for your reminders yet"
        case .remindersDenied:
            "Scout isn’t allowed to read your reminders"
        case .needsFullDiskAccess:
            "Scout can’t read your \(Self.store(for: lane)) yet"
        case .building:
            "Reading your \(lane == .notes ? "notes" : "message history")…"
        case .failed:
            "That didn’t work"
        case .ready:
            ""
        }
    }

    private var detail: String? {
        switch status {
        case .contactsNotAsked:
            "One click and macOS will ask. Nothing leaves this Mac."
        case .contactsDenied:
            "Turn Scout on in Privacy & Security › Contacts. Nothing leaves this Mac."
        case .remindersNotAsked:
            "One click and macOS will ask. Nothing leaves this Mac."
        case .remindersDenied:
            "Turn Scout on in Privacy & Security › Reminders. Nothing leaves this Mac."
        case .needsFullDiskAccess:
            "macOS keeps \(Self.store(for: lane)) locked away until you allow it. Turn on Scout in Full Disk Access, then come back — you only do this once."
        case .building:
            "The first read goes through everything you have. After that it only picks up what’s new."
        case .failed(let reason):
            reason
        case .ready:
            nil
        }
    }
}
