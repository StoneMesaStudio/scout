import AppKit
import SwiftUI
import ScoutCore

/// One line of results, whichever lane produced it. Keeping the layout identical across lanes is
/// what makes the keys behave identically too.
struct PanelRowView: View {

    let row: PanelRow
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

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
            Image(systemName: "gearshape")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var title: String {
        switch row {
        case .app(let entry, _): entry.name
        case .file(let result): result.displayName
        case .pane(let pane): pane.name
        }
    }

    private var badge: String? {
        switch row {
        case .file(let result) where result.duplicateCount > 1:
            "\(result.duplicateCount) copies"
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
        }
    }

    private var hint: String? {
        switch row {
        case .app: "return to launch"
        case .file(let result): result.kind == .folder ? "tab to search inside" : nil
        case .pane: "return to open"
        }
    }
}
