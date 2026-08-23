import AppKit
import SwiftUI
import ScoutCore

struct SettingsView: View {

    enum Tab: Hashable, Sendable {
        case general, places, permissions
    }

    /// When something else opens Settings to make a particular point — a permission that needs
    /// granting — it says which page to land on.
    var initialTab: Tab = .general
    /// Ask the Permissions page to raise a prompt as soon as it appears.
    var requestOnAppear: String?

    @State private var settings = ScoutSettings.shared
    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            PlacesSettings(settings: settings)
                .tabItem { Label("Places", systemImage: "folder") }
                .tag(Tab.places)
            PermissionSettings(requestOnAppear: requestOnAppear)
                .tabItem { Label("Permissions", systemImage: "lock") }
                .tag(Tab.permissions)
        }
        .frame(width: 580, height: 470)
        .onAppear { tab = initialTab }
    }
}

// MARK: - General

private struct GeneralSettings: View {

    @Bindable var settings: ScoutSettings
    @State private var launchAtLogin = ScoutSettings.shared.launchesAtLogin
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker("Open on:", selection: $settings.defaultScope) {
                    ForEach(SearchScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Text("My Files covers Documents, iCloud Drive, Desktop and Downloads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Put an exactly-matching app at the top", isOn: $settings.pinExactAppMatch)
                Text("Typing “Mail” and pressing return launches Mail, the way ⌘-Space always has.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Leave out of file results") {
                Toggle("Developer folders", isOn: $settings.excludeDeveloperFolders)
                Text("node_modules, DerivedData, build folders and the like.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("System and library folders", isOn: $settings.excludeSystemFolders)
                Text("Apps and settings have their own lanes, so they stay out of file results.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Mail") {
                Toggle("Search what messages say, not just subjects and senders",
                       isOn: $settings.searchMailBodies)
                Text("Mail keeps no searchable copy of message text for other apps, so Scout builds one — reading each message once, then keeping up as mail arrives. Turning this off deletes it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                MailIndexStatus(enabled: settings.searchMailBodies)
            }

            Section("Notes") {
                Text("Notes keeps its text compressed and unreadable to anything but itself, which is why Spotlight cannot find a note by what it says. Scout reads each note once and keeps up as they change. Locked notes stay locked — only their titles are searchable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                NotesIndexStatus()
            }

            Section {
                Toggle("Start Scout when I log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, wanted in
                        do {
                            try settings.setLaunchesAtLogin(wanted)
                            loginError = nil
                        } catch {
                            launchAtLogin = settings.launchesAtLogin
                            loginError = error.localizedDescription
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// How far along the mail index is, and a way to start it over.
private struct MailIndexStatus: View {

    let enabled: Bool

    @State private var progress: MailBodyIndex.Progress?
    @State private var size: Int64 = 0
    @State private var working = false

    private let service = MailSearchService()
    private let heartbeat = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if !enabled {
                EmptyView()
            } else if let progress, !progress.isComplete {
                HStack(spacing: 8) {
                    ProgressView(value: Double(progress.indexed), total: Double(max(1, progress.total)))
                        .frame(width: 140)
                    Text("\(progress.indexed.formatted()) of \(progress.total.formatted()) messages read")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let progress {
                HStack(spacing: 8) {
                    Label("\(progress.indexed.formatted()) messages indexed", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                    if size > 0 {
                        Text("· \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Build again") {
                        working = true
                        Task {
                            await service.rebuildBodies()
                            await refresh()
                            working = false
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(working)
                }
            }
        }
        .task { await refresh() }
        .onReceive(heartbeat) { _ in Task { await refresh() } }
    }

    private func refresh() async {
        await service.setBodySearch(enabled)
        progress = await service.bodyProgress()
        size = await service.bodyIndexSize()
    }
}

/// How many notes are indexed, and a way to start over.
private struct NotesIndexStatus: View {

    @State private var count = 0
    @State private var working = false

    private let service = NotesSearchService()

    var body: some View {
        HStack(spacing: 8) {
            if count > 0 {
                Label("^[\(count) note](inflect: true) indexed", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("Nothing indexed yet — Full Disk Access is what this one waits on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Build again") {
                working = true
                Task {
                    await service.rebuild()
                    count = await service.indexedCount()
                    working = false
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(working)
        }
        .task {
            await service.prepare()
            count = await service.indexedCount()
        }
    }
}

// MARK: - Places

private struct PlacesSettings: View {

    @Bindable var settings: ScoutSettings

    var body: some View {
        Form {
            Section("Pinned places") {
                Text("Folders you search often. Each one gets a chip under the search field, whether or not this particular search found anything in it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                FolderList(
                    folders: $settings.pinnedPlaces,
                    addTitle: "Pin a folder…",
                    emptyMessage: "No pinned folders yet."
                )
            }

            Section("Never search") {
                Text("Anything inside these is left out of every file search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                FolderList(
                    folders: $settings.customExclusions,
                    addTitle: "Exclude a folder…",
                    emptyMessage: "Nothing excluded beyond the defaults."
                )
            }
        }
        .formStyle(.grouped)
    }
}

private struct FolderList: View {

    @Binding var folders: [URL]
    let addTitle: String
    let emptyMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if folders.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            ForEach(folders, id: \.self) { folder in
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(folder.lastPathComponent)
                    Text(folder.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button {
                        folders.removeAll { $0 == folder }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Button(addTitle, action: chooseFolder)
                .padding(.top, 2)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        for url in panel.urls where !folders.contains(url) {
            folders.append(url)
        }
    }
}

// MARK: - Permissions

/// Every permission Scout needs, what each one buys, whether it is on, and a button that does as
/// much as macOS allows an app to do about it.
///
/// The list re-checks itself while the window is open, so walking over to System Settings and
/// back is enough — there is nothing to press afterwards to make it notice.
private struct PermissionSettings: View {

    /// The id of a permission to ask about the moment this page appears.
    var requestOnAppear: String?

    @State private var center = PermissionCenter()
    @State private var busy: String?
    @State private var hasAutoRequested = false
    /// Held so the window can be put back after a permission prompt takes the front away.
    @State private var window: NSWindow?

    /// macOS gives no notification when a permission changes, so the only way to keep up with a
    /// trip to System Settings is to look again periodically.
    private let heartbeat = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Scout asks for as little as it can, and everything it reads stays on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)

                ForEach(center.permissions) { permission in
                    PermissionRow(permission: permission, busy: busy == permission.id) {
                        busy = permission.id
                        Task {
                            await center.act(on: permission)
                            busy = nil
                            comeBack()
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Check again") { center.refresh() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                .padding(.top, 2)
            }
            .padding(18)
        }
        .onAppear {
            center.refresh()
            guard !hasAutoRequested, let requestOnAppear,
                  let permission = center.permissions.first(where: { $0.id == requestOnAppear })
            else { return }
            hasAutoRequested = true
            busy = permission.id
            Task {
                await center.act(on: permission)
                busy = nil
                comeBack()
            }
        }
        .onReceive(heartbeat) { _ in center.refresh() }
        .background(WindowAccessor(window: $window))
    }

    /// Put Settings back in front after macOS has had its say.
    ///
    /// The prompt is the system's window, not Scout's. When it goes, macOS hands the front to
    /// whatever app was there before — and Scout, having no Dock icon, is not it. The window was
    /// never closed; it was buried, which looks the same and is more annoying.
    private func comeBack() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct PermissionRow: View {

    let permission: Permission
    let busy: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.symbol)
                .font(.system(size: 15))
                .foregroundStyle(permission.state.isGranted ? Color.green : .secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(permission.title)
                        .font(.system(size: 13.5, weight: .medium))
                    StatusPill(state: permission.state)
                }

                Text(permission.purpose)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let granted = permission.grantedOn {
                    Text("Allowed \(granted.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                // Full Disk Access is the one that cannot be prompted for, so it gets the steps
                // spelled out rather than a button and a shrug.
                if permission.id == "fullDisk", !permission.state.isGranted {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("1.  Click the button — it opens straight to Full Disk Access.")
                        Text("2.  Find Scout in the list and switch it on.")
                        Text("3.  If Scout isn’t listed, click + and pick it:")
                        Button("Reveal Scout in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11.5))
                        .padding(.leading, 18)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 8)

            Button(action: action) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(permission.buttonTitle)
                }
            }
            .disabled(busy)
            .frame(minWidth: 108)
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(permission.state.isGranted ? Color.green.opacity(0.35) : Color.primary.opacity(0.08))
        )
    }
}

private struct StatusPill: View {

    let state: Permission.State

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(label).font(.system(size: 10.5, weight: .semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.16), in: Capsule())
        .foregroundStyle(tint)
    }

    private var label: String {
        switch state {
        case .granted: "ALLOWED"
        case .notGranted: "NOT ALLOWED"
        case .notAsked: "NOT ASKED YET"
        }
    }

    private var symbol: String {
        switch state {
        case .granted: "checkmark"
        case .notGranted: "xmark"
        case .notAsked: "questionmark"
        }
    }

    private var tint: Color {
        switch state {
        case .granted: .green
        case .notGranted: .orange
        case .notAsked: .secondary
        }
    }
}
