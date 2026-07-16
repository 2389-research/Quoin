import Foundation

// MARK: - CriticMarkup scanning (suggestions design, S1)

/// One CriticMarkup mark found in a raw source slice.
///
/// Grammar (docs/design/suggestions.md §2 — classic CriticMarkup):
/// `{++ins++}` `{--del--}` `{~~old~>new~~}` `{>>comment<<}` `{==highlight==}`
/// — `{` + doubled sigil + lazily-matched content + doubled sigil + `}`;
/// substitution splits on the FIRST `~>` (the reference toolkit's regex
/// rejects a bare `>` in the old half — a documented bug we do not
/// reproduce). An optional RDFM `{#id}` reference immediately after the
/// closer attaches metadata identity (surfaced in S2; recognized now so it
/// never renders as literal braces).
public struct CriticMark: Hashable, Sendable {
    public enum Payload: Hashable, Sendable {
        case insertion(String)
        case deletion(String)
        case substitution(old: String, new: String)
        case comment(String)
        case highlight(String)
    }
    public let payload: Payload
    /// Byte range of the WHOLE mark (opening `{` through closing `}`,
    /// including any trailing `{#id}` reference), relative to the scanned
    /// slice. The builder rebases it onto the block's absolute range —
    /// accept/reject in S2 splices exactly these bytes.
    public let range: ByteRange
    /// RDFM `{#id}` reference (e.g. "c1", "s2"), when present.
    public let id: String?
}

/// Raw-slice scanner for CriticMarkup, mirroring `MathScanner`'s segment
/// philosophy: cmark cannot parse these marks — smart punctuation turns
/// `--` into en-dashes and GFM strikethrough consumes `{~~…~~}` interiors —
/// so only the raw slice can see them (suggestions design §3). Inline code
/// spans (backtick runs, length-matched) and math spans (`$…$`, `$$…$$`,
/// `\(…\)`, `\[…\]`) are OPAQUE: a mark inside them stays literal text, per
/// the RDFM normative rule; math inside a TEXT segment still routes through
/// `MathScanner` downstream. Unbalanced marks degrade to literal text (the
/// `spliceHighlights` philosophy — never half-eat).
public enum CriticScanner {

    public enum Segment: Hashable, Sendable {
        /// Raw text between marks — may still contain markdown and math;
        /// the caller re-parses it.
        case text(String)
        case mark(CriticMark)
    }

    /// Cheap routing check: does this slice plausibly contain a mark?
    public static func containsMark(_ text: String) -> Bool {
        guard text.contains("{") else { return false }
        return text.contains("{++") || text.contains("{--") || text.contains("{~~")
            || text.contains("{>>") || text.contains("{==")
    }

    // Immutable table of pure builder closures — safe to share across
    // concurrency domains; the `@Sendable` closures + nonisolated(unsafe)
    // say so to Swift 6 without wrapping a read-only constant in a lock.
    private nonisolated(unsafe) static let openers: [(sigil: [UInt8], closer: [UInt8], make: @Sendable (String) -> CriticMark.Payload?)] = [
        (Array("{++".utf8), Array("++}".utf8), { .insertion($0) }),
        (Array("{--".utf8), Array("--}".utf8), { .deletion($0) }),
        (Array("{~~".utf8), Array("~~}".utf8), { content in
            // Split on the FIRST `~>`; a substitution without an arrow is
            // not a substitution — degrade to literal.
            guard let arrow = firstArrow(in: Array(content.utf8)) else { return nil }
            let bytes = Array(content.utf8)
            let old = String(decoding: bytes[0..<arrow], as: UTF8.self)
            let new = String(decoding: bytes[(arrow + 2)...], as: UTF8.self)
            return .substitution(old: old, new: new)
        }),
        (Array("{>>".utf8), Array("<<}".utf8), { .comment($0) }),
        (Array("{==".utf8), Array("==}".utf8), { .highlight($0) }),
    ]

