import Foundation

/// The System lane: System Settings panes, found by scanning the ones this Mac actually has.
///
/// Scanning rather than shipping a list means the lane does not rot when Apple renames or moves a
/// pane in the next macOS. The handful of panes built into System Settings itself — Wi-Fi, General,
/// Privacy & Security, Storage — have no bundle on disk to find, so they are named here.
public struct SettingsPaneIndex: Sendable {

    public struct Pane: Sendable, Hashable, Identifiable {
        public let identifier: String
        public let name: String
        /// Extra words that should match this pane: "location services" finds Privacy & Security.
        public let keywords: [String]

        public var id: String { identifier }

        /// The URL that opens this pane. System Settings registers this scheme.
        public var url: URL? {
            URL(string: "x-apple.systempreferences:\(identifier)")
        }

        public init(identifier: String, name: String, keywords: [String] = []) {
            self.identifier = identifier
            self.name = name
            self.keywords = keywords
        }
    }

    public private(set) var panes: [Pane]

    public init(panes: [Pane]) {
        self.panes = panes
    }

    public static let extensionsDirectory = URL(filePath: "/System/Library/ExtensionKit/Extensions")

    /// Panes that live inside System Settings.app rather than as their own bundle, so a directory
    /// scan will never find them.
    public static let builtIn: [Pane] = [
        Pane(identifier: "com.apple.wifi-settings-extension", name: "Wi-Fi",
             keywords: ["network", "wireless", "internet"]),
        Pane(identifier: "com.apple.systempreferences.GeneralSettings", name: "General",
             keywords: ["about", "storage", "airdrop", "language"]),
        Pane(identifier: "com.apple.settings.PrivacySecurity.extension", name: "Privacy & Security",
             keywords: ["full disk access", "location services", "permissions", "gatekeeper", "firewall"]),
        Pane(identifier: "com.apple.settings.Storage", name: "Storage",
             keywords: ["disk space", "free space"]),
    ]

    /// Read the settings extensions installed on this Mac.
    public static func scan(directory: URL = extensionsDirectory) -> SettingsPaneIndex {
        let fm = FileManager.default
        var panes = builtIn

        let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            ?? []

        for url in contents where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url),
                  let identifier = bundle.bundleIdentifier,
                  isSettingsPane(identifier)
            else { continue }

            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent

            guard !name.isEmpty else { continue }
            panes.append(Pane(identifier: identifier, name: nameOverrides[identifier] ?? name))
        }

        // Two bundles occasionally claim the same identifier; keep the first and sort by name.
        var seen: Set<String> = []
        let unique = panes.filter { seen.insert($0.identifier).inserted }
        return SettingsPaneIndex(panes: unique.sorted { $0.name < $1.name })
    }

    /// A few bundles carry an internal name rather than the one System Settings shows.
    static let nameOverrides: [String: String] = [
        "com.apple.HeadphoneSettings": "Headphones",
        "com.apple.Battery-Settings.extension": "Battery",
    ]

    /// Settings panes end in `-Settings.extension`; everything else in that directory is a widget,
    /// an App Intents helper, or an unrelated system extension.
    static func isSettingsPane(_ identifier: String) -> Bool {
        guard identifier.hasSuffix("-Settings.extension") else {
            // A few panes predate the naming convention.
            return ["com.apple.BluetoothSettings", "com.apple.HeadphoneSettings"].contains(identifier)
        }
        // Exclude the App Intents siblings, which share the prefix but are not panes.
        return !identifier.contains(".intents")
    }

    public func matches(for query: String) -> [Pane] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !needle.isEmpty else { return panes }

        func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }

        // Name matches first, then keyword matches — a pane found by its own name is a better
        // answer than one found by a synonym.
        let byName = panes.filter { fold($0.name).contains(needle) }
        let byKeyword = panes.filter { pane in
            !byName.contains(pane) && pane.keywords.contains { fold($0).contains(needle) }
        }
        return byName + byKeyword
    }
}
