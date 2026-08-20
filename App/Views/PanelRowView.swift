import AppKit
import SwiftUI
import ScoutCore

/// One line of results, whichever lane produced it. Keeping the layout identical across lanes is
/// what makes the keys behave identically too.
struct PanelRowView: View {

    let row: PanelRow
    let selected: Bool

    /// A message or a subject line is truncated at the end like a sentence, not in the middle
    /// like a filename.
    private var isMessage: Bool {
        switch row {
        case .message, .mail: true
        default: false
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(isMessage ? .tail : .middle)

                    if let badge {
                        Text(badge)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            if selected, let hint {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var icon: some View {
        switch row {
        case .app(let entry, _):
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path)).resizable()
        case .file(let result):
            Image(nsImage: NSWorkspace.shared.icon(forFile: result.url.path)).resizable()
        case .pane:
            symbolIcon("gearshape")
        case .mail:
            symbolIcon("envelope.fill")
        case .message:
            symbolIcon("message.fill")
        case .contact:
            symbolIcon("person.crop.circle.fill")
        }
    }

    private func symbolIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private var title: String {
        switch row {
        case .app(let entry, _): entry.name
        case .file(let result): result.displayName
        case .pane(let pane): pane.name
        case .mail(let hit): hit.subject
        // A message has no title of its own, so the message *is* the title.
        case .message(let hit): hit.text
        case .contact(let hit): hit.name
        }
    }

    private var badge: String? {
        switch row {
        case .file(let result) where result.duplicateCount > 1:
            "\(result.duplicateCount) copies"
        case .mail(let hit) where hit.isUnread:
            "unread"
        default:
            nil
        }
    }

    private var subtitle: String {
        switch row {
        case .app(let entry, let pinned):
            var parts = [pinned ? "Application — press return to launch" : "Application"]
            if !pinned, let used = entry.lastUsed {
                parts = ["Application", "used \(used.formatted(.relative(presentation: .named)))"]
            }
            return parts.joined(separator: " · ")

        case .file(let result):
            var parts = [result.breadcrumb()]
            if let modified = result.modified {
                parts.append(modified.formatted(date: .abbreviated, time: .shortened))
            }
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")

        case .pane:
            return "System Settings"

        case .mail(let hit):
            var parts = [hit.sender]
            if let date = hit.date {
                parts.append(date.formatted(date: .abbreviated, time: .omitted))
            }
            if let mailbox = hit.mailbox { parts.append(mailbox) }
            return parts.joined(separator: " · ")

        case .message(let hit):
            let who = hit.isFromMe ? "You → \(hit.counterpart)" : hit.counterpart
            return "\(who) · \(hit.date.formatted(date: .abbreviated, time: .shortened))"

        case .contact(let hit):
            return hit.detail.isEmpty ? "Contact" : hit.detail
        }
    }

    private var hint: String? {
        switch row {
        case .app: "return to launch"
        case .file(let result): result.kind == .folder ? "tab to search inside" : nil
        case .pane: "return to open"
        case .mail: "return to open in Mail"
        case .message: "return to open the conversation"
        case .contact: "return to open in Contacts"
        }
    }
}
