// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import AppKit
import Foundation

/// Catches the spinning wheel in the act, so it stops being a thing people describe from memory.
///
/// Scout hangs have been hard to pin down for the same reason all of them are: by the time anybody
/// can report one, the thread that was stuck has moved on. This asks the main thread whether it is
/// still there four times a second. When it stops answering for longer than macOS waits before
/// drawing the wheel, it runs `sample` against this very process and writes the result next to the
/// indexes.
///
/// The file holds stack traces and the names of loaded libraries. No file contents, nothing about
/// what was being searched for, and it goes nowhere — same promise as the rest of the app.
final class HangWatchdog: @unchecked Sendable {

    static let shared = HangWatchdog()

    /// macOS puts the wheel up at around two seconds, so that is the definition of the thing
    /// being measured rather than a number picked for taste.
    private static let hangThreshold: TimeInterval = 2

    /// One report per episode, and not more than one a minute, or a Mac having a bad afternoon
    /// fills the folder with the same stack.
    private static let quietPeriod: TimeInterval = 60

    private let lock = NSLock()
    private var askedAt: Date?
    private var capturedThisEpisode = false
    private var lastCapture: Date?
    private var running = false

    /// Where the reports go. Beside the indexes, because that is the folder the uninstaller
    /// already knows about and already offers to take away.
    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Scout/hangs")
    }

    func start() {
        lock.lock()
        guard !running else { return lock.unlock() }
        running = true
        lock.unlock()

        Task.detached(priority: .utility) { [self] in
            while !Task.isCancelled {
                ping()
                try? await Task.sleep(for: .milliseconds(250))
                checkForSilence()
            }
        }
    }

    /// Ask the main thread to say something. Only a main thread that is free can answer.
    private func ping() {
        lock.lock()
        // Still waiting on the last one — that is the interesting case, so do not reset the clock.
        guard askedAt == nil else { return lock.unlock() }
        askedAt = Date()
        lock.unlock()

        DispatchQueue.main.async { [self] in
            lock.lock()
            askedAt = nil
            capturedThisEpisode = false
            lock.unlock()
        }
    }

    private func checkForSilence() {
        lock.lock()
        guard let asked = askedAt, !capturedThisEpisode else { return lock.unlock() }
        let stuckFor = Date().timeIntervalSince(asked)
        guard stuckFor >= Self.hangThreshold else { return lock.unlock() }
        if let last = lastCapture, Date().timeIntervalSince(last) < Self.quietPeriod {
            return lock.unlock()
        }
        capturedThisEpisode = true
        lastCapture = Date()
        lock.unlock()

        capture(stuckFor: stuckFor)
    }

    private func capture(stuckFor: TimeInterval) {
        let directory = Self.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = directory.appending(path: "hang-\(stamp).txt")

        let sample = Process()
        sample.executableURL = URL(filePath: "/usr/bin/sample")
        sample.arguments = [String(ProcessInfo.processInfo.processIdentifier), "2", "-file", destination.path]
        try? sample.run()
        sample.waitUntilExit()

        // A note at the top, because "stuck for 9 seconds" is the first thing anyone reading this
        // wants to know and a sample does not say it.
        if let existing = try? String(contentsOf: destination, encoding: .utf8) {
            let header = """
                Scout was not answering for \(String(format: "%.1f", stuckFor)) seconds \
                when this was taken, at \(Date().formatted()).
                Look at the main thread: whatever it is in the middle of is the thing to fix.


                """
            try? (header + existing).write(to: destination, atomically: true, encoding: .utf8)
        }

        prune(in: directory)
    }

    /// Keep the last ten. Anything older has been superseded by a better example of the same bug.
    private func prune(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        let oldestFirst = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
        for file in oldestFirst.dropLast(10) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
