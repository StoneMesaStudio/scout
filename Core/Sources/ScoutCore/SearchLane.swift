// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Foundation

/// The eight things Scout can search.
///
/// Several can be on at once and each keeps its own section, so a search that covers files, mail
/// and contacts still shows three labelled groups rather than one interleaved pile. Which ones are
/// on is remembered between searches.
///
/// The order here is only the *default*. The user can drag the source buttons into any order they
/// like, and the number beside each one is its position — so after a reorder ⌘1 is whatever they
/// put first. Notes and Reminders are still declared last so that anyone who never reorders keeps
/// the numbers they learned.
public enum SearchLane: String, CaseIterable, Identifiable, Sendable {
    case files
    case contacts
    case mail
    case messages
    case apps
    case system
    case notes
    case reminders

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .files: "Files"
        case .contacts: "Contacts"
        case .mail: "Mail"
        case .messages: "Messages"
        case .apps: "Apps"
        case .system: "System"
        case .notes: "Notes"
        case .reminders: "Reminders"
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
        case .notes: "note.text"
        case .reminders: "checklist"
        }
    }

    /// The number this source carries before anybody reorders anything.
    ///
    /// The live number comes from where the button actually sits, not from here — see
    /// `ScoutSettings.orderedLanes`.
    public var defaultShortcut: String {
        String((Self.allCases.firstIndex(of: self) ?? 0) + 1)
    }

    /// A saved order turned back into lanes.
    ///
    /// Anything unrecognised is dropped and anything missing is appended in declaration order, so
    /// a source added in a later version arrives at the end of the user's own arrangement instead
    /// of vanishing or shuffling everything they set up.
    public static func ordered(from saved: [String]) -> [SearchLane] {
        var result = saved.compactMap(SearchLane.init(rawValue:))
        // Duplicates would draw the same button twice and give it two numbers.
        var seen = Set<SearchLane>()
        result = result.filter { seen.insert($0).inserted }
        result += allCases.filter { !seen.contains($0) }
        return result
    }

    /// Only the files lane has scopes; the rest search their whole store.
    public var hasScopes: Bool { self == .files }
}
