import Foundation

/// Footnote accumulation during a parse, split out of the converter's `Builder`.
///
/// Owns the two footnote maps — reference `ordinals` (assigned as `[^id]`
/// references are seen) and definition `blocks` (`[^id]: …`, built by the
/// converter's inline pipeline and stored here) — plus the pure definition
/// parsing. The only converter-pipeline dependency, the placeholder for an
/// undefined reference, is injected into `gather` as a closure so this type
/// stays free of the `Builder`'s shared conversion state.
struct FootnoteCollector {
    /// `[^id]` reference → 1-based order of first appearance.
    var ordinals: [String: Int] = [:]
    /// `[^id]` → the definition's converted blocks.
    var definitions: [String: [Block]] = [:]

    /// Footnotes in document order: referenced ids first in reference order (an
    /// undefined reference gets a `missing` placeholder), then defined-but-
    /// unreferenced ids appended after.
    func gather(missing: (String) -> [Block]) -> [Footnote] {
        var footnotes: [Footnote] = []
        for (id, index) in ordinals.sorted(by: { $0.value < $1.value }) {
            footnotes.append(Footnote(id: id, index: index, blocks: definitions[id] ?? missing(id)))
        }
        var nextIndex = ordinals.count + 1
        for (id, blocks) in definitions.sorted(by: { $0.key < $1.key }) where ordinals[id] == nil {
            footnotes.append(Footnote(id: id, index: nextIndex, blocks: blocks))
            nextIndex += 1
        }
        return footnotes
    }

    /// A single `[^id]: content` definition line, or nil when the slice does
    /// not open with a definition.
    static func parseDefinition(_ slice: String) -> (id: String, content: String)? {
        guard slice.hasPrefix("[^"),
              let close = slice.firstIndex(of: "]"),
              slice.index(after: close) < slice.endIndex,
              slice[slice.index(after: close)] == ":"
        else { return nil }
        let id = String(slice[slice.index(slice.startIndex, offsetBy: 2)..<close])
        guard !id.isEmpty, !id.contains(where: \.isWhitespace) else { return nil }
        let content = String(slice[slice.index(close, offsetBy: 2)...])
            .trimmingCharacters(in: .whitespaces)
        return (id: id, content: content)
    }

    /// Every definition in a paragraph slice that OPENS with one: adjacent
    /// `[^id]:` lines share a single cmark paragraph, so each definition line
    /// starts a new entry and other lines continue the current one. Empty when
    /// the slice isn't a definition paragraph.
    static func parseDefinitions(_ slice: String) -> [(id: String, content: String)] {
        guard parseDefinition(slice) != nil else { return [] }
        var definitions: [(id: String, content: String)] = []
        var current: (id: String, lines: [String])?
        // `\r\n` is one grapheme: split(separator: "\n") would keep CRLF
        // lines glued (line-walker rule).
        for line in slice.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            if let next = parseDefinition(String(line)) {
                if let current {
                    definitions.append((current.id, current.lines.joined(separator: "\n")))
                }
                current = (next.id, [next.content])
            } else {
                current?.lines.append(String(line))
            }
        }
        if let current {
            definitions.append((current.id, current.lines.joined(separator: "\n")))
        }
        return definitions
    }
}
