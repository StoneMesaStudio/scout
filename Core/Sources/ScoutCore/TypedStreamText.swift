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
        guard let markerEnd = firstStringMarkerEnd(in: bytes) else { return nil }

        var cursor = markerEnd
        // Between the class name and the string body sits a short run of typedstream bookkeeping
        // bytes. The string itself begins at the first length marker: either 0x2B (a one-byte
        // length follows) or a bare byte under 0x80 acting as the length.
        while cursor < bytes.count, cursor - markerEnd < 12 {
            let byte = bytes[cursor]

            if byte == 0x2B, cursor + 1 < bytes.count {
                let length = Int(bytes[cursor + 1])
                return string(bytes, from: cursor + 2, length: length)
            }

            // 0x81 introduces a two-byte little-endian length, used once a message passes 127 bytes.
            if byte == 0x81, cursor + 2 < bytes.count {
                let length = Int(bytes[cursor + 1]) | (Int(bytes[cursor + 2]) << 8)
                return string(bytes, from: cursor + 3, length: length)
            }

            cursor += 1
        }
        return nil
    }

    /// Find the end of the first `NSString` or `NSMutableString` class name in the stream.
    private static func firstStringMarkerEnd(in bytes: [UInt8]) -> Int? {
        // Longest first: "NSMutableString" contains "NSString" nowhere, but searching for the
        // shorter name first would still stop at the right place for either.
        for marker in ["NSMutableString", "NSString"] {
            if let range = range(of: Array(marker.utf8), in: bytes) {
                return range
            }
        }
        return nil
    }

    private static func range(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let limit = haystack.count - needle.count
        var index = 0
        while index <= limit {
            if haystack[index] == needle[0], Array(haystack[index..<index + needle.count]) == needle {
                return index + needle.count
            }
            index += 1
        }
        return nil
    }

    private static func string(_ bytes: [UInt8], from start: Int, length: Int) -> String? {
        guard length > 0, start >= 0, start + length <= bytes.count else { return nil }
        let slice = Array(bytes[start..<start + length])
        guard let text = String(bytes: slice, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }
}
