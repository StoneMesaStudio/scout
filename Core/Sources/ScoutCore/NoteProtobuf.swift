// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stone Mesa Studio, LLC

import Foundation

/// Pulls the words out of an Apple Notes body.
///
/// A note is not stored as text. It is a protobuf, gzipped, in a Core Data blob — Apple has no
/// API to read it and no intention of publishing one. So this walks the three fields that lead to
/// the text and nothing else: it does not decode the styling, the tables, the attachments or the
/// checklist state, because none of that is searchable anyway.
///
/// The path is `NoteStoreProto.document (2) → Document.note (3) → Note.text (2)`. If Apple moves
/// it, the fallback below finds the longest run of readable text in the blob instead — worse
/// results than the direct path, but not an empty lane.
enum NoteProtobuf {

    static func text(in data: Data) -> String? {
        if let direct = field(2, in: data)
            .flatMap({ field(3, in: $0) })
            .flatMap({ field(2, in: $0) })
            .flatMap({ String(data: $0, encoding: .utf8) }),
            !direct.isEmpty {
            return direct
        }
        return longestText(in: data, depth: 0)
    }

    /// The bytes of the first length-delimited field with this number, if there is one.
    static func field(_ number: Int, in data: Data) -> Data? {
        var found: Data?
        walk(data) { fieldNumber, payload in
            if fieldNumber == number, found == nil { found = payload }
        }
        return found
    }

    /// Every length-delimited field in a message, handed over one at a time.
    ///
    /// Stops at the first byte that cannot be a field key rather than guessing — a blob that is
    /// not a protobuf should produce nothing, not garbage.
    private static func walk(_ data: Data, _ body: (Int, Data) -> Void) {
        let bytes = [UInt8](data)
        var index = 0

        while index < bytes.count {
            guard let key = varint(bytes, &index) else { return }
            let number = Int(key >> 3)
            let wireType = key & 0x07

            switch wireType {
            case 0:                                     // varint
                guard varint(bytes, &index) != nil else { return }
            case 1:                                     // 64-bit
                index += 8
            case 2:                                     // length-delimited
                guard let length = varint(bytes, &index) else { return }
                let end = index + Int(length)
                guard length <= UInt64(bytes.count), end <= bytes.count, end >= index else { return }
                body(number, Data(bytes[index..<end]))
                index = end
            case 5:                                     // 32-bit
                index += 4
            default:
                return                                  // groups, or not a protobuf at all
            }
            guard index <= bytes.count else { return }
        }
    }

    private static func varint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    /// The fallback: the longest thing in the blob that reads as text.
    ///
    /// Deliberately crude. It exists so that a change to Apple's message layout costs quality
    /// rather than costing the whole lane, and it is only ever reached when the direct path fails.
    private static func longestText(in data: Data, depth: Int) -> String? {
        guard depth < 4 else { return nil }

        var best: String?
        walk(data) { _, payload in
            if let string = String(data: payload, encoding: .utf8), isReadable(string) {
                if string.count > (best?.count ?? 0) { best = string }
            } else if let nested = longestText(in: payload, depth: depth + 1) {
                if nested.count > (best?.count ?? 0) { best = nested }
            }
        }
        return best
    }

    /// Mostly letters, digits, punctuation and spaces — as opposed to a run of bytes that merely
    /// happens to be valid UTF-8.
    private static func isReadable(_ string: String) -> Bool {
        guard string.count >= 4 else { return false }
        let printable = string.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
                || CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return Double(printable.count) / Double(string.unicodeScalars.count) > 0.85
    }
}
