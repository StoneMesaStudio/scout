// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

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

        // Files, Contacts, Mail, Messages, Apps, Notes and Reminders on; System off, because it
        // is the one people reach for deliberately rather than constantly.
        let saved = store.stringArray(forKey: Key.enabledLanes)?.compactMap(SearchLane.init(rawValue:))
        var lanes = Set(saved ?? Self.defaultLanes)

        // A source added after someone started using Scout is not in their saved set, so without
        // this it would ship switched off and look like it was never built. Each new batch bumps
        // the version and is added once; anything they then switch off stays off.
        let version = store.integer(forKey: Key.enabledLanesVersion)
        if saved != nil, version < Self.lanesVersion {
            lanes.formUnion([.notes, .reminders])
            store.set(lanes.map(\.rawValue), forKey: Key.enabledLanes)
        }
        store.set(Self.lanesVersion, forKey: Key.enabledLanesVersion)
        enabledLanes = lanes
        laneOrder = SearchLane.ordered(from: store.stringArray(forKey: Key.laneOrder) ?? [])
        resultsPerSource = store.object(forKey: Key.resultsPerSource) as? Int ?? Self.defaultResultsPerSource
        // Words by default. The discs wear each app's real icon, which is a stronger label than
        // most icon rows manage — but two of the eight are not the app whose contents the source
        // searches, "click the yellow one" is not a sentence anybody should have to say down a
        // phone, and the number under a button is its position rather than its name, so the
        // shortcut cannot stand in either. The icons are one setting away for whoever wants them.
        sourceButtonStyle = SourceButtonStyle(rawValue: store.string(forKey: Key.sourceButtonStyle) ?? "")
            ?? .textOnly
        hasSeenWelcome = store.bool(forKey: Key.hasSeenWelcome)
        hasAskedForFolders = store.bool(forKey: Key.hasAskedForFolders)
        hideCommandSpaceHint = store.bool(forKey: Key.hideCommandSpaceHint)
        searchMailBodies = store.object(forKey: Key.searchMailBodies) as? Bool ?? true

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
        static let enabledLanesVersion = "enabledLanesVersion"
        static let laneOrder = "laneOrder"
        static let resultsPerSource = "resultsPerSource"
        static let sourceButtonStyle = "sourceButtonStyle"
        static let hasSeenWelcome = "hasSeenWelcome"
        static let hasAskedForFolders = "hasAskedForFolders"
        static let panelFrame = "panelFrame"
        static let hideCommandSpaceHint = "hideCommandSpaceHint"
        static let searchMailBodies = "searchMailBodies"
    }

    /// What a Mac that has never run Scout starts with.
    private static let defaultLanes: [SearchLane] = [.files, .contacts, .mail, .messages, .apps, .notes, .reminders]

    /// Bumped whenever a source is added, so existing installs pick it up exactly once.
    private static let lanesVersion = 2

    /// How many results each source shows before offering the rest. Ten rather than twenty-five:
    /// the point of the panel is a list you can take in at a glance, with the whole lot one click
    /// away when you want it.
    static let defaultResultsPerSource = 10

    /// The numbers offered in Settings.
    static let resultsPerSourceChoices = [5, 10, 15, 25, 50]

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
    /// May be empty: turning everything off and then clicking the one you want is a faster way
    /// to get to a single source than switching seven off one at a time.
    var enabledLanes: Set<SearchLane> {
        didSet { store.set(enabledLanes.map(\.rawValue), forKey: Key.enabledLanes) }
    }

    /// The order the source buttons sit in, which is also the order their results appear in.
    ///
    /// Dragged by the user. The number on a button is its position here, so reordering moves the
    /// ⌘-numbers with it — which is the point: the number means "where it sits".
    var laneOrder: [SearchLane] {
        didSet { store.set(laneOrder.map(\.rawValue), forKey: Key.laneOrder) }
    }

    /// Move one source to a position in the row, and report whether anything actually changed.
    ///
    /// `index` is a gap between buttons, counted before the move — the same way an insertion
    /// point is drawn — so pulling something out from the left shifts every later gap down one.
    @discardableResult
    func moveLane(_ lane: SearchLane, to index: Int) -> Bool {
        guard let from = laneOrder.firstIndex(of: lane) else { return false }
        var updated = laneOrder
        updated.remove(at: from)
        let target = min(max(0, index > from ? index - 1 : index), updated.count)
        updated.insert(lane, at: target)
        guard updated != laneOrder else { return false }
        laneOrder = updated
        return true
    }

    /// Put the buttons back the way they shipped.
    func resetLaneOrder() {
        laneOrder = SearchLane.allCases
    }

    /// How many results each source shows before offering the rest.
    var resultsPerSource: Int {
        didSet { store.set(resultsPerSource, forKey: Key.resultsPerSource) }
    }

    /// Icons, labels, or both — the same three choices Mail's toolbar offers, on the same
    /// right-click menu.
    var sourceButtonStyle: SourceButtonStyle {
        didSet { store.set(sourceButtonStyle.rawValue, forKey: Key.sourceButtonStyle) }
    }

    /// Typing an app's name exactly puts that app at the top of the file results.
    var pinExactAppMatch: Bool {
        didSet { store.set(pinExactAppMatch, forKey: Key.pinExactAppMatch) }
    }

    /// Whether Scout has put the Documents, Desktop and Downloads question to the user at a
    /// moment of its own choosing. See `AppDelegate.askAboutFoldersOnce`.
    var hasAskedForFolders: Bool {
        didSet { store.set(hasAskedForFolders, forKey: Key.hasAskedForFolders) }
    }

    var hasSeenWelcome: Bool {
        didSet { store.set(hasSeenWelcome, forKey: Key.hasSeenWelcome) }
    }

    /// Dismisses the footer's offer to hand ⌘-Space over. ⌥-Space is a perfectly good shortcut,
    /// and a permanent nag about a choice already made is just noise.
    var hideCommandSpaceHint: Bool {
        didSet { store.set(hideCommandSpaceHint, forKey: Key.hideCommandSpaceHint) }
    }

    /// Search what messages say, not only their subjects and senders. Requires Scout to keep an
    /// index of its own over the message files, which is built once and then kept up.
    var searchMailBodies: Bool {
        didSet { store.set(searchMailBodies, forKey: Key.searchMailBodies) }
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

/// How the source buttons are drawn.
enum SourceButtonStyle: String, CaseIterable, Identifiable {
    case iconAndText
    case iconOnly
    case textOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconAndText: "Icon and Text"
        case .iconOnly: "Icon Only"
        case .textOnly: "Text Only"
        }
    }

    var showsIcon: Bool { self != .textOnly }
    var showsText: Bool { self != .iconOnly }
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
