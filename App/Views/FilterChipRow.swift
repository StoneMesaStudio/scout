// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import SwiftUI
import ScoutCore

/// The chips under the search field.
///
/// They are on the surface, not behind a menu, because the complaint that produced this app was
/// that narrowing a search in Spotlight is both hard to reach and ineffective once reached.
/// Every chip here removes results outright.
struct FilterChipRow: View {

    @Bindable var model: SearchModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Pinned places first: they are the same on every search, so their position
                // stays learnable.
                ForEach(model.pinnedPlaces, id: \.self) { place in
                    Chip(
                        caption: "Pinned",
                        label: place.lastPathComponent,
                        symbol: "pin.fill",
                        active: model.filter.folders.contains(place)
                    ) {
                        model.filter.toggle(folder: place)
                    }
                }

                ForEach(model.suggestions.folders.filter { !model.pinnedPlaces.contains($0.url) }) { folder in
                    Chip(
                        caption: "In",
                        label: folder.name,
                        detail: "\(folder.count)",
                        active: model.filter.folders.contains(folder.url)
                    ) {
                        model.filter.toggle(folder: folder.url)
                    }
                }

                ForEach(model.suggestions.kinds) { kind in
                    Chip(
                        caption: "Kind",
                        label: kind.title,
                        symbol: kind.symbol,
                        active: model.filter.kinds.contains(kind)
                    ) {
                        model.filter.toggle(kind: kind)
                    }
                }

                ForEach(model.suggestions.windows) { window in
                    Chip(
                        caption: "When",
                        label: window.title,
                        active: model.filter.dateWindow == window
                    ) {
                        model.filter.toggle(window: window)
                    }
                }

                if !model.filter.isEmpty {
                    Button("Clear") { model.filter.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }
}

private struct Chip: View {
    var caption: String
    var label: String
    var symbol: String?
    var detail: String?
    var active: Bool
    var action: () -> Void

    init(
        caption: String,
        label: String,
        symbol: String? = nil,
        detail: String? = nil,
        active: Bool,
        action: @escaping () -> Void
    ) {
        self.caption = caption
        self.label = label
        self.symbol = symbol
        self.detail = detail
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(caption.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .opacity(0.55)

                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10))
                }

                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                if let detail {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .opacity(0.6)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                active ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(active ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
            )
            .foregroundStyle(active ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}
