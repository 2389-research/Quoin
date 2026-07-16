import Foundation

/// Inline post-passes that run after cmark conversion, following the same
/// philosophy as `MathScanner`: cmark has no extension for these, so Quoin
/// recognizes them itself and degrades to literal text when unbalanced.
enum InlinePostPasses {

    // MARK: - ==highlight==

    /// Splices `==highlighted==` spans into an inline list. Spans may cross
    /// inline nodes (`==bold **text** end==`); an unclosed `==` stays literal.
    /// Opener must not be followed by whitespace, closer not preceded by it.
    static func spliceHighlights(into inlines: [Inline], stats: inout DocumentStats) -> [Inline] {
        var result: [Inline] = []
        var pending: [Inline] = []       // collected content inside an open ==
        var isOpen = false

        func flushUnclosed() {
            guard isOpen else { return }
            // Reinsert the literal opener and everything collected.
            result.append(.text("=="))
            result.append(contentsOf: pending)
            pending = []
            isOpen = false
        }

        func emit(_ inline: Inline) {
            if isOpen { pending.append(inline) } else { result.append(inline) }
        }

        for inline in inlines {
            guard case .text(let text) = inline, text.contains("==") else {
                emit(inline)
                continue
            }
            var remainder = Substring(text)
            while let range = remainder.range(of: "==") {
                let before = String(remainder[..<range.lowerBound])
                let after = remainder[range.upperBound...]
                if !isOpen {
                    // Candidate opener: must be followed by non-whitespace.
                    if let first = after.first, !first.isWhitespace {
                        if !before.isEmpty { emit(.text(before)) }
                        isOpen = true
                        pending = []
                    } else {
                        emit(.text(before + "=="))
                    }
                } else {
                    // Candidate closer: must be preceded by non-whitespace.
                    if let last = before.last, !last.isWhitespace {
                        if !before.isEmpty { pending.append(.text(before)) }
                        isOpen = false
                        stats.highlightCount += 1
                        let color = extractColorTag(&pending)
                        result.append(.highlight(pending, color))
                        pending = []
                    } else {
                        pending.append(.text(before + "=="))
                    }
                }
                remainder = after
            }
            if !remainder.isEmpty { emit(.text(String(remainder))) }
        }
        flushUnclosed()
        return result
    }

    /// Strips a leading `{color}` tag from the span content and returns the
    /// palette color it names; unknown names stay literal text, no tag = lime.
    private static func extractColorTag(_ pending: inout [Inline]) -> HighlightColor {
        guard case .text(let text)? = pending.first,
              text.hasPrefix("{"),
              let close = text.firstIndex(of: "}"),
              let color = HighlightColor(rawValue: String(text[text.index(after: text.startIndex)..<close]))
        else { return .lime }
        let rest = String(text[text.index(after: close)...])
        if rest.isEmpty {
            pending.removeFirst()
        } else {
            pending[0] = .text(rest)
        }
        return color
    }

    // MARK: - [^id] footnote references

    /// Replaces `[^id]` occurrences in text runs with footnote references.
    /// `ordinals` assigns 1-based numbers in order of first appearance.
    static func spliceFootnoteReferences(
        into inlines: [Inline],
        ordinals: inout [String: Int]
    ) -> [Inline] {
        func ordinal(_ id: String) -> Int {
            if let existing = ordinals[id] { return existing }
            let next = ordinals.count + 1
            ordinals[id] = next
            return next
        }
        var result: [Inline] = []
        for inline in inlines {
            guard case .text(let text) = inline, text.contains("[^") else {
                result.append(inline)
                continue
            }
            var remainder = Substring(text)
            while let open = remainder.range(of: "[^") {
                guard let close = remainder[open.upperBound...].firstIndex(of: "]") else { break }
                let id = String(remainder[open.upperBound..<close])
                guard !id.isEmpty, !id.contains(where: \.isWhitespace) else {
                    // Not a footnote; emit through the bracket and continue.
                    result.append(.text(String(remainder[..<open.upperBound])))
                    remainder = remainder[open.upperBound...]
                    continue
                }
                let before = String(remainder[..<open.lowerBound])
                if !before.isEmpty { result.append(.text(before)) }
                result.append(.footnoteReference(id: id, index: ordinal(id)))
                remainder = remainder[remainder.index(after: close)...]
            }
            if !remainder.isEmpty { result.append(.text(String(remainder))) }
        }
        return result
    }

    // MARK: - Front matter

    /// Splits leading YAML front matter (`---\n…\n---`) from the source.
    /// Returns the YAML body and the byte length of the whole front-matter
    /// block including its closing delimiter line.
    ///
    /// Delegates to `FrontMatterEditing.block(in:)` — ONE recognizer for
    /// the grammar (its writers depend on agreeing with the converter),
    /// and its byte-level walk sees CRLF documents: the old Character
    /// split never split `\r\n` lines (one grapheme), so CRLF front
    /// matter silently parsed as a thematic break plus prose.
    static func frontMatter(in source: String) -> (yaml: String, byteLength: Int)? {
        guard let block = FrontMatterEditing.block(in: source) else { return nil }
        return (yaml: block.yaml, byteLength: block.length)
    }
}
