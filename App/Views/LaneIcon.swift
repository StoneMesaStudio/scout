import AppKit
import SwiftUI
import ScoutCore

/// The real icon of the app each source reads from.
///
/// Asked of the system rather than drawn here, so Notes' icon is whatever Notes' icon is today
/// and stays right through an OS update — the same reason file results use the Finder's icons
/// instead of a guess at what a PDF looks like.
@MainActor
enum LaneIcon {

    private static var cache: [SearchLane: NSImage] = [:]

    static func image(for lane: SearchLane) -> NSImage? {
        if let cached = cache[lane] { return cached }

        let workspace = NSWorkspace.shared
        // Bundle identifier first: it survives Apple moving apps between /Applications and
        // /System/Applications, which has happened to most of these at least once.
        let url = bundleIdentifier(for: lane)
            .flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }
            ?? fallbackPath(for: lane).map { URL(filePath: $0) }

        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let icon = workspace.icon(forFile: url.path)
        cache[lane] = icon
        return icon
    }

    private static func bundleIdentifier(for lane: SearchLane) -> String? {
        switch lane {
        case .files: "com.apple.finder"
        case .contacts: "com.apple.AddressBook"
        case .mail: "com.apple.mail"
        case .messages: "com.apple.MobileSMS"
        case .system: "com.apple.systempreferences"
        case .notes: "com.apple.Notes"
        case .reminders: "com.apple.reminders"
        // The Apps lane is what is installed on this Mac, not an app of its own, so it wears the
        // Applications folder.
        case .apps: nil
        }
    }

    private static func fallbackPath(for lane: SearchLane) -> String? {
        switch lane {
        case .apps: "/Applications"
        case .files: "/System/Library/CoreServices/Finder.app"
        default: nil
        }
    }
}

/// One source's icon, in colour when the source is on and grey when it is off.
///
/// This is what lets the switches be as quiet as they are: colour against grey already says which
/// sources are running, so the plate behind an active one only has to whisper.
struct LaneIconView: View {

    let lane: SearchLane
    let isOn: Bool
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let icon = LaneIcon.image(for: lane) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                // A source whose app has been removed still needs a switch.
                Image(systemName: lane.symbol)
                    .font(.system(size: size * 0.7, weight: .medium))
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .grayscale(isOn ? 0 : 1)
        .opacity(isOn ? 1 : 0.45)
    }
}
