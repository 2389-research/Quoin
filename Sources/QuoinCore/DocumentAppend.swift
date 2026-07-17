import Foundation

/// Builds the byte-precise `SourceEdit` that appends text to the END of a
/// document. Pure and platform-free so the trailing-newline rules are
/// unit-testable without a live session — the App Intents "Append Text to
/// Note" action (and any future append caller) funnels through this seam and
/// then through `DocumentSession.appendText`, so the append is a real,
/// undoable, byte-lossless edit rather than a raw file rewrite.
///
/// The edit is a pure insertion at `source.utf8.count` (length-0 range), so
/// every existing byte is untouched — the round-trip invariant holds for the
/// whole prefix for free.
public enum DocumentAppend {

    /// The edit that appends `text` as its own line(s) at the end of `source`,
    /// or `nil` when `text` carries nothing to append (empty, or only
    /// whitespace/newlines).
    ///
    /// Newline handling, made deterministic so callers can reason about it:
    /// incoming `\r\n`/`\r` are normalized to `\n`; the caller's own trailing
    /// newlines are stripped and replaced with exactly one, so an append never
    /// leaves a double blank line at the tail. When `source` is non-empty and
    /// does NOT already end in a newline, a single joining `\n` is inserted
    /// first so the appended text starts on a fresh line instead of being
    /// glued onto the last line. Interior newlines within `text` are preserved
    /// verbatim (a multi-line append lands as multiple lines).
    public static func appendEdit(appending text: String, to source: String) -> SourceEdit? {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Trim only the caller's trailing newlines; we own the terminal one.
        // Leading and interior whitespace is content and is preserved.
        var trimmed = Substring(normalized)
        while trimmed.hasSuffix("\n") { trimmed = trimmed.dropLast() }
        // Nothing meaningful to append (empty, or only whitespace/newlines) —
        // the append is a no-op. Leading/interior whitespace of REAL content is
        // still preserved below; this only rejects an all-blank payload.
        guard trimmed.contains(where: { !$0.isWhitespace }) else { return nil }

        var replacement = ""
        if !source.isEmpty, !source.hasSuffix("\n") {
            replacement += "\n"
        }
        replacement += trimmed
        replacement += "\n"

        let offset = source.utf8.count
        return SourceEdit(range: ByteRange(offset: offset, length: 0), replacement: replacement)
    }
}
