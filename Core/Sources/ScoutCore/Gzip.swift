import Compression
import Foundation

/// Just enough gzip to read what Apple Notes stores.
///
/// Every note body in `NoteStore.sqlite` is a gzip-compressed protobuf. Foundation has no public
/// gunzip, and Apple's Compression framework decodes raw DEFLATE rather than gzip — so the ten
/// byte header and its optional extras are stripped here and the payload handed over on its own.
///
/// A blob that is not gzip at all comes back nil rather than as nonsense. That is the normal
/// answer for a password-protected note, whose data is encrypted instead of compressed.
enum Gzip {

    static func inflate(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        // 10 header bytes, 8 trailer bytes, and at least something in between.
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }

        let flags = bytes[3]
        var offset = 10

        if flags & 0x04 != 0 {                                  // FEXTRA
            guard offset + 2 <= bytes.count else { return nil }
            offset += 2 + (Int(bytes[offset]) | Int(bytes[offset + 1]) << 8)
        }
        if flags & 0x08 != 0 {                                  // FNAME
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            offset = end + 1
        }
        if flags & 0x10 != 0 {                                  // FCOMMENT
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 }                    // FHCRC

        // The last eight bytes are the checksum and the original length. The decoder wants
        // neither, and handing them over makes it report a corrupt stream.
        guard offset < bytes.count - 8 else { return nil }
        return rawInflate(Array(bytes[offset..<(bytes.count - 8)]))
    }

    /// Raw DEFLATE, which is what `COMPRESSION_ZLIB` actually means in Apple's framework — no
    /// zlib header, no gzip header, just the compressed stream.
    private static func rawInflate(_ payload: [UInt8]) -> Data? {
        guard !payload.isEmpty else { return nil }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }

        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data()
        var status = COMPRESSION_STATUS_OK

        payload.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = source.count

            repeat {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.pointee.dst_size
                if produced > 0 { output.append(buffer, count: produced) }
            } while status == COMPRESSION_STATUS_OK
        }

        return status == COMPRESSION_STATUS_END ? output : nil
    }
}
