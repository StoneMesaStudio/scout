import SwiftUI
import ScoutCore

/// The panel: a field, the source buttons, the chips, grouped results, and a line of keys along
/// the bottom.
struct SearchRootView: View {

    @Bindable var model: SearchModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field
            sourceBar
            Divider().opacity(0.5)

            if model.hasChips {
                FilterChipRow(model: model)
                Divider().opacity(0.5)
            }

            // The results area always claims the space left over, so the panel keeps its shape
            // whether it is showing sixty rows, none, or nothing typed yet.
            Group {
                if !model.sections.isEmpty {
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
        .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
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
        // ⌘L flips the file scope, ⌘1…⌘6 switch a source on or off.
        .onKeyPress(keys: ["l", "1", "2", "3", "4", "5", "6"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            if press.key.character == "l" {
                model.toggleScope()
            } else if let number = Int(String(press.key.character)) {
                model.toggleLane(number: number)
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
        HStack(spacing: 7) {
            ForEach(SearchLane.allCases) { lane in
                SourceButton(
                    lane: lane,
                    isOn: model.enabledLanes.contains(lane)
                ) {
                    model.toggleLane(lane)
                }
            }

            Spacer()
            scopeControl
        }
        .padding(.horizontal, 17)
        .padding(.bottom, 12)
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
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.sections) { section in
                        Section {
                            sectionBody(section)
                        } header: {
                            SectionHeader(lane: section.lane, count: section.rows.count)
                        }
                    }

                    if model.enabledLanes.contains(.files), model.hiddenCount > 0 {
                        hiddenNotice
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: model.selection) { _, new in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func sectionBody(_ section: PanelSection) -> some View {
        if section.status != .ready {
            LaneStatusView(status: section.status, lane: section.lane) {
                model.requestContactsAccess()
            }
        } else {
            let start = model.startIndex(of: section)
            ForEach(Array(section.rows.enumerated()), id: \.element.id) { offset, row in
                let index = start + offset
                PanelRowView(row: row, selected: model.selection == index)
                    .id(index)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.selection = index
                        model.activate()
                    }
            }
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
        let names = SearchLane.allCases
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
            KeyHint("⌘1–6", "Sources")

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

/// A source switch. Drawn as a real button — raised, bordered, and obviously filled when on —
/// because a row of bare words does not read as something you can press.
private struct SourceButton: View {

    let lane: SearchLane
    let isOn: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: lane.symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(lane.title)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 12)
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
            .shadow(color: .black.opacity(isOn ? 0.18 : 0.06), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("⌘\(lane.shortcut) — turn \(lane.title) \(isOn ? "off" : "on")")
    }
}

private struct SectionHeader: View {
    let lane: SearchLane
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: lane.symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(lane.title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, design: .monospaced))
                    .opacity(0.7)
            }
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.regularMaterial)
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
