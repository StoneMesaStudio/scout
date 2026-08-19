import AppKit
import SwiftUI
import ScoutCore

/// Shown in place of results when a lane cannot answer yet, and why.
///
/// Mail and Messages both need Full Disk Access — a permission macOS gives no way to request from
/// inside an app. All Scout can do is say plainly what is missing and open the right settings
/// pane, rather than showing an empty list that looks like "nothing found".
struct LaneStatusView: View {

    let status: LaneStatus
    let lane: SearchLane

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 5) {
                Text(headline)
                    .font(.system(size: 13.5, weight: .medium))

                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if status == .needsFullDiskAccess {
                    Button("Open Full Disk Access") {
                        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
                        if let url { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .padding(.top, 1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var symbol: String {
        switch status {
        case .needsFullDiskAccess: "lock"
        case .building: "clock"
        case .failed: "exclamationmark.triangle"
        case .ready: "checkmark"
        }
    }

    private var tint: Color {
        switch status {
        case .needsFullDiskAccess, .building: .secondary
        case .failed: .orange
        case .ready: .secondary
        }
    }

    private var headline: String {
        switch status {
        case .needsFullDiskAccess:
            "Scout can’t read your \(lane == .mail ? "mail" : "messages") yet"
        case .building:
            "Reading your message history…"
        case .failed:
            "That didn’t work"
        case .ready:
            ""
        }
    }

    private var detail: String? {
        switch status {
        case .needsFullDiskAccess:
            "macOS keeps mail and messages locked away until you allow it. Turn on Scout in Full Disk Access, then come back — you only do this once."
        case .building:
            "The first read goes through your whole history. After that it only picks up what’s new."
        case .failed(let reason):
            reason
        case .ready:
            nil
        }
    }
}
