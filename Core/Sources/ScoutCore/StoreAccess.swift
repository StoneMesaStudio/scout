import Foundation

/// Whether a protected store can actually be read.
///
/// The obvious check is wrong: `FileManager.isReadableFile` reports the POSIX permissions, which
/// say yes for `~/Library/Mail` whether or not Full Disk Access has been granted. macOS enforces
/// that separately, at the moment of opening. So the only honest test is to try.
///
/// Getting this wrong is worse than it sounds — Scout told the user "nothing in your mail matches"
/// when the truth was that it had never been allowed to look.
public enum StoreAccess {

    public static func canRead(directory: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) != nil
    }

    public static func canRead(file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        // Opening can succeed where reading does not, so take a byte to be sure.
        return (try? handle.read(upToCount: 1)) != nil
    }
}
