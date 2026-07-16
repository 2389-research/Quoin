import Foundation

// MARK: - Review Mode: typing becomes suggestions (suggestions §3.6, S3b)

/// Transforms an ordinary keystroke edit (relative byte range + replacement
/// within the active block's source slice) into its SUGGESTION form:
/// insertions become `{++…++}`, deletions `{--…--}`, replacements
/// `{~~old~>new~~}`.
///
/// COALESCING is stateless, by construction: a fresh keystroke outside any
/// mark mints a mark and parks the caret INSIDE its body; the next
/// keystroke's position is then inside a mark body, which passes through
/// as a `.plain` edit — the mark grows, no per-keystroke state to track or
/// invalidate. Backspacing right after a deletion mark extends it leftward.
///
/// Typed marks are deliberately ID-LESS (deviation from §3.6's sketch): a
/// combined mark+endmatter edit spans to EOF, which defeats the render
/// patch pipeline on EVERY keystroke. Resolution synthesizes ids and
/// records later (universal history), so nothing is lost.
///
/// `.refused` means the edit has no faithful suggestion form (structural
/// newlines, edits tearing an existing mark, edits inside a deletion's
/// original text) — the caller beeps; review mode never silently applies
/// a REAL edit.
public enum SuggestTransform {

    public enum Outcome: Equatable, Sendable {
        /// Apply the edit unchanged (typing inside a suggestion's body).
        case plain
        /// Apply this edit instead.
        case transformed(range: ByteRange, replacement: String, caretDelta: Int)
        /// No faithful suggestion form — beep, never silently edit.
        case refused
    }

    /// One scanned mark with its body region(s), all in slice-relative bytes.
    private struct Mark {
        let range: ByteRange
        let payload: CriticMark.Payload
        let bodyStart: Int
        let bodyEnd: Int          // excludes closing sigil + any {#id}
        let arrowOffset: Int?     // substitution: offset of `~>` within slice
    }

