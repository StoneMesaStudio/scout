import Foundation

/// One thing found on disk, with the attributes ranking needs and the display needs.
public struct SearchResult: Identifiable, Sendable, Hashable {

    public enum Kind: String, Sendable, Hashable {
        case folder
        case file
        case application
    }

    public let url: URL
    public let displayName: String
    public let kind: Kind
    /// Uniform type identifier, e.g. `com.adobe.pdf`. Used for the Kind filters.
    public let contentType: String?
    public let modified: Date?
    /// When the user last opened it. Absent for most files; a strong signal when present.
    public let lastUsed: Date?
    public let size: Int64?
    /// Set when several identical copies collapsed into this one row.
    public var duplicateCount: Int
    /// The other copies, kept so the row can expand.
    public var duplicates: [URL]

    public init(
        url: URL,
        displayName: String,
        kind: Kind,
        contentType: String? = nil,
        modified: Date? = nil,
        lastUsed: Date? = nil,
        size: Int64? = nil,
        duplicateCount: Int = 1,
        duplicates: [URL] = []
    ) {
        self.url = url
        self.displayName = displayName
        self.kind = kind
        self.contentType = contentType
        self.modified = modified
        self.lastUsed = lastUsed
        self.size = size
        self.duplicateCount = duplicateCount
        self.duplicates = duplicates
    }

    public var id: URL { url }

    /// The folder the item sits in, as a breadcrumb: `iCloud Drive › Vehicles › Ford F350`.
    public func breadcrumb(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        var components = url.deletingLastPathComponent().pathComponents
        let homeParts = home.pathComponents

        if components.starts(with: SearchScope.iCloudDrive(home: home).pathComponents) {
            components = ["iCloud Drive"] + components.dropFirst(SearchScope.iCloudDrive(home: home).pathComponents.count)
        } else if components.starts(with: homeParts) {
            components = Array(components.dropFirst(homeParts.count))
        } else {
            components = components.filter { $0 != "/" }
        }

        // Long paths get elided in the middle — the first and last two carry the meaning.
        if components.count > 4 {
            components = [components[0], "…"] + components.suffix(2)
        }
        return components.joined(separator: " › ")
    }
}
