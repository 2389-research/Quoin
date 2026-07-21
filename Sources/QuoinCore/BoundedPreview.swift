import Foundation

/// Hard limits for the Quick Look "fast/bounded" render mode (issue #8).
///
/// The Quick Look thumbnail/preview extension reuses the SAME parse/render
/// path as the app, but under caps that keep a pathological `.md` file cheap
/// to preview: the input is truncated to a byte budget BEFORE parsing, and the
/// parsed document is reduced to a bounded block list with expensive embeds
/// (Mermaid diagrams, display math) swapped for lightweight placeholders — the
/// extension NEVER runs the full Mermaid/Vinculum layout. These are caps on
/// input SIZE and layout WORK, not a wall-clock deadline; cmark-gfm is ~linear
/// at these sizes, and the OS Quick Look agent's own watchdog is the final
/// backstop for a stuck render (it yields no preview, never a Finder hang).
/// Raw HTML (the one remote-reachable escape hatch) is neutralised to inert
/// escaped text here, and the HTML preview additionally ships a restrictive CSP
/// — see QuickLookContent.
///
/// This is pure, platform-free logic (which blocks survive, how they are
/// truncated, what the placeholders say) so it is unit-tested in
/// `QuoinCoreTests`; the Quick Look classes stay thin.
public struct PreviewBounds: Sendable, Equatable {
    /// Maximum number of source UTF-8 bytes handed to the parser. Bounds
    /// parse time — the dominant cost — regardless of file size on disk.
    public var maxInputBytes: Int
    /// Maximum number of TOP-LEVEL blocks projected. Extra blocks are
    /// dropped and `blocksTruncated` is set.
    public var maxBlocks: Int
    /// Code blocks longer than this many lines are clipped (a trailing `…`
    /// line marks the cut).
    public var maxCodeLines: Int
    /// Tables keep at most this many body rows; lists at most this many
    /// items. Extra rows/items are dropped.
    public var maxRows: Int
    /// Whether gathered footnotes are carried into the preview.
    public var includeFootnotes: Bool

    public init(
        maxInputBytes: Int,
        maxBlocks: Int,
        maxCodeLines: Int,
        maxRows: Int,
        includeFootnotes: Bool
    ) {
        self.maxInputBytes = maxInputBytes
        self.maxBlocks = maxBlocks
        self.maxCodeLines = maxCodeLines
        self.maxRows = maxRows
        self.includeFootnotes = includeFootnotes
    }

    /// Tight budget for the small Finder/Spotlight thumbnail: only the top of
    /// the document is ever visible, so parse little and project few blocks.
    public static let thumbnail = PreviewBounds(
        maxInputBytes: 256 * 1024,
        maxBlocks: 40,
        maxCodeLines: 20,
        maxRows: 12,
        includeFootnotes: false)

    /// Looser budget for the full Quick Look preview panel (still bounded so
    /// the panel opens instantly).
    public static let preview = PreviewBounds(
        maxInputBytes: 1024 * 1024,
        maxBlocks: 400,
        maxCodeLines: 200,
        maxRows: 200,
        includeFootnotes: true)
}

/// The bounded projection of a document: a reduced `QuoinDocument` (safe to
/// hand to `HTMLExporter` or `AttributedRenderer` without triggering
/// diagram/math layout) plus flags describing what was cut.
public struct BoundedPreviewDocument: Sendable {
    /// The reduced document — placeholder-substituted and length-capped.
    public let document: QuoinDocument
    /// True when top-level blocks were dropped to satisfy `maxBlocks`.
    public let blocksTruncated: Bool
    /// True when the source was cut to satisfy `maxInputBytes` before parsing.
    public let inputTruncated: Bool

    public init(document: QuoinDocument, blocksTruncated: Bool, inputTruncated: Bool) {
        self.document = document
        self.blocksTruncated = blocksTruncated
        self.inputTruncated = inputTruncated
    }
}

/// Human-readable placeholder labels for embeds the bounded mode does not
/// lay out. Centralised so the thumbnail, the preview, and the tests all
/// agree on the exact wording.
public enum PreviewPlaceholder {
    public static let mermaid = "◆ Mermaid diagram"
    public static func math(_ latex: String) -> String {
        let oneLine = latex
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = oneLine.count > 80 ? String(oneLine.prefix(79)) + "…" : oneLine
        return clipped.isEmpty ? "∑ Math" : "∑ \(clipped)"
    }
    public static func image(alt: String) -> String {
        let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "🖼 image" : "🖼 \(trimmed)"
    }
}

