// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Foundation

/// Pulls the readable text out of a Messages `attributedBody` blob.
///
/// Messages stores most modern messages twice: a plain `text` column, and an `attributedBody`
/// blob holding the styled version. On recent macOS the plain column is frequently empty, and a
/// search that only reads it misses those messages entirely — which is a large part of why
/// searching Messages feels broken.
///
/// The blob is an old NeXT-era typedstream, not a modern keyed archive, so `NSKeyedUnarchiver`
/// cannot read it and the Swift overlay no longer exposes `NSUnarchiver`. What it does contain is
/// a length-prefixed UTF-8 run immediately after an `NSString`/`NSMutableString` class marker,
/// which is enough. Anything unexpected returns nil rather than guessing.
public enum TypedStreamText {

    public static func extract(from data: Data) -> String? {
        let bytes = [UInt8](data)

        // Try every string marker in the blob and keep the longest thing that decodes. A message
        // can carry several — an empty one for an attribute name, the real text later — and which
        // position holds the body varies with how the message was composed.
        var best: String?
        for markerEnd in stringMarkerEnds(in: bytes) {
            guard let candidate = readString(bytes, after: markerEnd) else { continue }
            if candidate.count > (best?.count ?? 0) { best = candidate }
        }
        return best
    }

    /// Between the class name and the string body sits a short run of typedstream bookkeeping.
    /// The body begins at a length marker: `0x2B` for a one-byte length, `0x81` for a two-byte
    /// little-endian one — and `0x2B 0x81` for the two together, which is what a long message
    /// composed in Messages looks like.
    private static func readString(_ bytes: [UInt8], after markerEnd: Int) -> String? {
        var cursor = markerEnd
        while cursor < bytes.count, cursor - markerEnd < 16 {
            let byte = bytes[cursor]

            if byte == 0x2B, cursor + 1 < bytes.count {
                if bytes[cursor + 1] == 0x81, cursor + 3 < bytes.count {
                    let length = Int(bytes[cursor + 2]) | (Int(bytes[cursor + 3]) << 8)
                    return string(bytes, from: cursor + 4, length: length)
                }
                return string(bytes, from: cursor + 2, length: Int(bytes[cursor + 1]))
            }

            if byte == 0x81, cursor + 2 < bytes.count {
                let length = Int(bytes[cursor + 1]) | (Int(bytes[cursor + 2]) << 8)
                return string(bytes, from: cursor + 3, length: length)
            }

            cursor += 1
        }
        return nil
    }

    /// Every position just past an `NSString` or `NSMutableString` class name.
    private static func stringMarkerEnds(in bytes: [UInt8]) -> [Int] {
        var ends: [Int] = []
        for marker in ["NSMutableString", "NSString"] {
            ends.append(contentsOf: ranges(of: Array(marker.utf8), in: bytes))
        }
        return ends.sorted()
    }

    private static func ranges(of needle: [UInt8], in haystack: [UInt8]) -> [Int] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        var found: [Int] = []
        let limit = haystack.count - needle.count
        var index = 0
        while index <= limit {
            if haystack[index] == needle[0], Array(haystack[index..<index + needle.count]) == needle {
                found.append(index + needle.count)
                index += needle.count
            } else {
                index += 1
            }
        }
        return found
    }

    private static func string(_ bytes: [UInt8], from start: Int, length: Int) -> String? {
        guard length > 0, start >= 0, start + length <= bytes.count else { return nil }
        let slice = Array(bytes[start..<start + length])
        guard let text = String(bytes: slice, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }
}
