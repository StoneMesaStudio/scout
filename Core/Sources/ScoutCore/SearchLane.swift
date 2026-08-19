import Foundation

/// The six things Scout can search.
///
/// Several can be on at once and each keeps its own section, so a search that covers files, mail
/// and contacts still shows three labelled groups rather than one interleaved pile. Which ones are
/// on is remembered between searches.
public enum SearchLane: String, CaseIterable, Identifiable, Sendable {
    case files
    case contacts
    case mail
    case messages
    case apps
    case system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .files: "Files"
        case .contacts: "Contacts"
        case .mail: "Mail"
        case .messages: "Messages"
        case .apps: "Apps"
        case .system: "System"
        }
    }

    /// SF Symbol shown beside the lane name.
    public var symbol: String {
        switch self {
        case .files: "doc"
        case .contacts: "person.crop.circle"
        case .mail: "envelope"
        case .messages: "message"
        case .apps: "square.grid.2x2"
        case .system: "gearshape"
        }
    }

    /// ⌘1 … ⌘6, in declaration order.
    public var shortcut: String {
        String((Self.allCases.firstIndex(of: self) ?? 0) + 1)
    }

    /// Only the files lane has scopes; the rest search their whole store.
    public var hasScopes: Bool { self == .files }
}
