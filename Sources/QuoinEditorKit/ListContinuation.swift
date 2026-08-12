import Foundation

/// PURE marker continuation for the editable-islands Return handler (Phase 3,
/// Task 6). Given the current island LINE UP TO THE CARET, decide what Return
/// does inside a list or a block-quote:
///
/// - `.continue(String)` — insert this string (always begins with `\n`) to open
///   a fresh sibling row that carries the SAME marker and leading indent.
///   Ordered markers INCREMENT their number; task items reset to an unchecked
///   box; the bullet char (`-`/`*`/`+`), the ordered delimiter (`.`/`)`), and
///   the nesting indent/depth are all preserved.
/// - `.exit` — the current line is a marker with no content (an EMPTY item, or a
///   `> ` with nothing after it). Return should DELETE that trailing marker so
///   the item collapses to a blank line, exiting the list/quote. The controller
///   realizes this by removing the line's marker text (see `IslandController`).
///
/// This type is platform-free (Foundation only, no AppKit) and exhaustively
/// unit-tested. It NEVER throws or crashes: any line that does not match a
/// marker pattern in a list/quote context falls back to `.continue("\n")` (a
/// plain soft break), so an unexpected shape degrades to a bare newline rather
/// than corrupting the source.
///
/// The input is the line's `start ..< caret` substring (NOT the whole line): the
/// contract is "what has been typed on this line so far". An item is EMPTY when
/// nothing but whitespace follows its marker up to the caret.
public enum ListContinuation: Equatable {
    /// Insert this string at the caret (always leads with `\n`).
    case `continue`(String)
    /// Delete the current line's marker — the item is empty; exit the list/quote.
    case exit

    /// LIST continuation (`.listAware`). Parses the leading indent + bullet or
    /// ordered marker (optionally a task checkbox) off `lineUpToCaret`.
    public static func list(lineUpToCaret line: String) -> ListContinuation {
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        let indent = String(chars[0 ..< i])
        guard i < chars.count else { return .continue("\n") }

        let c = chars[i]

        // Unordered bullet: - * +  (optionally a task checkbox).
        if c == "-" || c == "*" || c == "+" {
            var j = i + 1
            // A real marker is the bullet followed by a space (or end-of-line
            // while the marker is still being typed). "- text" glued with no
            // space ("-text") is not a marker → fall back.
            guard j >= chars.count || chars[j] == " " else { return .continue("\n") }
            if j < chars.count, chars[j] == " " { j += 1 }

            // Task item? "[ ]" / "[x]" / "[X]" immediately after the bullet+space.
            if let box = taskCheckboxLength(Array(chars[j...])) {
                var k = j + box
                if k < chars.count, chars[k] == " " { k += 1 }
                if isBlank(chars[k...]) { return .exit }
                // Continue as a FRESH unchecked box (never copy the checked state).
                return .continue("\n" + indent + String(c) + " [ ] ")
            }

            if isBlank(chars[j...]) { return .exit }
            return .continue("\n" + indent + String(c) + " ")
        }

        // Ordered marker: <digits> ('.' or ')') space.
        if c.isNumber {
            var j = i
            while j < chars.count, chars[j].isNumber { j += 1 }
            let digits = String(chars[i ..< j])
            guard j < chars.count, chars[j] == "." || chars[j] == ")" else {
                return .continue("\n")
            }
            let delimiter = chars[j]
            j += 1
            guard j >= chars.count || chars[j] == " " else { return .continue("\n") }
            if j < chars.count, chars[j] == " " { j += 1 }
            if isBlank(chars[j...]) { return .exit }
            let next = (Int(digits) ?? 0) + 1
            return .continue("\n" + indent + "\(next)" + String(delimiter) + " ")
        }

        return .continue("\n")
    }

    /// QUOTE continuation (`.quoteAware`). Parses the nested `> ` prefix (any
    /// depth) off `lineUpToCaret`; an empty quoted line exits.
    public static func quote(lineUpToCaret line: String) -> ListContinuation {
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        let indent = String(chars[0 ..< i])
        guard i < chars.count, chars[i] == ">" else { return .continue("\n") }

        var depth = 0
        while i < chars.count, chars[i] == ">" {
            depth += 1
            i += 1
            if i < chars.count, chars[i] == " " { i += 1 }
        }
        if isBlank(chars[i...]) { return .exit }
        let prefix = indent + String(repeating: "> ", count: depth)
        return .continue("\n" + prefix)
    }

    // MARK: - Helpers

    /// Length (3) if `rest` begins with a GFM task checkbox `[ ]`/`[x]`/`[X]`.
    private static func taskCheckboxLength(_ rest: [Character]) -> Int? {
        guard rest.count >= 3, rest[0] == "[", rest[2] == "]" else { return nil }
        let inner = rest[1]
        return (inner == " " || inner == "x" || inner == "X") ? 3 : nil
    }

    /// True when the slice is empty or entirely spaces/tabs — an empty item.
    private static func isBlank(_ slice: ArraySlice<Character>) -> Bool {
        for ch in slice where ch != " " && ch != "\t" { return false }
        return true
    }
}