public enum BoundedPreview {

    /// Parse-then-reduce entry point used by the Quick Look extension: cap the
    /// source, run the SHARED `MarkdownConverter`, then reduce.
    public static func make(fromSource source: String, bounds: PreviewBounds) -> BoundedPreviewDocument {
        let (capped, inputTruncated) = truncatedSource(source, maxBytes: bounds.maxInputBytes)
        let document = MarkdownConverter.parse(capped)
        return make(from: document, bounds: bounds, inputTruncated: inputTruncated)
    }

    /// Reduce an already-parsed document to the bounded projection.
    public static func make(
        from document: QuoinDocument,
        bounds: PreviewBounds,
        inputTruncated: Bool = false
    ) -> BoundedPreviewDocument {
        var placeholderCounter = 0
        var reduced: [Block] = []
        reduced.reserveCapacity(min(document.blocks.count, bounds.maxBlocks))
        var blocksTruncated = false

        for block in document.blocks {
            if reduced.count >= bounds.maxBlocks {
                blocksTruncated = true
                break
            }
            reduced.append(reduce(block, bounds: bounds, counter: &placeholderCounter))
        }

        let footnotes: [Footnote]
        if bounds.includeFootnotes {
            footnotes = document.footnotes.map { footnote in
                Footnote(
                    id: footnote.id,
                    index: footnote.index,
                    blocks: footnote.blocks.map { reduce($0, bounds: bounds, counter: &placeholderCounter) })
            }
        } else {
            footnotes = []
        }

        let bounded = QuoinDocument(
            source: document.source,
            blocks: reduced,
            outline: document.outline,
            footnotes: footnotes,
            stats: document.stats,
            sourceHash: document.sourceHash,
            reviewMetadata: document.reviewMetadata)

        return BoundedPreviewDocument(
            document: bounded,
            blocksTruncated: blocksTruncated,
            inputTruncated: inputTruncated)
    }

    // MARK: - Source truncation

    /// Keeps at most `maxBytes` UTF-8 bytes of `source`, never splitting a
    /// multi-byte scalar (a split byte would decode to U+FFFD). Returns the
    /// (possibly identical) source and whether a cut happened.
    public static func truncatedSource(_ source: String, maxBytes: Int) -> (source: String, truncated: Bool) {
        let bytes = source.utf8
        guard bytes.count > maxBytes else { return (source, false) }
        // Back up off any UTF-8 continuation byte so the cut lands on a
        // scalar boundary.
        var cut = maxBytes
        let array = Array(bytes)
        while cut > 0 && (array[cut] & 0b1100_0000) == 0b1000_0000 {
            cut -= 1
        }
        return (String(decoding: array[..<cut], as: UTF8.self), true)
    }

    // MARK: - Block reduction

