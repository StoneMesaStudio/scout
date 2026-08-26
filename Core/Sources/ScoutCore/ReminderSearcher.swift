// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import EventKit
import Foundation

/// One reminder found in Reminders.
public struct ReminderHit: Identifiable, Sendable, Hashable {

    public let identifier: String
    public let title: String
    /// The list it sits in — "Groceries", "Work". Reminders calls these calendars.
    public let list: String?
    public let due: Date?
    public let isCompleted: Bool
    /// The first line of the reminder's notes, when it has any.
    public let note: String?

    public var id: String { identifier }

    public init(
        identifier: String,
        title: String,
        list: String?,
        due: Date?,
        isCompleted: Bool,
        note: String? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.list = list
        self.due = due
        self.isCompleted = isCompleted
        self.note = note
    }

    /// What to show under the title: which list, when it is due, and its note if it has one.
    ///
    /// A finished reminder never says "overdue". Ninety-nine per cent of a real list is finished,
    /// so the overdue wording — which exists to make an outstanding one jump out — was being
    /// applied to almost every row, telling people something they had already done was late.
    public var detail: String {
        var parts: [String] = []
        if let list, !list.isEmpty { parts.append(list) }
        if let due {
            parts.append(isCompleted
                         ? "Due \(due.formatted(date: .abbreviated, time: .omitted))"
                         : Self.dueDescription(due))
        }
        if let note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    /// "Due today", "Overdue by 3 days", "Due 14 Sep" — a date on its own makes the reader do
    /// the subtraction, and overdue is the whole reason to look.
    static func dueDescription(_ due: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: due)).day ?? 0
        switch days {
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        case -1: return "Overdue by a day"
        case ..<(-1): return "Overdue by \(-days) days"
        default: return "Due \(due.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    /// Opens the reminder in Reminders.
    ///
    /// `x-apple-reminderkit://REMCDReminder/<uuid>` is the scheme Reminders answers to. EventKit
    /// hands out identifiers in more than one shape, so anything that is not a plain UUID comes
    /// back nil and the panel launches Reminders itself instead of opening nothing.
    public var openURL: URL? {
        let uuid = identifier.split(separator: "/").last.map(String.init) ?? identifier
        guard UUID(uuidString: uuid) != nil else { return nil }
        return URL(string: "x-apple-reminderkit://REMCDReminder/\(uuid)")
    }
}

/// A reminder with everything about it worth matching, which is more than gets shown.
public struct ReminderRecord: Sendable {

    public let hit: ReminderHit
    /// The title on its own, ranked well above everything else.
    public let title: String
    /// The list name.
    public let list: String
    /// The full notes, and any URL attached to the reminder.
    public let body: String

    public init(hit: ReminderHit, title: String, list: String, body: String) {
        self.hit = hit
        self.title = title
        self.list = list
        self.body = body
    }
}

/// Reads the Reminders store.
public struct ReminderSearcher: Sendable {

    public enum Access: Sendable, Equatable {
        case notRequested
        case allowed
        case denied
    }

    public init() {}

    public var access: Access {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .allowed
        case .notDetermined: .notRequested
        default: .denied
        }
    }

    /// Ask once. macOS shows its own prompt and remembers the answer.
    public func requestAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToReminders()) ?? false
    }

    /// Every reminder, as records we can search ourselves.
    ///
    /// EventKit has no text predicate for reminders — `predicateForReminders(in:)` is the only
    /// one there is, and it means "all of them". So all of them is what gets read, once every few
    /// minutes, and the matching happens here where it can be made to behave.
    public func loadAll() async -> [ReminderRecord] {
        guard access == .allowed else { return [] }

        let store = EKEventStore()
        let predicate = store.predicateForReminders(in: nil)

        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                // `store` is captured deliberately: EventKit does not promise to keep it alive
                // for the duration of the fetch, and a released store never calls back.
                _ = store
                continuation.resume(returning: (reminders ?? []).map(Self.record(from:)))
            }
        }
    }

    static func record(from reminder: EKReminder) -> ReminderRecord {
        let title = reminder.title ?? ""
        let list = reminder.calendar?.title ?? ""
        let notes = reminder.notes ?? ""
        let url = reminder.url?.absoluteString ?? ""

        let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }

        let hit = ReminderHit(
            identifier: reminder.calendarItemIdentifier,
            title: title.isEmpty ? "Untitled reminder" : title,
            list: list.isEmpty ? nil : list,
            due: due,
            isCompleted: reminder.isCompleted,
            note: notes.components(separatedBy: .newlines).first { !$0.isEmpty }
        )

        return ReminderRecord(
            hit: hit,
            title: title,
            list: list,
            body: [notes, url].filter { !$0.isEmpty }.joined(separator: " ")
        )
    }
}
