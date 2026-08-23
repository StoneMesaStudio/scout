import SwiftUI
import ScoutCore

/// The panel: a field, the source buttons, the chips, grouped results, and a line of keys along
/// the bottom.
struct SearchRootView: View {

    @Bindable var model: SearchModel
    @State private var settings = ScoutSettings.shared
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                field
                sourceBar
            }
            // Drag anywhere in the top bar to move the panel. Only the top bar: making the
            // results draggable would mean a slightly-moved click on a result moved the window
            // instead of opening the thing.
            .background(WindowDragHandle())
            Divider().opacity(0.5)

            if model.hasChips {
                FilterChipRow(model: model)
                Divider().opacity(0.5)
            }

            // The results area always claims the space left over, so the panel keeps its shape
            // whether it is showing sixty rows, none, or nothing typed yet.
            Group {
                if model.noLanesAreOn {
                    noSourcesState
                } else if !model.displayItems.isEmpty {
                    results
                } else if !model.text.isEmpty {
                    emptyState
                } else {
                    idleState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.5)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .onAppear { fieldFocused = true }
    }

    // MARK: - Field

    private var field: some View {
        HStack(spacing: 13) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $model.text)
                .textFieldStyle(.plain)
                .font(.system(size: 27, weight: .regular))
                .focused($fieldFocused)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 11)
        // ⌥ turns the arrows into a section jump, which is how you get past a hundred files
        // without holding the key down.
        .onKeyPress(keys: [.downArrow, .upArrow]) { press in
            let down = press.key == .downArrow
            if press.modifiers.contains(.option) {
                model.moveToSection(by: down ? 1 : -1)
            } else {
                model.moveSelection(by: down ? 1 : -1)
            }
            return .handled
        }
        .onKeyPress(.escape) { model.escape(); return .handled }
        .onKeyPress(.tab) { model.drillIntoSelection(); return .handled }
        // Return opens; ⌘Return reveals in the Finder instead. Handled together because
        // SwiftUI's key matching does not distinguish modifiers on its own.
        .onKeyPress(keys: [.return]) { press in
            if press.modifiers.contains(.command) {
                model.revealInFinder()
            } else {
                model.activate()
            }
            return .handled
        }
        // ⌘L flips the file scope, ⌘1…⌘8 switch a source on or off, ⌘0 switches the lot.
        .onKeyPress(keys: ["l", "0", "1", "2", "3", "4", "5", "6", "7", "8"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            switch press.key.character {
            case "l": model.toggleScope()
            case "0": model.setAllLanes(!model.allLanesAreOn)
            default:
                if let number = Int(String(press.key.character)) {
                    model.toggleLane(number: number)
                }
            }
            return .handled
        }
    }

    private var placeholder: String {
        if let folder = model.focusedFolderName { return "Search in \(folder)" }
        return "Search"
    }

    // MARK: - Sources

    private var sourceBar: some View {
        HStack(alignment: .top, spacing: 7) {
            // Wrapped rather than in one row: eight sources plus the scope switch do not fit
            // across the panel at its minimum width, and a row that overflows silently loses
            // whichever sources happen to be last.
            SourceStrip(model: model, style: settings.sourceButtonStyle)

            allOrNoneButton
            scopeControl
        }
        .padding(.horizontal, 17)
        .padding(.bottom, 12)
        // The same menu Mail's toolbar has, in the same place: right-click the buttons.
        .contextMenu {
            Picker("Show", selection: $settings.sourceButtonStyle) {
                ForEach(SourceButtonStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.inline)

            Divider()
            Button("Turn All Sources On") { model.setAllLanes(true) }
            Button("Turn All Sources Off") { model.setAllLanes(false) }
            Divider()
            Button("Put the Sources Back in Order") { model.resetLaneOrder() }
        }
    }

    /// One button, two jobs. Everything off is a real state — it is how you get to a single
    /// source in two clicks instead of seven.
    private var allOrNoneButton: some View {
        Button {
            model.setAllLanes(!model.allLanesAreOn)
        } label: {
            Text(model.allLanesAreOn ? "None" : "All")
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 34)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(minHeight: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.16))
                }
        }
        .buttonStyle(.plain)
        .help(model.allLanesAreOn ? "⌘0 — turn every source off" : "⌘0 — turn every source on")
    }

    /// The scope switch sits in the panel itself, not behind a menu — reaching it has to be
    /// cheaper than retyping the search somewhere else.
    @ViewBuilder
    private var scopeControl: some View {
        if model.enabledLanes.contains(.files) {
            if let folder = model.focusedFolderName {
                Button {
                    model.escape()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                        Text(folder).lineLimit(1)
                        Image(systemName: "xmark.circle.fill").opacity(0.6)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Picker("", selection: $model.scope) {
                    ForEach(SearchScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - Results

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain VStack, not a lazy one. A LazyVStack recycles its row views, and with
                // a heterogeneous list — headings, notices and six kinds of result — it was
                // handing a row of one type the view built for another: mail results drawn as
                // messages, headings sitting over the wrong section. At forty rows there is
                // nothing to gain from laziness anyway.
                VStack(alignment: .leading, spacing: 2) {
                    // Every item carries the same kind of identity — its own id, applied once,
                    // to whatever it draws. Giving only some of them an explicit `.id` left
                    // SwiftUI matching rows to the wrong items when the list changed shape.
                    ForEach(model.displayItems) { item in
                        itemView(item)
                            .id(item.id)
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: model.selection) { _, _ in
                guard let id = model.selectedItemID else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: PanelItem) -> some View {
        switch item {
        case .header(let lane, let count, let total):
            SectionHeader(
                lane: lane,
                count: count,
                total: total,
                isSoloed: model.soloedLane == lane,
                onSolo: { model.soloLane(lane) },
                onShowAll: { model.showAllSources() }
            )

        case .status(let lane, let status):
            LaneStatusView(status: status, lane: lane) {
                // Which prompt to raise is decided by the notice that offered it, not by the
                // lane — Contacts and Reminders are the only two macOS lets an app ask about.
                switch status {
                case .remindersNotAsked: model.requestRemindersAccess()
                default: model.requestContactsAccess()
                }
            }

        case .row(let row, let index):
            PanelRowView(row: row, selected: model.selection == index)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selection = index
                    model.activate()
                }

        case .indexing(_, let done, let total):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading your mail so it can be searched by what it says — \(done.formatted()) of \(total.formatted())")
                Spacer()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

        case .showMore(let lane, let remaining):
            Button {
                model.showMore(lane)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    Text("Show more — ^[\(remaining) more result](inflect: true)")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

        case .hiddenNotice:
            hiddenNotice
        }
    }

    /// Excluded matches are counted, never silently dropped — otherwise "no results" and
    /// "results you can't see" look identical.
    private var hiddenNotice: some View {
        Button {
            model.showHidden.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                Text(model.showHidden
                     ? "Showing developer and system matches"
                     : "^[\(model.hiddenCount) match](inflect: true) in developer and system folders hidden")
                Spacer()
                Text(model.showHidden ? "Hide" : "Show").fontWeight(.semibold)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
    }

    /// "Nothing matched" has to be distinguishable from "still searching" and from "not allowed
    /// to look" — the same blank list otherwise stands for all three.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Nothing matches “\(model.text)”.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            if model.enabledLanes.contains(.files), model.scope == .myFiles {
                Button("Search the whole Mac") { model.toggleScope() }
                    .buttonStyle(.link)
                    .font(.system(size: 13))
            }
        }
        // Greedy, so it centres in the whole panel rather than shrink-wrapping into a band.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Everything switched off. A deliberate state — it is how you get to one source in two
    /// clicks — so it explains itself rather than looking like a search that found nothing.
    private var noSourcesState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.dashed")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No sources are switched on.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Button("Turn them all back on") { model.setAllLanes(true) }
                .buttonStyle(.link)
                .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Before anything is typed. Says which sources are on, so an empty panel still answers the
    /// question "what is this about to search".
    private var idleState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("Start typing")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text(sourceSummary)
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private var sourceSummary: String {
        let names = model.orderedLanes
            .filter { model.enabledLanes.contains($0) }
            .map(\.title)
        guard !names.isEmpty else { return "No sources are switched on." }
        guard names.count > 1 else { return "Searching \(names[0])." }
        return "Searching " + names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1] + "."
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 16) {
            KeyHint("return", "Open")
            KeyHint("⌘return", "Reveal in Finder")
            KeyHint("tab", "Search inside folder")
            KeyHint("⌘1–8", "Sources")
            KeyHint("⌥↑↓", "Section")

            Spacer()

            // Only while the shortcut is still Spotlight's. Once it isn't, this disappears
            // rather than becoming a button that does nothing useful.
            if model.showsCommandSpaceHint {
                HStack(spacing: 6) {
                    Text("⌘-Space opens Spotlight")
                    Button("Hand it to Scout") { model.openSpotlightShortcutSettings() }
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .underline()
                        .help("Opens Keyboard settings. Click \u{201C}Keyboard Shortcuts\u{2026}\u{201D}, choose Spotlight on the left, untick \u{201C}Show Spotlight search\u{201D}.")
                    Button {
                        model.dismissCommandSpaceHint()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Stop offering. \u{2325}-Space keeps working.")
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .foregroundStyle(.secondary)
            }

            Button {
                model.resetPanelGeometry()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Put the panel back to its default size and position")

            Button {
                model.openSettings()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                    Text("Settings")
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Scout's settings, including permissions")

            KeyHint("esc", "Dismiss")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

// MARK: - Pieces

/// Lays its children out left to right, starting a new line when the next one will not fit.
///
/// SwiftUI has no wrapping stack, and the alternative — letting an HStack squeeze — makes the
/// source names illegible before it makes them fit.
private struct SourceFlow: Layout {

    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, max(widest, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// Where the source buttons are, so a drag knows what it is passing over.
private struct SourceFramesKey: PreferenceKey {
    static var defaultValue: [SearchLane: CGRect] { [:] }

    static func reduce(value: inout [SearchLane: CGRect], nextValue: () -> [SearchLane: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The row of source switches, which is also the row you rearrange.
///
/// One gesture does both jobs. `.draggable` on a `Button` does not work here — the button claims
/// the press and the drag never starts — so there is no button: a press that never travels more
/// than a few points is a click, and one that does is a drag. Sources shuffle out of the way as
/// the dragged one passes over them, rather than waiting for a drop.
private struct SourceStrip: View {

    @Bindable var model: SearchModel
    let style: SourceButtonStyle

    private static let space = "sourceStrip"
    /// How far the mouse has to travel before a click becomes a drag.
    private static let threshold: CGFloat = 5

    @State private var frames: [SearchLane: CGRect] = [:]
    @State private var dragged: SearchLane?
    @State private var offset: CGSize = .zero

    var body: some View {
        SourceFlow(spacing: 7) {
            ForEach(model.orderedLanes) { lane in
                SourceButton(
                    lane: lane,
                    number: model.number(for: lane),
                    style: style,
                    isOn: model.enabledLanes.contains(lane),
                    isDragging: dragged == lane
                )
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: SourceFramesKey.self,
                            value: [lane: geometry.frame(in: .named(Self.space))]
                        )
                    }
                )
                .offset(dragged == lane ? offset : .zero)
                .zIndex(dragged == lane ? 1 : 0)
                .gesture(gesture(for: lane))
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(SourceFramesKey.self) { frames = $0 }
    }

    private func gesture(for lane: SearchLane) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragged == nil {
                    let travelled = max(abs(value.translation.width), abs(value.translation.height))
                    guard travelled > Self.threshold else { return }
                    dragged = lane
                }
                guard dragged == lane, let home = frames[lane] else { return }

                // Measured against where the button sits *now*, so it keeps following the cursor
                // after the row has rearranged underneath it.
                offset = CGSize(width: value.location.x - home.midX,
                                height: value.location.y - home.midY)

                if let over = frames.first(where: { $0.key != lane && $0.value.contains(value.location) })?.key {
                    withAnimation(.easeOut(duration: 0.16)) { model.moveLane(lane, before: over) }
                }
            }
            .onEnded { _ in
                // A press that never travelled is a click, and clicking is what these are for.
                let wasDrag = dragged != nil
                withAnimation(.easeOut(duration: 0.16)) {
                    dragged = nil
                    offset = .zero
                }
                if !wasDrag { model.toggleLane(lane) }
            }
    }
}

/// A source switch. Drawn as a real button — raised, bordered, and obviously filled when on —
/// because a row of bare words does not read as something you can press.
private struct SourceButton: View {

    let lane: SearchLane
    let number: Int?
    let style: SourceButtonStyle
    let isOn: Bool
    let isDragging: Bool

    @State private var hovering = false

    var body: some View {
        Group {
            HStack(spacing: 6) {
                if style.showsIcon {
                    Image(systemName: lane.symbol)
                        .font(.system(size: 11, weight: .semibold))
                }
                if style.showsText {
                    Text(lane.title)
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .padding(.horizontal, style == .iconOnly ? 9 : 12)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isOn ? Color.clear : Color.primary.opacity(hovering ? 0.28 : 0.16))
            }
            .foregroundStyle(isOn ? Color.white : .primary)
            // Lifted off the row while it is being carried, so it is obvious which one is moving.
            .shadow(color: .black.opacity(isDragging ? 0.35 : (isOn ? 0.18 : 0.06)),
                    radius: isDragging ? 6 : 1, y: isDragging ? 3 : 1)
            .scaleEffect(isDragging ? 1.05 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(lane.title))
    }

    private var helpText: String {
        let key = number.map { "⌘\($0) — " } ?? ""
        return key + "turn \(lane.title) \(isOn ? "off" : "on"). Drag to reorder."
    }
}

private struct SectionHeader: View {
    let lane: SearchLane
    let count: Int
    let total: Int
    /// True when this source is already the only one showing.
    let isSoloed: Bool
    let onSolo: () -> Void
    let onShowAll: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: lane.symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(lane.title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
            if count > 0 {
                // "12 of 2,367" rather than a bare 12 — the difference between "that's all
                // there is" and "there is plenty more".
                Text(total > count ? "\(count) of \(total.formatted())" : "\(count)")
                    .font(.system(size: 10, design: .monospaced))
                    .opacity(0.7)
            }
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)

            // The way out of a long list: take the source you meant and drop the other seven.
            if isSoloed {
                link("Show all sources", action: onShowAll)
            } else if count > 0 {
                link("Show only \(lane.title)", action: onSolo)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.regularMaterial)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .underline()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

private struct KeyHint: View {
    let key: String
    let label: String

    init(_ key: String, _ label: String) {
        self.key = key
        self.label = label
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }
}