    private static func reduce(_ block: Block, bounds: PreviewBounds, counter: inout Int) -> Block {
        switch block.kind {
        case .diagram:
            return placeholder(PreviewPlaceholder.mermaid, like: block, counter: &counter)

        case .mathBlock(let latex):
            return placeholder(PreviewPlaceholder.math(latex), like: block, counter: &counter)

        case .heading(let level, let inlines, let slug):
            return Block(id: block.id,
                         kind: .heading(level: level, inlines: reduce(inlines), slug: slug),
                         range: block.range)

        case .paragraph(let inlines):
            return Block(id: block.id, kind: .paragraph(inlines: reduce(inlines)), range: block.range)

        case .codeBlock(let language, let code):
            return Block(id: block.id,
                         kind: .codeBlock(language: language, code: clip(code, lines: bounds.maxCodeLines)),
                         range: block.range)

        case .table(let header, let rows, let alignments):
            let cappedRows = Array(rows.prefix(bounds.maxRows)).map { row in
                row.map { TableCell(inlines: reduce($0.inlines)) }
            }
            let cappedHeader = header.map { TableCell(inlines: reduce($0.inlines)) }
            return Block(id: block.id,
                         kind: .table(header: cappedHeader, rows: cappedRows, alignments: alignments),
                         range: block.range)

        case .list(let items, let ordered, let start):
            let cappedItems = Array(items.prefix(bounds.maxRows)).map { item in
                ListItem(
                    blocks: item.blocks.map { reduce($0, bounds: bounds, counter: &counter) },
                    task: item.task,
                    taskMarkerRange: item.taskMarkerRange)
            }
            return Block(id: block.id,
                         kind: .list(items: cappedItems, ordered: ordered, start: start),
                         range: block.range)

        case .blockQuote(let children):
            return Block(id: block.id,
                         kind: .blockQuote(children: reduceContainer(children, bounds: bounds, counter: &counter)),
                         range: block.range)

        case .callout(let kind, let children):
            return Block(id: block.id,
                         kind: .callout(kind: kind, children: reduceContainer(children, bounds: bounds, counter: &counter)),
                         range: block.range)

        case .htmlBlock(let html):
            // Raw HTML is the one escape hatch that could reach the network:
            // a `<img src="https://tracker…">`, `<iframe>`, or remote
            // `<link rel=stylesheet>` would fire when Quick Look renders the
            // preview HTML in its own WebView — a tracking-pixel vector
            // directly contrary to the local-only guarantee. Neutralise it to
            // inert, escaped source text (a code block, clipped to the line
            // budget) so the preview shows WHAT the HTML is without ever
            // letting it fetch anything. (The HTML preview also carries a
            // restrictive CSP as a second layer; see QuickLookContent.)
            return Block(id: block.id,
                         kind: .codeBlock(language: nil, code: clip(html, lines: bounds.maxCodeLines)),
                         range: block.range)

        case .frontMatter, .reviewEndmatter, .tableOfContents, .thematicBreak:
            // Cheap to render as-is; no embedded layout to worry about, and
            // HTMLExporter escapes their contents (no raw HTML reaches output).
            return block
        }
    }

    /// Reduce a container's children, capping their count to `maxBlocks` too
    /// so a quote/callout stuffed with thousands of blocks can't blow the
    /// budget from the inside.
    private static func reduceContainer(_ children: [Block], bounds: PreviewBounds, counter: inout Int) -> [Block] {
        Array(children.prefix(bounds.maxBlocks)).map { reduce($0, bounds: bounds, counter: &counter) }
    }

    private static func placeholder(_ label: String, like block: Block, counter: inout Int) -> Block {
        counter += 1
        // A synthetic id keeps the placeholder distinct in the render's block
        // map. Passive (non-active) rendering reads only `kind`, so the
        // range is irrelevant here and is carried through for stability.
        let id = BlockID(contentHash: label.hashValue &+ counter, occurrence: counter)
        return Block(id: id, kind: .codeBlock(language: nil, code: label), range: block.range)
    }

    /// Clip a code block to at most `lines` lines, marking the cut. Normalises
    /// CRLF first — Swift treats `\r\n` as one grapheme, so a naive split
    /// would never break Windows-newline files.
    private static func clip(_ code: String, lines: Int) -> String {
        let normalized = code.replacingOccurrences(of: "\r\n", with: "\n")
        let split = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard split.count > lines else { return code }
        return split.prefix(lines).joined(separator: "\n") + "\n…"
    }

    // MARK: - Inline reduction

    /// Swap inline math for inline code (its LaTeX source, no typesetting) and
    /// images for a compact text placeholder, recursing through every inline
    /// container so nothing nested triggers layout or a file read.
    private static func reduce(_ inlines: [Inline]) -> [Inline] {
        inlines.map { reduce($0) }
    }

    private static func reduce(_ inline: Inline) -> Inline {
        switch inline {
        case .math(let latex):
            return .code(latex)
        case .image(_, let alt):
            return .text(PreviewPlaceholder.image(alt: alt))
        case .emphasis(let c):
            return .emphasis(reduce(c))
        case .strong(let c):
            return .strong(reduce(c))
        case .strikethrough(let c):
            return .strikethrough(reduce(c))
        case .highlight(let c, let color):
            return .highlight(reduce(c), color)
        case .link(let destination, let c):
            return .link(destination: destination, children: reduce(c))
        case .html(let raw):
            // Neutralise inline raw HTML too: emit it as inert text (escaped
            // downstream by HTMLExporter) rather than verbatim, so no inline
            // `<img>`/tag can reach a remote resource from the preview.
            return .text(raw)
        case .text, .code, .footnoteReference, .suggestion, .softBreak, .lineBreak:
            return inline
        }
    }
}
