import Foundation
import VinculumLayout

/// Pre-cmark protection for standalone display-math blocks (`$$…$$` or
/// `\[…\]` with each delimiter alone on its own line).
///
/// cmark has no math extension: an interior line of bare `=` (setext
/// underline) or `---` (thematic break) tears the span into paragraph +
/// phantom heading + orphaned tail BEFORE the converter's math pass can
/// run — the heading even enters the outline. These spans are therefore
/// claimed from the RAW source first (the same split-before-cmark
/// precedent as front matter and review endmatter) and the segments
/// between them are parsed separately.
///
/// Detection is deliberately conservative — a rejected span merely falls
/// through to cmark and the existing paragraph-slice math pass:
/// - opener (`$$` / `\[`) is a whole line at column 0, preceded by a
///   blank line or the start of input;
/// - closer (`$$` / `\]`) is a whole line, followed by a blank line or
///   the end of input;
/// - no blank line inside the span (cmark would split there regardless);
/// - `MathScanner.scan` confirms the span as exactly ONE `.displayMath`
///   segment — self-calibration against the scanner the paragraph path
///   uses, so prose with a stray `\[` is never swallowed.
enum DisplayMathPrescan {

    struct Span: Equatable {
        /// Byte range of the span — opener line start through the closer's
        /// last content byte, EXCLUDING the trailing line terminator (the
        /// block-range convention used everywhere else).
        let range: ByteRange
        /// Byte offset just past the closer's line terminator; segment
        /// parsing resumes here.
        let resumeOffset: Int
        /// The confirmed latex (delimiters stripped, whitespace-trimmed by
        /// `MathScanner` exactly as on the paragraph-slice path).
        let latex: String
    }

    static func spans(in source: String) -> [Span] {
        // Cheap bail: no possible opener, no scan. Byte-level so the guard
        // itself isn't a grapheme-aware full-string search (see ByteScan).
        guard source.utf8Contains([0x24, 0x24]) || source.utf8Contains([0x5C, 0x5B])
        else { return [] }

        let bytes = Array(source.utf8)
        // Line table: (start, contentEnd, next) — contentEnd excludes the
        // `\n` AND a preceding `\r`, so CRLF documents classify identically.
        var lines: [(start: Int, contentEnd: Int, next: Int)] = []
        var lineStart = 0
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\n") {
                var contentEnd = i
                if contentEnd > lineStart, bytes[contentEnd - 1] == UInt8(ascii: "\r") {
                    contentEnd -= 1
                }
                lines.append((start: lineStart, contentEnd: contentEnd, next: i + 1))
                lineStart = i + 1
            }
            i += 1
        }
        if lineStart < bytes.count {
            lines.append((start: lineStart, contentEnd: bytes.count, next: bytes.count))
        }

        func isBlank(_ line: (start: Int, contentEnd: Int, next: Int)) -> Bool {
            for j in line.start..<line.contentEnd
            where bytes[j] != UInt8(ascii: " ") && bytes[j] != UInt8(ascii: "\t") {
                return false
            }
            return true
        }
        func content(_ line: (start: Int, contentEnd: Int, next: Int)) -> ArraySlice<UInt8> {
            bytes[line.start..<line.contentEnd]
        }

        // A `$$`/`\[` line INSIDE a fenced code block is code, not a math
        // opener (review HIGH: a fenced `$$…$$` was claimed, tearing the
        // code block apart and eating following prose). Precompute which
        // lines sit inside a ```/~~~ fence, conservatively per CommonMark:
        // an opener is 3+ of ` or ~ indented 0–3 spaces; the closer is 3+
        // of the SAME char, at least as long, with no trailing info text.
        var insideFence = [Bool](repeating: false, count: lines.count)
        var fenceChar: UInt8?
        var fenceLen = 0
        for (idx, line) in lines.enumerated() {
            let c = content(line)
            var p = c.startIndex
            var indent = 0
            while p < c.endIndex, c[p] == UInt8(ascii: " "), indent < 4 { p += 1; indent += 1 }
            let ch = p < c.endIndex ? c[p] : 0
            var runLen = 0
            var q = p
            while q < c.endIndex, c[q] == ch { runLen += 1; q += 1 }
            let isBacktickOrTilde = ch == UInt8(ascii: "`") || ch == UInt8(ascii: "~")
            if let open = fenceChar {
                insideFence[idx] = true // the closer line itself counts as fence
                if indent < 4, isBacktickOrTilde, ch == open, runLen >= fenceLen {
                    // Closer: rest of line must be blank.
                    var rest = q
                    while rest < c.endIndex, c[rest] == UInt8(ascii: " ") { rest += 1 }
                    if rest == c.endIndex { fenceChar = nil; fenceLen = 0 }
                }
            } else if indent < 4, isBacktickOrTilde, runLen >= 3 {
                // Backtick openers may not contain a backtick in the info
                // string; tildes may. Conservative: treat as a fence opener.
                fenceChar = ch
                fenceLen = runLen
                insideFence[idx] = true
            }
        }

        let dollarFence: [UInt8] = Array("$$".utf8)
        let bracketOpen: [UInt8] = Array("\\[".utf8)
        let bracketClose: [UInt8] = Array("\\]".utf8)

        var spans: [Span] = []
        var previousBlank = true
        var li = 0
        while li < lines.count {
            let openerContent = content(lines[li])
            let closer: [UInt8]?
            switch true {
            case openerContent.elementsEqual(dollarFence): closer = dollarFence
            case openerContent.elementsEqual(bracketOpen): closer = bracketClose
            default: closer = nil
            }
            if previousBlank, let closer, !insideFence[li] {
                var lj = li + 1
                var closerIndex: Int?
                while lj < lines.count {
                    if isBlank(lines[lj]) { break }               // blank inside → reject
                    if content(lines[lj]).elementsEqual(closer) { closerIndex = lj; break }
                    lj += 1
                }
                if let closerIndex,
                   closerIndex + 1 >= lines.count || isBlank(lines[closerIndex + 1]) {
                    let range = ByteRange(
                        offset: lines[li].start,
                        length: lines[closerIndex].contentEnd - lines[li].start)
                    if let text = source.substring(in: range) {
                        let segments = MathScanner.scan(text)
                        if segments.count == 1, case .displayMath(let latex) = segments[0] {
                            spans.append(Span(
                                range: range,
                                resumeOffset: lines[closerIndex].next,
                                latex: latex))
                            previousBlank = false
                            li = closerIndex + 1
                            continue
                        }
                    }
                }
            }
            previousBlank = isBlank(lines[li])
            li += 1
        }
        return spans
    }
}
