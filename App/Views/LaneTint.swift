// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import SwiftUI
import ScoutCore

/// A colour per source, so the eye can find where one section ends and the next begins without
/// reading a word.
///
/// Kept here rather than in `ScoutCore` on purpose: the core is pure logic with no opinion about
/// how anything looks, and `Color` is not available to it.
extension SearchLane {

    /// Close to the colour each of Apple's own apps uses, because that is the association people
    /// already have — a green band reads as Messages before the label is read.
    var tint: Color {
        switch self {
        case .files: .blue
        case .contacts: .orange
        case .mail: .indigo
        case .messages: .green
        case .apps: .purple
        case .system: .gray
        case .notes: .yellow
        case .reminders: .red
        }
    }
}
