import Foundation

/// Structural line-prefix edits (#25): heading level, list/quote toggles, and
/// keyboard checkbox toggle. Each takes a block's SOURCE SLICE (the bytes at
/// `block.range`) and returns a replacement slice, so — like `BlockEditing` —
/// the bytes BETWEEN blocks are untouched and round-trip losslessness holds by
/// construction. All line handling is scalar-based to avoid Swift's
/// `\r\n`-is-one-Character trap (a `split(separator:"\n")` never splits CRLF),
/// and every transform preserves each line's original terminator exactly.
public enum StructureEditing {

    /// A physical line and its terminator (`""`, `"\n"`, or `"\r\n"`).
    struct Line {
        var content: String
        let terminator: String
    }

    /// Split into physical lines without tripping over CRLF graphemes. A slice
    /// that ends in a newline yields no phantom trailing empty line.
    static func lines(of slice: String) -> [Line] {
        var result: [Line] = []
        var content = String.UnicodeScalarView()
        let scalars = slice.unicodeScalars
        var i = scalars.startIndex
        while i < scalars.endIndex {
            let scalar = scalars[i]
            if scalar == "\n" {
                result.append(Line(content: String(content), terminator: "\n"))
                content = String.UnicodeScalarView()
            } else if scalar == "\r" {
                let next = scalars.index(after: i)
                if next < scalars.endIndex, scalars[next] == "\n" {
                    result.append(Line(content: String(content), terminator: "\r\n"))
                    content = String.UnicodeScalarView()
                    i = next // skip the paired \n on the next step
                } else {
                    content.append(scalar) // lone CR is ordinary content
                }
            } else {
                content.append(scalar)
            }
            i = scalars.index(after: i)
        }
        if !content.isEmpty {
            result.append(Line(content: String(content), terminator: ""))
        }
        return result
    }

    private static func join(_ lines: [Line]) -> String {
        lines.map { $0.content + $0.terminator }.joined()
    }

    // MARK: - Headings

    /// The leading `#` count of a line (0 when it is not an ATX heading).
    static func headingLevel(of content: String) -> Int {
        guard let range = content.range(of: "^(#{1,6})[ \\t]", options: .regularExpression) else { return 0 }
        return content.distance(from: range.lowerBound, to: content.index(before: range.upperBound))
    }

    private static func strippingHeading(_ content: String) -> String {
        guard let range = content.range(of: "^#{1,6}[ \\t]+", options: .regularExpression) else { return content }
        var copy = content
        copy.removeSubrange(range)
        return copy
    }

    /// Set a heading level on a single-line block (paragraph or heading).
    /// `level == 0` strips the heading to a plain paragraph; 1…6 sets that many
    /// `#`. Returns nil for multi-line slices or an out-of-range level — the
    /// caller no-ops.
    public static func settingHeadingLevel(_ slice: String, level: Int) -> String? {
        guard (0...6).contains(level) else { return nil }
        var parsed = lines(of: slice)
        guard parsed.count == 1 else { return nil }
        let text = strippingHeading(parsed[0].content)
        parsed[0].content = level == 0 ? text : String(repeating: "#", count: level) + " " + text
        return join(parsed)
    }

    /// Cycle a single-line block's heading level: none → 1 → 2 → … → 6 → none.
    public static func cyclingHeadingLevel(_ slice: String) -> String? {
        let parsed = lines(of: slice)
        guard parsed.count == 1 else { return nil }
        let current = headingLevel(of: parsed[0].content)
        return settingHeadingLevel(slice, level: current >= 6 ? 0 : current + 1)
    }

    // MARK: - Blockquote

    /// Toggle a `> ` prefix on every line. If every non-empty line is already
    /// quoted, the quote is stripped; otherwise every line gains `> `.
    public static func togglingQuote(_ slice: String) -> String? {
        var parsed = lines(of: slice)
        guard !parsed.isEmpty else { return nil }
        let quoted = parsed.allSatisfy { $0.content.isEmpty || $0.content.hasPrefix(">") }
        for index in parsed.indices {
            if quoted {
                var content = parsed[index].content
                if content.hasPrefix("> ") { content.removeFirst(2) }
                else if content.hasPrefix(">") { content.removeFirst(1) }
                parsed[index].content = content
            } else {
                parsed[index].content = "> " + parsed[index].content
            }
        }
        return join(parsed)
    }

