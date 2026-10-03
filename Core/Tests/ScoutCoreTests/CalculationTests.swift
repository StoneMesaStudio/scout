// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Testing
import Foundation
@testable import ScoutCore

/// Everything here is stated as something somebody would type into the field.
@Suite struct CalculationTests {

    private func answer(_ typed: String) -> String? { Calculator.evaluate(typed)?.answer }

    // MARK: - Sums

    @Test func addsSubtractsMultipliesAndDivides() {
        #expect(answer("2+2") == "4")
        #expect(answer("100 - 42") == "58")
        #expect(answer("12 * 12") == "144")
        #expect(answer("10 / 4") == "2.5")
    }

    @Test func keepsTheUsualPrecedenceAndBrackets() {
        #expect(answer("2 + 3 * 4") == "14")
        #expect(answer("(2 + 3) * 4") == "20")
        #expect(answer("2^10") == "1,024")
        #expect(answer("-5 + 3") == "-2")
    }

    @Test func groupsThousandsInTheAnswerAndUnderstandsThemInTheQuestion() {
        #expect(answer("1,234 * 2") == "2,468")
        #expect(answer("2000 * 3") == "6,000")
    }

    /// "20% of 80" is how people say it out loud, so it is what the field accepts.
    @Test func handlesPercentages() {
        #expect(answer("20% of 80") == "16")
        #expect(answer("15% * 200") == "30")
    }

    /// Dividing by nothing has no answer, so no row appears rather than one reading "inf".
    @Test func refusesToDivideByZero() {
        #expect(Calculator.evaluate("5 / 0") == nil)
    }

    /// The answer is copied without grouping, so it can be pasted straight into the next sum.
    @Test func copiesTheAnswerWithoutItsCommas() {
        #expect(Calculator.evaluate("2000 * 3")?.plain == "6000")
    }

    // MARK: - Conversions

    @Test func convertsLength() {
        #expect(answer("12 ft in m") == "3.6576 m")
        #expect(answer("100 cm to in")?.hasPrefix("39.37") == true)
        #expect(answer("5 km in miles")?.hasPrefix("3.1068") == true)
    }

    @Test func convertsTemperature() {
        #expect(answer("180 F in C")?.hasPrefix("82.22") == true)
        #expect(answer("100 C in F") == "212 °F")
        #expect(answer("0 c to f") == "32 °F")
    }

    @Test func convertsWeightAndData() {
        #expect(answer("2 kg in lbs")?.hasPrefix("4.409") == true)
        #expect(answer("2 GB to MB") == "2,000 MB")
    }

    /// "in" is both the keyword and inches, so the last one wins.
    @Test func readsInchesAndTheWordInInTheSameQuestion() {
        #expect(answer("12 in in cm") == "30.48 cm")
    }

    @Test func doesTheSumBeforeConverting() {
        #expect(answer("3 * 4 ft in m") == "3.6576 m")
    }

    @Test func refusesUnitsThatDoNotMeetSomewhere() {
        #expect(Calculator.evaluate("12 ft in kg") == nil)
    }

    // MARK: - Refusing, which is most of the job

    @Test func ordinarySearchesProduceNoAnswer() {
        for typed in ["insurance", "e-mail", "cal", "jose", "2026", "report v2",
                      "x-ray", "10-year plan", "Notes", "scout.app", "2026-09-13"] {
            #expect(Calculator.evaluate(typed) == nil, "\(typed) is a search, not a sum")
        }
    }

    /// A number on its own is a year, a version or a house number far more often than it is a sum.
    @Test func aBareNumberIsNotASum() {
        #expect(Calculator.evaluate("42") == nil)
        #expect(Calculator.evaluate("1,234") == nil)
    }
}
