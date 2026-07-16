import Foundation

/// The single source of truth for turning a human title — a document's first
/// H1, or a manual rename — into a safe on-disk filename *base* (no extension).
///
/// Quoin is file-backed and international by design: titles arrive with CJK,
/// RTL, emoji, combining marks, and punctuation. A rename must never produce a
/// name that is inaccessible (leading dot → hidden), collides via a path
/// separator, is rejected by the volume (control characters, over-long), or
/// silently splits a character. Both the H1 auto-rename and `Library.rename`
/// route through here so the two paths can never diverge.
public enum FilenamePolicy {

    /// Byte budget for the base name. The common filename-component limit is
    /// 255 UTF-8 bytes; we stay well under it to leave room for an extension
    /// (`.markdown`) and a collision suffix (` 12`).
    public static let maxBaseNameUTF8Bytes = 200

    /// Used when a title sanitizes to nothing (e.g. "///", "…", or all control
    /// characters). Matches the app's "Untitled" new-document convention.
    public static let fallback = "Untitled"

    public static func sanitize(_ title: String) -> String {
        // Map control characters and line/paragraph separators to spaces (so
        // "A\nB" reads "A B", not "AB"); forbidden path/volume separators to
        // dashes. Everything else — including emoji, ZWJ sequences, and marks
        // — is preserved.
        var mapped = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                mapped.append(" ")
            default:
                if scalar == "/" || scalar == ":" || scalar == "\\" {
                    mapped.append("-")
                } else {
                    mapped.append(scalar)
                }
            }
        }

        // Collapse whitespace runs and trim both ends.
        let collapsed = String(mapped)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Leading dots hide the file; trailing dots/spaces are stripped or
        // rejected by some volumes. Trim before and after budgeting, since
        // truncation can leave a trailing space.
        let trimSet = CharacterSet(charactersIn: ". ")
        let dedotted = collapsed.trimmingCharacters(in: trimSet)
        let bounded = byteBudgeted(dedotted).trimmingCharacters(in: trimSet)
        return bounded.isEmpty ? fallback : bounded
    }

    /// Truncates to the byte budget on grapheme-cluster boundaries, so an
    /// emoji or a base+combining-mark sequence is never split mid-character.
    private static func byteBudgeted(_ s: String) -> String {
        guard s.utf8.count > maxBaseNameUTF8Bytes else { return s }
        var out = ""
        var bytes = 0
        for character in s {
            let width = String(character).utf8.count
            if bytes + width > maxBaseNameUTF8Bytes { break }
            out.append(character)
            bytes += width
        }
        return out
    }
}