    // MARK: - Lists

    /// Strip a leading list marker (`-`/`*`/`+ ` or `N. `), keeping indentation.
    private static func strippingListMarker(_ content: String) -> String {
        if let range = content.range(of: "^[ \\t]*([-*+]|\\d+\\.)[ \\t]+", options: .regularExpression) {
            // Preserve the original indentation, drop only the marker + gap.
            let indent = content.prefix { $0 == " " || $0 == "\t" }
            var copy = content
            copy.removeSubrange(range)
            return String(indent) + copy
        }
        return content
    }

    private static func isBullet(_ content: String) -> Bool {
        content.range(of: "^[ \\t]*[-*+][ \\t]", options: .regularExpression) != nil
    }

    private static func isOrdered(_ content: String) -> Bool {
        content.range(of: "^[ \\t]*\\d+\\.[ \\t]", options: .regularExpression) != nil
    }

    /// Toggle the block's lines into (or out of) a bullet or numbered list.
    /// When every non-empty line already has the target marker the list is
    /// stripped to plain paragraphs; otherwise each line gets the marker
    /// (ordered lists renumber from 1). Blank lines are left untouched.
    public static func togglingList(_ slice: String, ordered: Bool) -> String? {
        var parsed = lines(of: slice)
        let nonEmpty = parsed.filter { !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmpty.isEmpty else { return nil }

        let alreadyTarget = nonEmpty.allSatisfy { ordered ? isOrdered($0.content) : isBullet($0.content) }
        var ordinal = 1
        for index in parsed.indices {
            if parsed[index].content.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let stripped = strippingListMarker(parsed[index].content)
            if alreadyTarget {
                parsed[index].content = stripped
            } else if ordered {
                parsed[index].content = "\(ordinal). " + stripped
                ordinal += 1
            } else {
                parsed[index].content = "- " + stripped
            }
        }
        return join(parsed)
    }

    // MARK: - Checkbox

    /// Toggle the task checkbox on the line containing `caretUTF16` (a UTF-16
    /// offset into the slice). A `[ ]` becomes `[x]` and vice-versa; a bullet
    /// or plain line gains `- [ ] `. Returns nil when nothing sensible applies.
    public static func togglingCheckbox(_ slice: String, caretUTF16: Int) -> String? {
        var parsed = lines(of: slice)
        guard !parsed.isEmpty else { return nil }

        // Locate the caret's physical line by walking UTF-16 lengths.
        var consumed = 0
        var target = parsed.count - 1
        for (index, line) in parsed.enumerated() {
            let lineLength = line.content.utf16.count + line.terminator.utf16.count
            if caretUTF16 < consumed + lineLength {
                target = index
                break
            }
            consumed += lineLength
        }

        let content = parsed[target].content
        let indent = String(content.prefix { $0 == " " || $0 == "\t" })
        if content.range(of: "^[ \\t]*[-*+][ \\t]+\\[[ xX]\\][ \\t]", options: .regularExpression) != nil {
            // Existing checkbox → flip its state, leaving everything else intact.
            var copy = content
            if let boxRange = copy.range(of: "\\[[ xX]\\]", options: .regularExpression) {
                let checked = copy[boxRange] != "[ ]"
                copy.replaceSubrange(boxRange, with: checked ? "[ ]" : "[x]")
            }
            parsed[target].content = copy
        } else if isBullet(content) {
            // Plain bullet → task bullet: insert `[ ] ` after the marker.
            let stripped = strippingListMarker(content)
            parsed[target].content = indent + "- [ ] " + stripped.drop(while: { $0 == " " || $0 == "\t" })
        } else {
            // Plain line → task bullet.
            let stripped = String(content.drop(while: { $0 == " " || $0 == "\t" }))
            parsed[target].content = indent + "- [ ] " + stripped
        }
        return join(parsed)
    }
}
