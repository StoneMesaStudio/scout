import Foundation

/// The five things Scout can search, each on its own key.
///
/// They are lanes rather than sections because results never mix: a file search returns files,
/// and mail only answers when asked. Blending them is what makes a search box feel like it is
/// guessing, and guessing is the thing being replaced.
public enum SearchLane: String, CaseIterable, Identifiable, Sendable {
    case files
    case mail
    case messages
    case apps
    case system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .files: "Files"
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
        case .mail: "envelope"
        case .messages: "message"
        case .apps: "square.grid.2x2"
        case .system: "gearshape"
        }
    }

    /// ⌘1 … ⌘5, in declaration order.
    public var shortcut: String {
        String((Self.allCases.firstIndex(of: self) ?? 0) + 1)
    }

    /// Only the files lane has scopes; the rest search their whole store.
    public var hasScopes: Bool { self == .files }
}
