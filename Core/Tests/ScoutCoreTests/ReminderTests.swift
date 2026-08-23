import Foundation
import Testing
@testable import ScoutCore

private func reminder(
    _ title: String,
    list: String = "Reminders",
    notes: String = "",
    due: Date? = nil,
    completed: Bool = false,
    identifier: String = UUID().uuidString
) -> ReminderRecord {
    let hit = ReminderHit(
        identifier: identifier,
        title: title,
        list: list.isEmpty ? nil : list,
        due: due,
        isCompleted: completed,
        note: notes.isEmpty ? nil : notes
    )
    return ReminderRecord(hit: hit, title: title, list: list, body: notes)
}

private func day(_ offset: Int) -> Date {
    Calendar.current.date(byAdding: .day, value: offset, to: Date())!
}

@Suite struct ReminderIndexTests {

    @Test func onlyRemindersThatActuallyContainTheQueryComeBack() {
        let index = ReminderIndex(records: [
            reminder("Call the chimney sweep"),
            reminder("Buy milk"),
        ])
        #expect(index.search("chimney").items.map(\.title) == ["Call the chimney sweep"])
    }

    @Test func theTitleLeadsOverTheListAndTheNote() {
        let index = ReminderIndex(records: [
            reminder("Order gravel", list: "Yard", notes: "ask about delivery"),
            reminder("Call Dave", list: "Gravel project"),
            reminder("Pay the invoice", notes: "the gravel one, not the fencing one"),
        ])
        #expect(index.search("gravel").items.map(\.title) == ["Order gravel", "Call Dave", "Pay the invoice"])
    }

    @Test func aWholeWordBeatsAWordItIsBuriedIn() {
        let index = ReminderIndex(records: [
            reminder("Renew the passport"),
            reminder("Passport photos"),
        ])
        // "Passport photos" starts with the word; "Renew the passport" merely contains it.
        #expect(index.search("passport").items.first?.title == "Passport photos")
    }

    @Test func whatIsStillOutstandingComesBeforeWhatIsDone() {
        // The common question is "what do I still owe", so nothing finished outranks something
        // outstanding — but the finished ones stay, because "did I ever write that down" is the
        // other half of why anyone searches reminders.
        let index = ReminderIndex(records: [
            reminder("Chimney sweep", completed: true),
            reminder("Chimney inspection", completed: false),
        ])
        let hits = index.search("chimney").items
        #expect(hits.map(\.title) == ["Chimney inspection", "Chimney sweep"])
        #expect(hits.count == 2)
    }

    @Test func amongEqualsTheSoonestDueComesFirst() {
        let index = ReminderIndex(records: [
            reminder("Chimney later", due: day(30)),
            reminder("Chimney sooner", due: day(2)),
            reminder("Chimney whenever", due: nil),
        ])
        #expect(index.search("chimney").items.map(\.title)
                == ["Chimney sooner", "Chimney later", "Chimney whenever"])
    }

    @Test func accentsAndCaseAreIgnoredTheWayTheyAreEverywhereElse() {
        let index = ReminderIndex(records: [reminder("Llamar a José")])
        #expect(index.search("jose").items.count == 1)
    }

    @Test func aSingleLetterIsNotASearch() {
        let index = ReminderIndex(records: [reminder("Chimney sweep")])
        #expect(index.search("c").items.isEmpty)
    }

    @Test func theTotalCountsEverythingThatMatchedNotJustThePage() {
        let index = ReminderIndex(records: (1...30).map { reminder("Chimney \($0)") })
        let page = index.search("chimney", limit: 5)
        #expect(page.items.count == 5)
        #expect(page.total == 30)
    }
}

@Suite struct ReminderHitTests {

    @Test func aReminderOpensInReminders() {
        let hit = reminder("Chimney", identifier: "3B0A0F0E-1111-2222-3333-444455556666").hit
        #expect(hit.openURL?.absoluteString
                == "x-apple-reminderkit://REMCDReminder/3B0A0F0E-1111-2222-3333-444455556666")
    }

    @Test func anIdentifierThatIsNotAUUIDOpensNothingRatherThanTheWrongThing() {
        // EventKit hands out more than one shape of identifier. A URL built out of the wrong one
        // does not fail — it opens Reminders showing nothing, which reads as a broken app.
        #expect(reminder("Chimney", identifier: "local-12").hit.openURL == nil)
    }

    @Test func dueDatesReadAsSentencesRatherThanAsSubtraction() {
        let now = Date()
        #expect(ReminderHit.dueDescription(now, now: now) == "Due today")
        #expect(ReminderHit.dueDescription(day(1), now: now) == "Due tomorrow")
        #expect(ReminderHit.dueDescription(day(-1), now: now) == "Overdue by a day")
        #expect(ReminderHit.dueDescription(day(-3), now: now) == "Overdue by 3 days")
    }

    @Test func theSubtitleSaysWhichListAndWhenItIsDue() {
        let hit = reminder("Chimney", list: "Household", due: Date()).hit
        #expect(hit.detail == "Household · Due today")
    }
}
