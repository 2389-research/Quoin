import Foundation

public enum TaskToggleError: Error, Equatable {
    /// The bytes at the marker range are not a `[ ]`/`[x]` marker — the
    /// document changed and the write is refused rather than risked.
    case markerMismatch
    case invalidRange
}

/// The single byte-precise mutation Quoin performs on user files in v1:
/// flipping a task checkbox. Exactly one byte inside the three-byte
/// `[ ]`/`[x]` marker changes; every other byte of the file is preserved.
public enum TaskToggler {

    /// Returns the new source with the marker at `markerRange` toggled.
    public static func toggle(source: String, markerRange: ByteRange) throws -> String {
        var bytes = Array(source.utf8)
        guard markerRange.length == 3,
              markerRange.offset >= 0,
              markerRange.upperBound <= bytes.count
        else { throw TaskToggleError.invalidRange }

        guard bytes[markerRange.offset] == UInt8(ascii: "["),
              bytes[markerRange.offset + 2] == UInt8(ascii: "]")
        else { throw TaskToggleError.markerMismatch }

        switch bytes[markerRange.offset + 1] {
        case UInt8(ascii: " "):
            bytes[markerRange.offset + 1] = UInt8(ascii: "x")
        case UInt8(ascii: "x"), UInt8(ascii: "X"):
            bytes[markerRange.offset + 1] = UInt8(ascii: " ")
        default:
            throw TaskToggleError.markerMismatch
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
