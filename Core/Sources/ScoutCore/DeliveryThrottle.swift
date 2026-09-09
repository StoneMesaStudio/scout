// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Foundation

/// How long to hold on to a batch of Spotlight results before handing them over.
///
/// Spotlight reports its progress several times a second while a search gathers, and every report
/// used to cost a full walk of every match — six attributes per item, read one at a time out of
/// the metadata server — and then a full re-rank of everything downstream. All of it on the thread
/// that draws the window. A word matching a few hundred files therefore spent more of each second
/// re-reading its own answer than drawing it, and typing was the worst case, because every
/// keystroke starts the gathering over from nothing. That was the beachball.
///
/// Holding the deliveries to one every 350 ms turns a burst of eight into three. Results still
/// appear to stream in — nobody can see the difference between three updates a second and eight —
/// and the work between them is a third of what it was.
///
/// Kept as a plain value with no clock of its own so the arithmetic can be tested without waiting
/// for real time to pass.
public struct DeliveryThrottle: Sendable {

    public let gap: Duration

    public init(gap: Duration) {
        self.gap = gap
    }

    /// How long to wait before delivering.
    ///
    /// - Parameter sinceLastDelivery: time elapsed since the last delivery, or `nil` if none has
    ///   happened yet — the first answer to a new search is never held back.
    public func wait(sinceLastDelivery elapsed: Duration?) -> Duration {
        guard let elapsed else { return .zero }
        return elapsed >= gap ? .zero : gap - elapsed
    }

    /// How many deliveries a burst of reports arriving `interval` apart would actually cost over
    /// `window`. Used by the tests to state the behaviour the way it is felt: eight reports a
    /// second becoming three.
    public func deliveries(reportsEvery interval: Duration, over window: Duration) -> Int {
        guard interval > .zero, window > .zero else { return 0 }

        var elapsed: Duration = .zero
        var lastDelivery: Duration? = nil
        var count = 0

        while elapsed <= window {
            let since = lastDelivery.map { elapsed - $0 }
            if wait(sinceLastDelivery: since) == .zero {
                count += 1
                lastDelivery = elapsed
            }
            elapsed += interval
        }
        return count
    }
}