    public static func outcome(
        relativeRange: ByteRange, replacement: String, in slice: String
    ) -> Outcome {
        // Structural edits aren't suggestions in v1: a newline inside a
        // mark splits the block and unbalances it (documented limitation).
        guard !replacement.contains("\n") else { return .refused }

        let bytes = Array(slice.utf8)
        guard relativeRange.offset >= 0,
              relativeRange.offset + relativeRange.length <= bytes.count else { return .refused }
        let marks = scanMarks(in: slice)
        let start = relativeRange.offset
        let end = relativeRange.offset + relativeRange.length

        func mark(containing position: Int) -> Mark? {
            marks.first { position > $0.range.offset && position < $0.range.offset + $0.range.length }
        }
        /// The editable body region a position sits in (inclusive ends —
        /// the caret at either edge of the body still grows it).
        func growableBody(at position: Int) -> Mark? {
            marks.first { mark in
                switch mark.payload {
                case .insertion:
                    return position >= mark.bodyStart && position <= mark.bodyEnd
                case .substitution:
                    // Only the NEW half is the suggestion's own text.
                    guard let arrow = mark.arrowOffset else { return false }
                    return position >= arrow + 2 && position <= mark.bodyEnd
                default:
                    return false
                }
            }
        }

        // INSERTION (typing at a caret).
        if relativeRange.length == 0, !replacement.isEmpty {
            if let body = growableBody(at: start) {
                // Growing a mark is a plain insert — UNLESS the typed text
                // would re-scan the mark to a DIFFERENT structure (typing
                // the body's own sigil, e.g. a `+` into `{++…++}`, makes
                // the lazy scanner find an earlier closer, leaking the tail
                // as literal source; review MEDIUM). Self-calibrate: apply
                // the candidate and require the same mark count with the
                // caret still inside a growable body.
                if plainInsertKeepsStructure(
                    at: start, insert: replacement, in: bytes, markCount: marks.count, body: body) {
                    return .plain
                }
                return .refused
            }
            if mark(containing: start) != nil { return .refused }
            return .transformed(
                range: relativeRange,
                replacement: "{++\(replacement)++}",
                caretDelta: 3 + replacement.utf8.count)
        }

        // DELETION (backspace / forward delete / cut).
        if relativeRange.length > 0, replacement.isEmpty {
            // Inside a growable body: shrink in place — unless that empties
            // the body, then the whole mark goes (an empty suggestion is
            // noise, and `{++++}` still parses as a mark).
            if let body = growableBody(at: start), end <= body.bodyEnd {
                let ownStart: Int
                if case .substitution = body.payload, let arrow = body.arrowOffset {
                    ownStart = arrow + 2
                } else {
                    ownStart = body.bodyStart
                }
                guard start >= ownStart else { return .refused }
                if start == ownStart, end == body.bodyEnd {
                    if case .substitution = body.payload, let arrow = body.arrowOffset {
                        // Emptying the new half turns the substitution into
                        // a plain deletion suggestion of the old half.
                        let old = String(decoding: bytes[body.bodyStart..<arrow], as: UTF8.self)
                        let replacementMark = "{--\(old)--}"
                        return .transformed(
                            range: body.range,
                            replacement: replacementMark,
                            caretDelta: replacementMark.utf8.count)
                    }
                    return .transformed(range: body.range, replacement: "", caretDelta: 0)
                }
                return .plain
            }
            // Backspace immediately after a deletion mark extends it: the
            // character BEFORE the mark joins the suggested deletion.
            if let deletion = marks.first(where: { markEnd in
                if case .deletion = markEnd.payload {
                    return end == markEnd.range.offset + markEnd.range.length
                        && start >= markEnd.bodyEnd
                }
                return false
            }) {
                guard let previous = characterRange(endingAt: deletion.range.offset, in: slice)
                else { return .refused }
                // The character being absorbed must be PLAIN prose — never a
                // byte of an abutting mark. Extending across a mark boundary
                // ate the neighbor's closing `}` and destroyed an untouched
                // suggestion (review BLOCKER). Refuse instead.
                let absorbInsideOtherMark = marks.contains { other in
                    other.range.offset != deletion.range.offset
                        && previous.lowerBound < other.range.offset + other.range.length
                        && previous.upperBound > other.range.offset
                }
                guard !absorbInsideOtherMark else { return .refused }
                let char = String(decoding: bytes[previous.lowerBound..<previous.upperBound], as: UTF8.self)
                let body = String(decoding: bytes[deletion.bodyStart..<deletion.bodyEnd], as: UTF8.self)
                // Preserve the mark's `{#id}` reference: it sits after the
                // closing `--}` (bytes bodyEnd+3 … markEnd). Dropping it
                // silently orphaned the RDFM identity on a tail backspace
                // (review HIGH).
                let markEnd = deletion.range.offset + deletion.range.length
                let idSuffix = String(decoding: bytes[(deletion.bodyEnd + 3)..<markEnd], as: UTF8.self)
                let replacementMark = "{--\(char)\(body)--}\(idSuffix)"
                return .transformed(
                    range: ByteRange(
                        offset: previous.lowerBound,
                        length: markEnd - previous.lowerBound),
                    replacement: replacementMark,
                    caretDelta: replacementMark.utf8.count)
            }
            // Fully outside every mark: wrap as a deletion suggestion.
            if marks.allSatisfy({ end <= $0.range.offset || start >= $0.range.offset + $0.range.length }) {
                let deleted = String(decoding: bytes[start..<end], as: UTF8.self)
                let replacementMark = "{--\(deleted)--}"
                return .transformed(
                    range: relativeRange,
                    replacement: replacementMark,
                    caretDelta: replacementMark.utf8.count)
            }
            return .refused
        }

        // REPLACEMENT (typing over a selection).
        if relativeRange.length > 0, !replacement.isEmpty {
            if let body = growableBody(at: start), end <= body.bodyEnd {
                return .plain // retyping inside the suggestion's own text
            }
            if marks.allSatisfy({ end <= $0.range.offset || start >= $0.range.offset + $0.range.length }) {
                let old = String(decoding: bytes[start..<end], as: UTF8.self)
                let mark = "{~~\(old)~>\(replacement)~~}"
                return .transformed(
                    range: relativeRange,
                    replacement: mark,
                    caretDelta: 3 + old.utf8.count + 2 + replacement.utf8.count)
            }
            return .refused
        }

        return .plain // zero-length no-op
    }

