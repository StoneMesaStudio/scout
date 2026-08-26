// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Foundation

/// One message found in the Messages history.
public struct MessageHit: Identifiable, Sendable, Hashable {

    public let rowID: Int64
    public let text: String
    public let date: Date
    public let isFromMe: Bool
    /// The other party: a chat's display name where there is one, otherwise the phone number or
    /// address the message came from.
    public let counterpart: String
    /// Passed to Messages' URL scheme to open the conversation.
    public let chatIdentifier: String?
    public let hasAttachment: Bool

    public var id: Int64 { rowID }

    public init(
        rowID: Int64,
        text: String,
        date: Date,
        isFromMe: Bool,
        counterpart: String,
        chatIdentifier: String?,
        hasAttachment: Bool
    ) {
        self.rowID = rowID
        self.text = text
        self.date = date
        self.isFromMe = isFromMe
        self.counterpart = counterpart
        self.chatIdentifier = chatIdentifier
        self.hasAttachment = hasAttachment
    }

    /// Opens the conversation in Messages.
    public var openURL: URL? {
        guard let chatIdentifier, !chatIdentifier.isEmpty else { return nil }
        guard let encoded = chatIdentifier.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) else {
            return nil
        }
        return URL(string: "imessage://\(encoded)")
    }

    /// Messages stores dates as nanoseconds since 2001 on modern macOS, but rows written by very
    /// old versions are in whole seconds. The magnitude tells them apart — a plausible seconds
    /// value is far too small to be a plausible nanoseconds value.
    public static func date(fromAppleTimestamp raw: Int64) -> Date {
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}
