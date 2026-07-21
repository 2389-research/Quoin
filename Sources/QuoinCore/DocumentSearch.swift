import Foundation

/// A single search hit: which block it's in and where within that block's
/// plain-text projection.
public struct SearchMatch: Hashable, Sendable, Identifiable {
    public let blockID: BlockID
    /// Character range within the block's plain-text projection.
    public let textRange: Range<Int>
    public let ordinal: Int

    public var id: Int { ordinal }
}

/// Case- and diacritic-insensitive as-you-type search over the document's
/// plain-text projection. The projection is computed once per document
/// snapshot; each query is a linear scan (well under a frame for 1 MB docs).
public struct DocumentSearch: Sendable {

    public struct BlockText: Sendable {
        public let blockID: BlockID
        public let text: String
    }

    public let blockTexts: [BlockText]

    public init(document: QuoinDocument) {
        var texts: [BlockText] = []
        func walk(_ blocks: [Block]) {
            for block in blocks {
                switch block.kind {
                case .heading(_, let inlines, _), .paragraph(let inlines):
                    texts.append(BlockText(blockID: block.id, text: inlines.plainText))
                case .codeBlock(_, let code):
                    texts.append(BlockText(blockID: block.id, text: code))
                case .diagram(let source, _):
                    texts.append(BlockText(blockID: block.id, text: source))
                case .mathBlock(let latex):
                    texts.append(BlockText(blockID: block.id, text: latex))
                case .table(let header, let rows, _):
                    let cells = (header + rows.flatMap { $0 }).map { $0.inlines.plainText }
                    texts.append(BlockText(blockID: block.id, text: cells.joined(separator: " ")))
                case .list(let items, _, _):
                    for item in items { walk(item.blocks) }
                case .blockQuote(let children), .callout(_, let children):
                    walk(children)
                case .htmlBlock(let html):
                    texts.append(BlockText(blockID: block.id, text: html))
                case .frontMatter(let yaml):
                    texts.append(BlockText(blockID: block.id, text: yaml))
                case .reviewEndmatter(let yaml):
                    texts.append(BlockText(blockID: block.id, text: yaml))
                case .thematicBreak, .tableOfContents:
                    break
                }
            }
        }
        walk(document.blocks)
        for footnote in document.footnotes { walk(footnote.blocks) }
        self.blockTexts = texts
    }

    public func matches(for query: String) -> [SearchMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [SearchMatch] = []
        var ordinal = 0
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        for blockText in blockTexts {
            let text = blockText.text
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: trimmed, options: options, range: searchStart..<text.endIndex) {
                let lower = text.distance(from: text.startIndex, to: found.lowerBound)
                let upper = text.distance(from: text.startIndex, to: found.upperBound)
                results.append(SearchMatch(blockID: blockText.blockID, textRange: lower..<upper, ordinal: ordinal))
                ordinal += 1
                searchStart = found.upperBound > found.lowerBound
                    ? found.upperBound
                    : text.index(after: found.lowerBound)
            }
        }
        return results
    }
}