    /// True when inserting `insert` at byte `start` leaves the mark family
    /// intact: same mark count, and the caret still inside a growable body
    /// of the SAME payload kind. Guards the stateless-scan hazard where
    /// typing a sigil re-anchors the lazy closer (review MEDIUM).
    private static func plainInsertKeepsStructure(
        at start: Int, insert: String, in bytes: [UInt8], markCount: Int, body: Mark
    ) -> Bool {
        // Fast path: no sigil/brace character can't change parsing.
        if !insert.utf8.contains(where: { b in
            b == UInt8(ascii: "+") || b == UInt8(ascii: "-") || b == UInt8(ascii: "~")
                || b == UInt8(ascii: "=") || b == UInt8(ascii: ">")
                || b == UInt8(ascii: "{") || b == UInt8(ascii: "}")
        }) {
            return true
        }
        var candidate = bytes
        candidate.insert(contentsOf: Array(insert.utf8), at: start)
        let slice = String(decoding: candidate, as: UTF8.self)
        let marks = scanMarks(in: slice)
        guard marks.count == markCount else { return false }
        let caret = start + insert.utf8.count
        // The caret must land in a GROWABLE BODY of the same kind — not
        // merely inside the mark's range. A `}` that re-anchors the closer
        // early leaves the caret past the body (in the leaked tail), which
        // this rejects even though the range still nominally contains it.
        return marks.contains { m in
            guard samePayloadKind(m.payload, body.payload) else { return false }
            let lower: Int
            if case .substitution = m.payload, let arrow = m.arrowOffset {
                lower = arrow + 2
            } else {
                lower = m.bodyStart
            }
            return caret >= lower && caret <= m.bodyEnd
        }
    }

    private static func samePayloadKind(_ a: CriticMark.Payload, _ b: CriticMark.Payload) -> Bool {
        switch (a, b) {
        case (.insertion, .insertion), (.deletion, .deletion),
             (.substitution, .substitution), (.comment, .comment), (.highlight, .highlight):
            return true
        default:
            return false
        }
    }

    // MARK: - Scanning

    private static func scanMarks(in slice: String) -> [Mark] {
        var marks: [Mark] = []
        for segment in CriticScanner.scan(slice) {
            guard case .mark(let mark) = segment else { continue }
            let bytes = Array(slice.utf8)
            let start = mark.range.offset
            let end = mark.range.offset + mark.range.length
            // The trailing {#id} reference, when present, sits after the
            // closing sigil: body end = closer start.
            var closerStart = end - 3
            if mark.id != nil {
                // "{#" + id + "}"
                closerStart = end - 3 - (mark.id!.utf8.count + 3)
            }
            var arrow: Int?
            if case .substitution = mark.payload {
                var i = start + 3
                while i + 1 < closerStart {
                    if bytes[i] == UInt8(ascii: "~"), bytes[i + 1] == UInt8(ascii: ">") {
                        arrow = i
                        break
                    }
                    i += 1
                }
            }
            marks.append(Mark(
                range: mark.range,
                payload: mark.payload,
                bodyStart: start + 3,
                bodyEnd: closerStart,
                arrowOffset: arrow))
        }
        return marks
    }

    /// The UTF-8 range of the CHARACTER ending exactly at `end` — backspace
    /// must consume a whole grapheme, never tear a multi-byte sequence.
    private static func characterRange(endingAt end: Int, in slice: String) -> Range<Int>? {
        guard end > 0 else { return nil }
        guard let endIndex = slice.utf8.index(
            slice.utf8.startIndex, offsetBy: end, limitedBy: slice.utf8.endIndex),
            let stringEnd = endIndex.samePosition(in: slice),
            stringEnd > slice.startIndex
        else { return nil }
        let charStart = slice.index(before: stringEnd)
        let startOffset = slice.utf8.distance(from: slice.utf8.startIndex, to: charStart.samePosition(in: slice.utf8)!)
        return startOffset..<end
    }
}
