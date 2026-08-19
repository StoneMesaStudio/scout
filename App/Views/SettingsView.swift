import AppKit
import SwiftUI
import ScoutCore

struct SettingsView: View {

    @State private var settings = ScoutSettings.shared

    var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            PlacesSettings(settings: settings)
                .tabItem { Label("Places", systemImage: "folder") }
            PermissionSettings()
                .tabItem { Label("Permissions", systemImage: "lock") }
        }
        .frame(width: 520, height: 400)
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

private struct PermissionSettings: View {

    @State private var spotlightOwnsCommandSpace = SpotlightShortcut.isEnabled

    var body: some View {
        Form {
            Section("The ⌘-Space shortcut") {
                if spotlightOwnsCommandSpace {
                    Text("macOS is still giving ⌘-Space to Spotlight. Until you turn that off, use ⌥-Space to open Scout — both work.")
                        .font(.callout)
                    Text("In Keyboard Shortcuts, choose Spotlight and untick “Show Spotlight search”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Keyboard Shortcuts") {
                        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
                    }
                } else {
                    Label("⌘-Space opens Scout.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text("⌥-Space works too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Check again") { spotlightOwnsCommandSpace = SpotlightShortcut.isEnabled }
                    .buttonStyle(.link)
            }

            Section("Mail and Messages") {
                Text("macOS keeps mail and messages locked away from every app until you say otherwise. Scout reads them on this Mac only, and sends nothing anywhere.")
                    .font(.callout)
                Button("Open Full Disk Access") {
                    open("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { spotlightOwnsCommandSpace = SpotlightShortcut.isEnabled }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
