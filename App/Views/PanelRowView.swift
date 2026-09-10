// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ScoutCore

/// Icons, worked out once per file rather than once per draw.
///
/// Asking the Finder for an icon means a `fileExists` and a `NSWorkspace` lookup, and both were
/// happening inside the view's body — so every keystroke and every arrow key paid for all of them
/// again, for every row on screen. On a local disk that is milliseconds a row; on a network volume
/// that has gone away, `fileExists` blocks until the mount times out.
@MainActor
final class IconCache {

    static let shared = IconCache()

    /// Plenty for any search, and small enough that emptying it wholesale costs nothing. There is
    /// no cleverer eviction because an icon is worth a few kilobytes and the panel is not a
    /// long-running document window.
    private static let capacity = 4_000
    private var icons: [String: NSImage] = [:]

    /// What is already known, and can be drawn this instant. `nil` means ask for it.
    func known(_ path: String) -> NSImage? { icons[path] }

    /// The icon macOS has for a kind of thing, with no disk involved.
    ///
    /// Drawn while the real one is being fetched. It is the right icon for the file's type — a PDF
    /// gets the PDF page, a folder gets a folder — so the row does not visibly change shape when
    /// the real one lands, and often does not visibly change at all.
    nonisolated static func placeholder(for result: SearchResult) -> NSImage {
        if let identifier = result.contentType, let type = UTType(identifier) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: result.kind == .folder ? .folder : .item)
    }

    nonisolated static func applicationPlaceholder() -> NSImage {
        NSWorkspace.shared.icon(for: .application)
    }

    /// Ask the Finder, away from the thread that draws the window.
    ///
    /// `fileExists` and `icon(forFile:)` both go to disk, and on this Mac most results live under
    /// an iCloud-managed Documents folder, so both go through the file provider — which answers
    /// when it answers. Inside a SwiftUI body that meant every keystroke paying for every row's
    /// icon on the main thread, and a slow answer stopped the window.
    func resolve(_ result: SearchResult) async -> NSImage {
        if let known = icons[result.url.path] { return known }

        let path = result.url.path
        let contentType = result.contentType
        let kind = result.kind
        let icon = await Task.detached(priority: .userInitiated) {
            if FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
            if let identifier = contentType, let type = UTType(identifier) {
                return NSWorkspace.shared.icon(for: type)
            }
            return NSWorkspace.shared.icon(for: kind == .folder ? .folder : .item)
        }.value

        store(icon, at: path)
        return icon
    }

    func resolveApplication(at url: URL) async -> NSImage {
        if let known = icons[url.path] { return known }

        let path = url.path
        let icon = await Task.detached(priority: .userInitiated) {
            NSWorkspace.shared.icon(forFile: path)
        }.value

        store(icon, at: path)
        return icon
    }

    private func store(_ icon: NSImage, at path: String) {
        if icons.count >= Self.capacity { icons.removeAll(keepingCapacity: true) }
        icons[path] = icon
    }
}

/// One row's icon: whatever is already known, or the icon for its kind until the Finder answers.
///
/// A view of its own so that one slow answer redraws one row rather than the whole list.
private struct RowIcon: View {

    enum Source: Equatable {
        case file(SearchResult)
        case application(URL)

        var path: String {
            switch self {
            case .file(let result): result.url.path
            case .application(let url): url.path
            }
        }
    }

    let source: Source
    @State private var resolved: NSImage?

    var body: some View {
        Image(nsImage: resolved ?? IconCache.shared.known(source.path) ?? fallback)
            .resizable()
            .task(id: source.path) {
                switch source {
                case .file(let result): resolved = await IconCache.shared.resolve(result)
                case .application(let url): resolved = await IconCache.shared.resolveApplication(at: url)
                }
            }
    }

    private var fallback: NSImage {
        switch source {
        case .file(let result): IconCache.placeholder(for: result)
        case .application: IconCache.applicationPlaceholder()
        }
    }
}

/// One line of results, whichever lane produced it. Keeping the layout identical across lanes is
/// what makes the keys behave identically too.
struct PanelRowView: View {

    let row: PanelRow
    let selected: Bool

    @Environment(\.colorScheme) private var scheme

    /// A message, a subject line or a note title is truncated at the end like a sentence, not in
    /// the middle like a filename.
    private var isProse: Bool {
        switch row {
        case .message, .mail, .note, .reminder: true
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
                        .truncationMode(isProse ? .tail : .middle)

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
                    // Paths are cut at the front so the filename survives; a sentence is cut at
                    // the end, the way anyone reading it would.
                    .truncationMode(isProse ? .tail : .head)
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
        .background { if selected { selectionCard } }
    }

    /// The selected row is a card lifted off the page, not a wash of colour over it.
    ///
    /// A tint was tried and abandoned: every heading is already a tinted band, so a tinted row is
    /// the same thing in a slightly different shade, and the row that matters ends up quieter than
    /// the label above it. Depth is the one thing a heading never has, so it cannot be mistaken for
    /// one no matter which of the eight colours it is sitting under.
    private var selectionCard: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.34 : 0.18), radius: 5, y: 2)
    }

    /// Light: paper, which is brighter than the panel's grey. Dark: light laid *on* the panel,
    /// because `textBackgroundColor` in the dark is darker than the material behind it and a card
    /// darker than its page reads as a hole rather than a raised thing.
    private var cardFill: some ShapeStyle {
        scheme == .dark ? AnyShapeStyle(Color.white.opacity(0.16)) : AnyShapeStyle(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var icon: some View {
        switch row {
        case .app(let entry, _):
            RowIcon(source: .application(entry.url))
        case .file(let result):
            RowIcon(source: .file(result))
        case .pane:
            symbolIcon("gearshape")
        case .mail:
            symbolIcon("envelope.fill")
        case .message:
            symbolIcon("message.fill")
        case .contact:
            symbolIcon("person.crop.circle.fill")
        case .note(let hit):
            symbolIcon(hit.isLocked ? "lock.fill" : "note.text")
        case .reminder(let hit):
            symbolIcon(hit.isCompleted ? "checkmark.circle.fill" : "circle")
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
        case .note(let hit): hit.title
        case .reminder(let hit): hit.title
        }
    }

    private var badge: String? {
        switch row {
        case .file(let result) where result.duplicateCount > 1:
            "\(result.duplicateCount) copies"
        case .mail(let hit) where hit.isUnread:
            "unread"
        // A locked note is in the results on its title alone — saying so is the difference
        // between "there is nothing in it" and "Scout cannot read what is in it".
        case .note(let hit) where hit.isLocked:
            "locked"
        case .reminder(let hit) where hit.isCompleted:
            "done"
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

        case .note(let hit):
            return hit.detail.isEmpty ? "Note" : hit.detail

        case .reminder(let hit):
            return hit.detail.isEmpty ? "Reminder" : hit.detail
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
        case .note: "return to open in Notes"
        case .reminder: "return to open in Reminders"
        }
    }
}