    private static func firstArrow(in bytes: [UInt8]) -> Int? {
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == UInt8(ascii: "~"), bytes[i + 1] == UInt8(ascii: ">") { return i }
            i += 1
        }
        return nil
    }

    public static func scan(_ text: String) -> [Segment] {
        let bytes = Array(text.utf8)
        var segments: [Segment] = []
        var textStart = 0
        var i = 0

        func flushText(upTo end: Int) {
            guard end > textStart else { return }
            segments.append(.text(String(decoding: bytes[textStart..<end], as: UTF8.self)))
        }

        while i < bytes.count {
            let byte = bytes[i]

            // Inline code span: a backtick run is closed only by a run of the
            // SAME length (CommonMark); everything inside is opaque.
            if byte == UInt8(ascii: "`") {
                var runLength = 0
                while i + runLength < bytes.count, bytes[i + runLength] == UInt8(ascii: "`") {
                    runLength += 1
                }
                if let close = closingBacktickRun(in: bytes, from: i + runLength, length: runLength) {
                    i = close + runLength
                } else {
                    i += runLength
                }
                continue
            }

            // Math spans are opaque: $…$/$$…$$ and \(…\)/\[…\]. But only
            // REAL spans — the validity rules mirror MathScanner's, byte
            // for byte, or the two scanners disagree about what is math:
            // the naive skip treated "costs $5 … $10" as one span and
            // swallowed any mark between the amounts (panel review, HIGH).
            if byte == UInt8(ascii: "$") {
                if i > 0, bytes[i - 1] == UInt8(ascii: "\\") {
                    i += 1 // escaped dollar: literal
                    continue
                }
                if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "$") {
                    if let close = closingDoubleDollar(in: bytes, from: i + 2) {
                        i = close + 2
                    } else {
                        i += 2 // no closer: literal `$$`
                    }
                    continue
                }
                if let close = closingSingleDollar(in: bytes, from: i + 1) {
                    i = close + 1
                } else {
                    i += 1 // currency / lone dollar: literal, keep scanning
                }
                continue
            }
            if byte == UInt8(ascii: "\\"), i + 1 < bytes.count {
                let next = bytes[i + 1]
                if next == UInt8(ascii: "(") || next == UInt8(ascii: "[") {
                    let closer: [UInt8] = next == UInt8(ascii: "(") ? Array("\\)".utf8) : Array("\\]".utf8)
                    if let close = find(closer, in: bytes, from: i + 2) {
                        i = close + 2
                        continue
                    }
                }
                i += 2 // any other escape: skip the pair
                continue
            }

            if byte == UInt8(ascii: "{") {
                var matched = false
                for opener in openers where matches(opener.sigil, in: bytes, at: i) {
                    guard let close = find(opener.closer, in: bytes, from: i + opener.sigil.count) else { continue }
                    let content = String(
                        decoding: bytes[(i + opener.sigil.count)..<close], as: UTF8.self)
                    guard let payload = opener.make(content) else { continue }
                    var end = close + opener.closer.count
                    var id: String?
                    if let (reference, referenceEnd) = idReference(in: bytes, at: end) {
                        id = reference
                        end = referenceEnd
                    }
                    flushText(upTo: i)
                    segments.append(.mark(CriticMark(
                        payload: payload,
                        range: ByteRange(offset: i, length: end - i),
                        id: id)))
                    textStart = end
                    i = end
                    matched = true
                    break
                }
                if matched { continue }
            }

            i += 1
        }
        flushText(upTo: bytes.count)
        return segments
    }

    /// A trailing RDFM `{#id}` reference. Spec grammar: `ALPHA *( ALPHA /
    /// DIGIT / "_" / "-" )` — the FIRST character must be a letter, or the
    /// braces are literal prose a reference reader keeps (accepting
    /// `{#1abc}` made resolution delete bytes other readers preserve;
    /// panel review).
    private static func idReference(in bytes: [UInt8], at index: Int) -> (id: String, end: Int)? {
        guard index + 2 < bytes.count,
              bytes[index] == UInt8(ascii: "{"),
              bytes[index + 1] == UInt8(ascii: "#") else { return nil }
        let first = bytes[index + 2]
        guard (first >= UInt8(ascii: "a") && first <= UInt8(ascii: "z"))
            || (first >= UInt8(ascii: "A") && first <= UInt8(ascii: "Z")) else { return nil }
        var i = index + 2
        while i < bytes.count, bytes[i] != UInt8(ascii: "}") {
            let b = bytes[i]
            let ok = (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
                || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
                || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
                || b == UInt8(ascii: "-") || b == UInt8(ascii: "_")
            guard ok else { return nil }
            i += 1
        }
        guard i < bytes.count, i > index + 2 else { return nil }
        let id = String(decoding: bytes[(index + 2)..<i], as: UTF8.self)
        return (id, i + 1)
    }

    private static func isSpaceByte(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    /// Byte-wise mirror of `MathScanner.findClosingSingle` (Vinculum): the
    /// opener must not be followed by whitespace or `$`; a closer must not
    /// follow whitespace nor precede a digit; a blank line ends the scan.
    /// Divergence here is a bug — the two scanners must agree on what is
    /// math or marks near dollar amounts silently vanish.
    private static func closingSingleDollar(in bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count, !isSpaceByte(bytes[start]),
              bytes[start] != UInt8(ascii: "$") else { return nil }
        var i = start
        var lastNonSpace = -1
        var newlineRun = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "\\") { i += 2; continue }
            if b == UInt8(ascii: "\n") {
                newlineRun += 1
                if newlineRun >= 2 { break }
            } else if !isSpaceByte(b) {
                newlineRun = 0
            }
            if b == UInt8(ascii: "$") {
                let precededBySpace = lastNonSpace != i - 1
                let followedByDigit = i + 1 < bytes.count
                    && bytes[i + 1] >= UInt8(ascii: "0") && bytes[i + 1] <= UInt8(ascii: "9")
                if !precededBySpace, !followedByDigit, i > start {
                    return i
                }
                i += 1
                continue
            }
            if !isSpaceByte(b) { lastNonSpace = i }
            i += 1
        }
        return nil
    }

    /// Byte-wise mirror of `MathScanner.findClosingDouble`.
    private static func closingDoubleDollar(in bytes: [UInt8], from start: Int) -> Int? {
        var i = start
        while i + 1 < bytes.count {
            if bytes[i] == UInt8(ascii: "\\") { i += 2; continue }
            if bytes[i] == UInt8(ascii: "$"), bytes[i + 1] == UInt8(ascii: "$") { return i }
            i += 1
        }
        return nil
    }

    private static func matches(_ needle: [UInt8], in bytes: [UInt8], at index: Int) -> Bool {
        guard index + needle.count <= bytes.count else { return false }
        for (offset, byte) in needle.enumerated() where bytes[index + offset] != byte {
            return false
        }
        return true
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard needle.count > 0, start < bytes.count else { return nil }
        var i = start
        while i + needle.count <= bytes.count {
            if matches(needle, in: bytes, at: i) { return i }
            i += 1
        }
        return nil
    }

    private static func closingBacktickRun(in bytes: [UInt8], from start: Int, length: Int) -> Int? {
        var i = start
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "`") {
                var run = 0
                while i + run < bytes.count, bytes[i + run] == UInt8(ascii: "`") { run += 1 }
                if run == length { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }
}
