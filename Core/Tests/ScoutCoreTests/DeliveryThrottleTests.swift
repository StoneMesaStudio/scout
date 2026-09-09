// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Testing
import Foundation
@testable import ScoutCore

/// The throttle that stopped the panel beachballing while a word was being typed.
@Suite struct DeliveryThrottleTests {

    private let throttle = DeliveryThrottle(gap: .milliseconds(350))

    @Test func theFirstResultsOfASearchAreNeverHeldBack() {
        #expect(throttle.wait(sinceLastDelivery: nil) == .zero)
    }

    @Test func aReportArrivingRightAfterADeliveryWaitsOutTheRest() {
        #expect(throttle.wait(sinceLastDelivery: .milliseconds(100)) == .milliseconds(250))
    }

    @Test func aReportArrivingAfterTheGapGoesStraightThrough() {
        #expect(throttle.wait(sinceLastDelivery: .milliseconds(350)) == .zero)
        #expect(throttle.wait(sinceLastDelivery: .seconds(2)) == .zero)
    }

    /// The behaviour in terms of a real search: typing a word Spotlight has to hunt for used to
    /// cost a full re-read and re-rank about eight times a second. It now costs three.
    @Test func aBurstOfSpotlightProgressCostsThreeDeliveriesASecondNotEight() {
        let unthrottled = DeliveryThrottle(gap: .zero)
        #expect(unthrottled.deliveries(reportsEvery: .milliseconds(120), over: .seconds(1)) == 9)
        #expect(throttle.deliveries(reportsEvery: .milliseconds(120), over: .seconds(1)) == 3)
    }

    /// A source that reports slower than the gap is not delayed at all — the throttle only ever
    /// removes work, it never adds latency to a quiet search.
    @Test func aSlowTricklePassesThroughUntouched() {
        #expect(throttle.deliveries(reportsEvery: .seconds(1), over: .seconds(5)) == 6)
    }
}
