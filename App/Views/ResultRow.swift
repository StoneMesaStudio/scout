import AppKit
import SwiftUI
import ScoutCore

/// One file or folder. The name carries the match, the line under it carries the where and when —
/// the two things you need to tell near-identical results apart.
struct ResultRow: View {

    let result: SearchResult
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: result.url.path))
                .resizable()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(result.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if result.duplicateCount > 1 {
                        Text("^[\(result.duplicateCount) copy](inflect: true)")
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

            if selected, result.kind == .folder {
                Text("tab to search inside")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var subtitle: String {
        var parts = [result.breadcrumb()]
        if let modified = result.modified {
            parts.append(modified.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The one app whose name was typed exactly, sitting above the files so Return still launches it.
struct PinnedAppRow: View {

    let app: AppIndex.Entry
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 14, weight: .medium))
                Text("Application")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if selected {
                Text("return to launch")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }
}
