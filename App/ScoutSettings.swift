import AppKit
import Foundation
import Observation
import ServiceManagement
import ScoutCore

/// Everything the user can change, kept in one place and written straight through to disk.
///
/// Nothing here is specific to one Mac or one person: scopes, pinned folders and exclusions are
/// all settings precisely so Scout behaves the same on a stranger's machine as on the one it was
/// built on.
@MainActor
@Observable
final class ScoutSettings {

    static let shared = ScoutSettings()

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        defaultScope = SearchScope(rawValue: store.string(forKey: Key.defaultScope) ?? "") ?? .myFiles
        pinnedPlaces = (store.stringArray(forKey: Key.pinnedPlaces) ?? []).map { URL(filePath: $0) }
        customExclusions = (store.stringArray(forKey: Key.customExclusions) ?? []).map { URL(filePath: $0) }
        excludeDeveloperFolders = store.object(forKey: Key.excludeDeveloper) as? Bool ?? true
        excludeSystemFolders = store.object(forKey: Key.excludeSystem) as? Bool ?? true
        pinExactAppMatch = store.object(forKey: Key.pinExactAppMatch) as? Bool ?? true

        // Files, Contacts, Mail, Messages and Apps on; System off, because it is the one people
        // reach for deliberately rather than constantly.
        let saved = store.stringArray(forKey: Key.enabledLanes)?.compactMap(SearchLane.init(rawValue:))
        enabledLanes = Set(saved ?? [.files, .contacts, .mail, .messages, .apps])
        hasSeenWelcome = store.bool(forKey: Key.hasSeenWelcome)

        if let saved = store.string(forKey: Key.panelFrame) {
            let rect = NSRectFromString(saved)
            panelFrame = rect.width > 0 ? rect : nil
        } else {
            panelFrame = nil
        }
    }

    private enum Key {
        static let defaultScope = "defaultScope"
        static let pinnedPlaces = "pinnedPlaces"
        static let customExclusions = "customExclusions"
        static let excludeDeveloper = "excludeDeveloperFolders"
        static let excludeSystem = "excludeSystemFolders"
        static let pinExactAppMatch = "pinExactAppMatch"
        static let enabledLanes = "enabledLanes"
        static let hasSeenWelcome = "hasSeenWelcome"
        static let panelFrame = "panelFrame"
    }

    /// Which scope the panel opens on.
    var defaultScope: SearchScope {
        didSet { store.set(defaultScope.rawValue, forKey: Key.defaultScope) }
    }

    /// Folders that always get a chip, whether or not this search found anything in them.
    var pinnedPlaces: [URL] {
        didSet { store.set(pinnedPlaces.map(\.path), forKey: Key.pinnedPlaces) }
    }

    var customExclusions: [URL] {
        didSet { store.set(customExclusions.map(\.path), forKey: Key.customExclusions) }
    }

    var excludeDeveloperFolders: Bool {
        didSet { store.set(excludeDeveloperFolders, forKey: Key.excludeDeveloper) }
    }

    var excludeSystemFolders: Bool {
        didSet { store.set(excludeSystemFolders, forKey: Key.excludeSystem) }
    }

    /// Which sources the panel searches. Remembered, so the set you use is the set you get.
    var enabledLanes: Set<SearchLane> {
        didSet { store.set(enabledLanes.map(\.rawValue), forKey: Key.enabledLanes) }
    }

    /// Typing an app's name exactly puts that app at the top of the file results.
    var pinExactAppMatch: Bool {
        didSet { store.set(pinExactAppMatch, forKey: Key.pinExactAppMatch) }
    }

    var hasSeenWelcome: Bool {
        didSet { store.set(hasSeenWelcome, forKey: Key.hasSeenWelcome) }
    }

    /// Where the panel was left, in size and position. Nil until it has been moved or resized
    /// once, which is what lets the first appearance be a sensible default instead.
    var panelFrame: NSRect? {
        didSet {
            if let panelFrame {
                store.set(NSStringFromRect(panelFrame), forKey: Key.panelFrame)
            } else {
                store.removeObject(forKey: Key.panelFrame)
            }
        }
    }

    /// The exclusions a file search runs with, assembled from the switches above.
    var exclusions: Exclusions {
        Exclusions(
            excludeHidden: true,
            excludeDeveloperNoise: excludeDeveloperFolders,
            excludeSystemInternals: excludeSystemFolders,
            userExcluded: customExclusions
        )
    }

    // MARK: - Launch at login

    /// Read straight from the system rather than mirrored into a preference, so it stays true
    /// even when the user turns it off in System Settings instead of here.
    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchesAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Whether macOS is still handing ⌘-Space to Spotlight.
///
/// There is no API to ask, and no way for an app to change it — the user has to untick a box in
/// System Settings. What Scout can do is read the same preference the box writes, so it can stop
/// nagging once the job is done.
enum SpotlightShortcut {

    /// The identifier macOS uses for "Show Spotlight search" in its symbolic hotkeys table.
    private static let showSpotlightSearch = "64"

    static var isEnabled: Bool {
        guard let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let hotKeys = defaults.dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = hotKeys[showSpotlightSearch] as? [String: Any],
              let enabled = entry["enabled"] as? Bool
        else {
            // No entry means the shortcut has never been changed, which means it is on.
            return true
        }
        return enabled
    }
}
