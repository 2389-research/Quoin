import Foundation

/// Smart-pair completion for the editor: typing an opening delimiter wraps
/// the caret in a closed pair; typing the closing half over an existing
/// closer skips it instead of doubling. Suspended inside code spans and
/// fences (design rule).
public enum SmartPairs {

    /// Delimiters that auto-close (handoff: `**` `_` `==` `$` `` ` ``).
    /// Single `*` completes too since `**` arrives as two keystrokes.
    static let pairs: Set<Character> = ["*", "_", "`", "$", "="]

    public struct Completion: Equatable, Sendable {
        /// Text to insert in place of the typed character(s).
        public let insert: String
        /// Caret position within `insert` (UTF-16) after insertion.
        public let caretOffset: Int
    }

    /// Wrapping: typing a pair delimiter with a non-empty selection wraps
    /// the selection instead of replacing it (select a word, press `*` →
    /// `*word*`). `=` wraps as the `==` highlight pair; every other pair
    /// char wraps with itself. Suspended inside code context, like
    /// `completion`. The returned `caretOffset` lands just before the
    /// closing delimiter so continued typing stays inside the span.
    public static func wrap(
        typing character: Character,
        selection: String,
        inText text: String,
        selectionStartUTF16 start: Int
    ) -> Completion? {
        guard pairs.contains(character), !selection.isEmpty else { return nil }
        guard !isInsideCodeContext(text: text, caretUTF16: start) else { return nil }
        // A selection that itself spans a newline isn't an inline span.
        guard !selection.contains("\n") else { return nil }
        let delimiter = character == "=" ? "==" : String(character)
        let wrapped = delimiter + selection + delimiter
        let caret = delimiter.utf16.count + selection.utf16.count
        return Completion(insert: wrapped, caretOffset: caret)
    }

    /// Decides how a single typed character behaves at `caretUTF16` in
    /// `text` (the active block's source). Returns nil for default handling.
    public static func completion(
        typing character: Character,
        inText text: String,
        caretUTF16 offset: Int
    ) -> Completion? {
        guard pairs.contains(character) else { return nil }
        guard !isInsideCodeContext(text: text, caretUTF16: offset) else { return nil }

        let caret = String.Index(utf16Offset: offset, in: text)
        let next: Character? = caret < text.endIndex ? text[caret] : nil

        // Type-over: the closing half already sits at the caret.
        if next == character {
            return Completion(insert: "", caretOffset: 1)
        }

        // `=` only pairs as part of `==`; a single equals is just text.
        if character == "=" {
            let previous: Character? = caret > text.startIndex ? text[text.index(before: caret)] : nil
            guard previous == "=" else { return nil }
            // Second `=` of an opener: complete to `==caret==`.
            return Completion(insert: "=" + "==", caretOffset: 1)
        }

        // Don't pair when gluing onto a word (typing *inside* text like
        // can*t); pairing is for starting a span.
        if let next, next.isLetter || next.isNumber {
            return nil
        }

        return Completion(insert: String(character) + String(character), caretOffset: 1)
    }

    /// True when the caret sits inside an inline code span or a code fence,
    /// where smart pairs are suspended.
    /// Public: the render layer's source styler shares this rule (span
    /// collapse is suspended inside code, same as pairing).
    public static func isInsideCodeContext(text: String, caretUTF16 offset: Int) -> Bool {
        var insideFence = false
        var backtickRun = 0
        var insideSpan = false
        var index = 0
        var atLineStart = true

        for unit in text.utf16 {
            if index >= offset { break }
            let ch = Character(Unicode.Scalar(unit) ?? " ")

            if ch == "`" {
                backtickRun += 1
            } else {
                if backtickRun >= 3 && atLineStart {
                    insideFence.toggle()
                } else if backtickRun > 0 && !insideFence {
                    insideSpan.toggle()
                }
                backtickRun = 0
                atLineStart = (ch == "\n")
            }
            index += 1
        }
        // Account for a run ending exactly at the caret.
        if backtickRun >= 3 && atLineStart {
            insideFence.toggle()
        } else if backtickRun > 0 && !insideFence {
            insideSpan.toggle()
        }
        return insideFence || insideSpan
    }
}

