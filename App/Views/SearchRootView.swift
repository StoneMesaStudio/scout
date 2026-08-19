import SwiftUI
import ScoutCore

/// The panel: a field, a scope switch, results, and a line of keys along the bottom.
struct SearchRootView: View {

    @Bindable var model: SearchModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider().opacity(0.6)
            if model.rowCount > 0 || model.hiddenCount > 0 {
                resultsList
                Divider().opacity(0.6)
            }
            footer
        }
        .frame(width: 680)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .onAppear { fieldFocused = true }
    }

    // MARK: - Field

    private var field: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search", text: $model.text)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .regular))
                .focused($fieldFocused)

            scopeControl
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
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
        // ⌘L flips the scope without leaving the keyboard.
        .onKeyPress(keys: ["l"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            model.toggleScope()
            return .handled
        }
    }

    /// The scope switch sits in the field itself, not behind a menu — reaching it has to be
    /// cheaper than retyping the search somewhere else.
    @ViewBuilder
    private var scopeControl: some View {
        if let folder = model.focusedFolderName {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text(folder).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
        } else {
            Picker("", selection: $model.scope) {
                ForEach(SearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .font(.system(size: 12))
        }
    }

    // MARK: - Results

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if let app = model.pinnedApp {
                        PinnedAppRow(app: app, selected: model.selection == 0)
                            .id(0)
                    }

                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                        let row = index + (model.pinnedApp == nil ? 0 : 1)
                        ResultRow(result: result, selected: model.selection == row)
                            .id(row)
                    }

                    if model.hiddenCount > 0 {
                        hiddenNotice
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 420)
            .onChange(of: model.selection) { _, new in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
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
            .font(.system(size: 12))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            KeyHint("return", "Open")
            KeyHint("⌘return", "Reveal in Finder")
            KeyHint("tab", "Search inside folder")
            Spacer()
            KeyHint("esc", "Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
                .font(.system(size: 10.5, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}
