import Foundation

/// Commit-time fence healing (ledger senior #10, embed brief tranche-2 #1).
///
/// Editing a fenced block's source and deleting its closing fence makes the
/// fence swallow every following block — the bytes are honest, but the
/// rendered document "loses" content and users panic. When such a block is
/// COMMITTED (Escape, ✓ done, click-away) still broken, the session appends
/// the closing line as an ordinary, undoable edit.
public enum FenceHealing {

    /// The suffix to append when `source` (the block's full slice) opens a
    /// fence it no longer closes; nil when the block needs no healing.
    /// Handles ``` and ~~~ fences (length ≥ opener, indentation preserved)
    /// and `$$` math blocks. Indented code has no fence and never heals.
    public static func healingSuffix(for source: String, kind: BlockKind) -> String? {
        switch kind {
        case .codeBlock, .mermaid:
            return fencedCodeSuffix(for: source)
        case .mathBlock:
            return mathSuffix(for: source)
        default:
            return nil
        }
    }

    private static func fencedCodeSuffix(for source: String) -> String? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard let opener = lines.first, let fence = fenceHead(of: opener) else {
            return nil // indented code block: no fence to heal
        }
        for line in lines.dropFirst() {
            if let close = fenceHead(of: line),
               close.char == fence.char,
               close.length >= fence.length,
               line.drop(while: { $0 == " " }).allSatisfy({ $0 == close.char }) {
                return nil // properly closed
            }
        }
        let closing = fence.indent + String(repeating: String(fence.char), count: fence.length)
        return (source.hasSuffix("\n") ? "" : "\n") + closing
    }

    /// The fence introducer of a line: up to 3 leading spaces, then 3+ of
    /// the same fence character.
    private static func fenceHead(of line: Substring) -> (char: Character, length: Int, indent: String)? {
        let indent = line.prefix(while: { $0 == " " })
        guard indent.count <= 3 else { return nil }
        let rest = line.dropFirst(indent.count)
        guard let char = rest.first, char == "`" || char == "~" else { return nil }
        let run = rest.prefix(while: { $0 == char }).count
        guard run >= 3 else { return nil }
        // An opener may carry an info string; backtick openers may not
        // contain further backticks in it, but healing doesn't need that
        // strictness — the parser already decided this block is fenced.
        return (char, run, String(indent))
    }

    private static func mathSuffix(for source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$$") else { return nil }
        // A bare `$$` is ambiguous (opener or empty block) — leave it.
        guard trimmed != "$$" else { return nil }
        // Healthy display math ends with a `$$` that isn't the opener.
        if trimmed.count >= 4, trimmed.hasSuffix("$$") { return nil }
        return (source.hasSuffix("\n") ? "" : "\n") + "$$"
    }
}