/// Selection-based format commands (⌘B/⌘I/⌘K/⇧⌘H): wrap or unwrap the
/// selected source text. Pure functions over the active block's source so
/// they're testable without a text system.
public enum Formatting {

    public struct Change: Equatable, Sendable {
        /// Replacement for the UTF-16 selection range that was passed in.
        public let replacement: String
        /// New selection within `replacement` (UTF-16).
        public let selectionOffset: Int
        public let selectionLength: Int
    }

    /// UTF-16 range of the word surrounding `caret` in `text`, or nil when
    /// the caret sits on whitespace/punctuation with no adjacent word. Lets
    /// ⌘B/⌘I/⇧⌘H with no selection format the word under the caret.
    public static func wordRange(in text: String, around caret: Int) -> (offset: Int, length: Int)? {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return nil }
        func isWord(_ unit: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return false }
            let ch = Character(scalar)
            return ch.isLetter || ch.isNumber || ch == "_"
        }
        var start = min(max(caret, 0), units.count)
        var end = start
        while start > 0, isWord(units[start - 1]) { start -= 1 }
        while end < units.count, isWord(units[end]) { end += 1 }
        guard end > start else { return nil }
        return (start, end - start)
    }

    /// Toggles a symmetric delimiter (e.g. `**`, `*`, `==`) around the
    /// selected text.
    public static func toggleWrap(selection: String, delimiter: String) -> Change {
        let hasWrap = selection.hasPrefix(delimiter) && selection.hasSuffix(delimiter)
            && selection.count >= delimiter.count * 2
        if hasWrap {
            let inner = String(selection.dropFirst(delimiter.count).dropLast(delimiter.count))
            return Change(replacement: inner, selectionOffset: 0, selectionLength: inner.utf16.count)
        }
        let wrapped = delimiter + selection + delimiter
        return Change(
            replacement: wrapped,
            selectionOffset: delimiter.utf16.count,
            selectionLength: selection.utf16.count
        )
    }

    /// ⇧⌘H: cycles the selection through the highlight palette.
    /// Unhighlighted → `==sel==` (lime) → `=={pink}sel==` → … →
    /// `=={orange}sel==` → back to plain text.
    public static func cycleHighlight(selection: String) -> Change {
        guard selection.hasPrefix("=="), selection.hasSuffix("=="), selection.count >= 4 else {
            // Wrap, keeping the delimiters inside the selection so a
            // repeated ⇧⌘H advances the cycle rather than re-wrapping.
            let wrapped = "==" + selection + "=="
            return Change(replacement: wrapped, selectionOffset: 0, selectionLength: wrapped.utf16.count)
        }
        var inner = String(selection.dropFirst(2).dropLast(2))
        var current = HighlightColor.lime
        if inner.hasPrefix("{"),
           let close = inner.firstIndex(of: "}"),
           let color = HighlightColor(rawValue: String(inner[inner.index(after: inner.startIndex)..<close])) {
            current = color
            inner = String(inner[inner.index(after: close)...])
        }

        let palette = HighlightColor.allCases
        guard let index = palette.firstIndex(of: current), index + 1 < palette.count else {
            // Last color: unwrap back to plain text.
            return Change(replacement: inner, selectionOffset: 0, selectionLength: inner.utf16.count)
        }
        let next = palette[index + 1]
        let prefix = "=={\(next.rawValue)}"
        return Change(
            replacement: prefix + inner + "==",
            selectionOffset: 0,
            selectionLength: (prefix + inner).utf16.count + 2
        )
    }

    /// Wraps the selection as a link: `[selection](url)`, selecting the URL
    /// placeholder for immediate typing.
    public static func makeLink(selection: String, url: String = "url") -> Change {
        let text = selection.isEmpty ? "link" : selection
        let replacement = "[\(text)](\(url))"
        let offset = 1 + text.utf16.count + 2 // past "[text]("
        return Change(replacement: replacement, selectionOffset: offset, selectionLength: url.utf16.count)
    }
}
