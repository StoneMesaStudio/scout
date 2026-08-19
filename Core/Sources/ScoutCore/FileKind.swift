import Foundation
import UniformTypeIdentifiers

/// The handful of categories worth filtering by, named the way a person would name them.
///
/// Deliberately coarse. Spotlight can filter on hundreds of uniform type identifiers, which is
/// exactly why its filtering is unusable — nobody wants to choose between
/// `com.microsoft.word.openxml.document` and `com.apple.iwork.pages.sffpages`.
public enum FileKind: String, CaseIterable, Identifiable, Sendable {
    case folder
    case pdf
    case document
    case spreadsheet
    case presentation
    case image
    case media
    case archive
    case code
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .folder: "Folders"
        case .pdf: "PDFs"
        case .document: "Documents"
        case .spreadsheet: "Spreadsheets"
        case .presentation: "Presentations"
        case .image: "Images"
        case .media: "Audio & Video"
        case .archive: "Archives"
        case .code: "Code"
        case .other: "Other"
        }
    }

    public var symbol: String {
        switch self {
        case .folder: "folder"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .presentation: "rectangle.on.rectangle"
        case .image: "photo"
        case .media: "play.rectangle"
        case .archive: "archivebox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc"
        }
    }

    /// Classify a result by what the system says it is, falling back to its extension.
    public static func of(_ result: SearchResult) -> FileKind {
        if result.kind == .folder { return .folder }
        if let identifier = result.contentType, let type = UTType(identifier) {
            if let kind = classify(type) { return kind }
        }
        if let type = UTType(filenameExtension: result.url.pathExtension), let kind = classify(type) {
            return kind
        }
        return .other
    }

    private static func classify(_ type: UTType) -> FileKind? {
        // Order matters: `pdf` conforms to `data` and `composite-content`, so the specific
        // checks have to come before the broad ones.
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audiovisualContent) { return .media }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .spreadsheet) { return .spreadsheet }
        if type.conforms(to: .presentation) { return .presentation }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return .code }
        if type.conforms(to: .rtf) || type.conforms(to: .text) || type.conforms(to: .compositeContent) {
            return .document
        }
        return nil
    }
}
