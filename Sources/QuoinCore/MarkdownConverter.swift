import Foundation
import Markdown
// Math parsing + macro expansion happen at parse time (unlike mermaid,
// which parses in QuoinRender), so this file uses VinculumLayout directly.
import VinculumLayout

/// Parses markdown source into an immutable `QuoinDocument`.
///
/// Pipeline: cmark-gfm (via swift-markdown) → `Block` tree with a UTF-8
/// source map → two post-passes folded into the walk: math extraction
/// (`$…$`, `$$…$$`, and ```math fences) and mermaid fence detection.
/// Outline and statistics are computed during the same walk.
public enum MarkdownConverter {

    public enum ParseStrategy: Equatable, Sendable {
        case full
        case plainParagraphFastPath
        /// Block-local re-parse of an edit inside a fenced embed block
        /// (code / mermaid / math). Typing in a chart's source used to
        /// re-parse the whole document on every keystroke.
        case fencedBlockFastPath
    }

    public struct IncrementalParseResult: Sendable {
        public let document: QuoinDocument
        public let inverse: SourceEdit
        public let strategy: ParseStrategy

        public init(document: QuoinDocument, inverse: SourceEdit, strategy: ParseStrategy) {
            self.document = document
            self.inverse = inverse
            self.strategy = strategy
        }
    }

    public static func parse(_ source: String) -> QuoinDocument {
        var watch = PhaseTrace.parseEnabled ? PhaseTrace.Stopwatch() : nil
        // YAML front matter is split off before cmark sees the source; all
        // ranges downstream are shifted back to absolute source offsets.
        var parseInput = source
        var baseOffset = 0
        var frontMatterYAML: String?
        if let front = InlinePostPasses.frontMatter(in: source) {
            frontMatterYAML = front.yaml
            baseOffset = front.byteLength
            parseInput = String(decoding: Array(source.utf8)[baseOffset...], as: UTF8.self)
        }
        // RDFM review endmatter is split off the TAIL the same way (the
        // last `\n---\n` whose YAML parses as review metadata AND is
        // referenced from the body — an ordinary trailing hrule never
        // matches). cmark never sees it; its block is appended after.
        var endmatter: ReviewEndmatter.Detected?
        if let detected = ReviewEndmatter.detect(in: parseInput) {
            endmatter = ReviewEndmatter.Detected(
                range: ByteRange(offset: baseOffset + detected.range.offset,
                                 length: detected.range.length),
                yaml: detected.yaml,
                metadata: detected.metadata)
            parseInput = String(
                decoding: Array(parseInput.utf8)[..<detected.range.offset],
                as: UTF8.self)
        }

        watch?.lap("frontmatter/endmatter")
        var builder = Builder(source: source, parseInput: parseInput, baseOffset: baseOffset)
        // Collect \newcommand/\def from every math segment first, so a
        // macro used before its definition still resolves (document scope).
        // Every definition begins with a backslash; a document without one
        // cannot define a macro, so skip the whole-source math scan for it
        // (macroTable already defaults to empty).
        if source.utf8.contains(0x5C) {
            builder.macroTable = MathMacros.collectDefinitions(from: source)
        }
        watch?.lap("macro scan")

        var blocks: [Block] = []
        if let frontMatterYAML {
            blocks.append(builder.makeBlock(
                kind: .frontMatter(yaml: frontMatterYAML),
                range: ByteRange(offset: 0, length: baseOffset)
            ))
        }
        // Standalone display-math spans are claimed from the raw source
        // BEFORE cmark: a setext-lookalike interior line (bare `=`, `---`)
        // would otherwise tear the span into paragraph + phantom heading +
        // orphan tail. The segments between spans parse independently —
        // safe because every claimed span is blank-line-separated from its
        // neighbors, exactly where cmark closes blocks anyway.
        let mathSpans = DisplayMathPrescan.spans(in: parseInput)
        watch?.lap("displaymath prescan")
        if mathSpans.isEmpty {
            let document = Markdown.Document(parsing: parseInput)
            watch?.lap("cmark parse")
            blocks.append(contentsOf: builder.convert(children: document.children))
            watch?.lap("tree walk")
        } else {
            let inputBytes = Array(parseInput.utf8)
            var cursor = 0
            for span in mathSpans {
                if span.range.offset > cursor {
                    let segment = String(decoding: inputBytes[cursor..<span.range.offset], as: UTF8.self)
                    blocks.append(contentsOf: builder.convert(segment: segment, at: baseOffset + cursor))
                }
                builder.stats.mathCount += 1
                blocks.append(builder.makeBlock(
                    kind: .mathBlock(latex: builder.expandMathBlock(span.latex)),
                    range: ByteRange(offset: baseOffset + span.range.offset, length: span.range.length)
                ))
                cursor = span.resumeOffset
            }
            if cursor < inputBytes.count {
                let segment = String(decoding: inputBytes[cursor...], as: UTF8.self)
                blocks.append(contentsOf: builder.convert(segment: segment, at: baseOffset + cursor))
            }
            watch?.lap("cmark+walk (math-segmented)")
        }
        if let endmatter {
            blocks.append(builder.makeBlock(
                kind: .reviewEndmatter(yaml: endmatter.yaml),
                range: endmatter.range
            ))
        }
        let footnotes = builder.gatherFootnotes()
        builder.finalizeStats()
        watch?.lap("footnotes/stats")
        let sourceHash = SHA256Hex.hash(of: source)
        watch?.lap("source hash")
        watch?.emit("parse.initial")
        return QuoinDocument(
            source: source,
            blocks: blocks,
            outline: builder.outline,
            footnotes: footnotes,
            stats: builder.stats,
            sourceHash: sourceHash,
            reviewMetadata: endmatter?.metadata
        )
    }

    public static func parseAfterEdit(previous: QuoinDocument, edit: SourceEdit) throws -> IncrementalParseResult {
        let (newSource, inverse) = try edit.apply(to: previous.source)
        if let fast = plainParagraphFastPath(previous: previous, edit: edit, newSource: newSource) {
            return IncrementalParseResult(document: fast, inverse: inverse, strategy: .plainParagraphFastPath)
        }
        if let fast = fencedBlockFastPath(previous: previous, edit: edit, newSource: newSource) {
            return IncrementalParseResult(document: fast, inverse: inverse, strategy: .fencedBlockFastPath)
        }
        return IncrementalParseResult(document: parse(newSource), inverse: inverse, strategy: .full)
    }

    /// Block-local re-parse for an edit inside a fenced embed block (code /
    /// mermaid / math) — the other thing a caret does all day. Typing inside
    /// a chart's revealed source used to fall through to a whole-document
    /// re-parse per keystroke, which is why editing a diagram in a long
    /// document felt sluggish while prose stayed snappy.
    ///
    /// Strategy: re-parse ONLY the block's source slice, before and after the
    /// edit, with the real parser. The old slice must reproduce the old block
    /// exactly (self-calibration — no duplicated fence rules here); the new
    /// slice must yield exactly one block of the same family whose relative
    /// range grew by exactly the edit's byte delta. Any early fence close,
    /// fence break, category flip, or structural surprise fails one of those
    /// checks and falls back to the full parse. Conservative rejections are
    /// always safe.
    private static func fencedBlockFastPath(
        previous: QuoinDocument,
        edit: SourceEdit,
        newSource: String
    ) -> QuoinDocument? {
        // suggestionCount counts every live critic mark: marks carry
        // ABSOLUTE byte ranges inside their inlines, which block-range
        // shifting can't reach — a fast-path edit before a mark left its
        // stored range (and content hash) stale, so panel actions hit the
        // drift refusal. Any live mark → full parse re-anchors them all.
        guard previous.stats.suggestionCount == 0,
              previous.footnotes.isEmpty,
              let blockIndex = previous.blocks.firstIndex(where: {
                  $0.range.offset <= edit.range.offset && edit.range.upperBound <= $0.range.upperBound
              })
        else { return nil }

        let block = previous.blocks[blockIndex]
        switch block.kind {
        case .codeBlock, .mermaid, .mathBlock: break
        default: return nil
        }
        guard let oldSlice = previous.source.substring(in: block.range) else { return nil }

        // The edit must stay strictly inside the content region: past the
        // opening fence line (so the info string can't change) and before the
        // closing fence line (so the terminator stays intact — an edit that
        // deletes the closer would make the fence swallow following blocks,
        // which a slice-local parse cannot see).
        let sliceBytes = Array(oldSlice.utf8)
        guard let firstNewline = sliceBytes.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        var lastLineStart = sliceBytes.count
        var i = sliceBytes.count - 1
        // Skip trailing newlines, then walk back to the closing line's start.
        while i >= 0, sliceBytes[i] == UInt8(ascii: "\n") { i -= 1 }
        while i >= 0, sliceBytes[i] != UInt8(ascii: "\n") { i -= 1 }
        lastLineStart = i + 1
        let relStart = edit.range.offset - block.range.offset
        let relEnd = edit.range.upperBound - block.range.offset
        guard relStart > firstNewline, relEnd <= lastLineStart else { return nil }

        // Self-calibrating slice parses: old must round-trip to the old
        // block; new must be one block of the same family, grown by delta.
        let relativeEdit = SourceEdit(
            range: ByteRange(offset: relStart, length: edit.range.length),
            replacement: edit.replacement
        )
        guard let (newSlice, _) = try? relativeEdit.apply(to: oldSlice) else { return nil }
        let oldParse = parse(oldSlice)
        guard oldParse.blocks.count == 1,
              oldParse.blocks[0].kind == block.kind
        else { return nil }
        let byteDelta = edit.replacement.utf8.count - edit.range.length
        let newParse = parse(newSlice)
        guard newParse.blocks.count == 1,
              sameEmbedFamily(newParse.blocks[0].kind, block.kind),
              newParse.blocks[0].range.offset == oldParse.blocks[0].range.offset,
              newParse.blocks[0].range.length == oldParse.blocks[0].range.length + byteDelta
        else { return nil }

        // Identity: same uniqueness rules as the paragraph fast path, so the
        // occurrence indices a full parse would assign are reproduced.
        let newKind = newParse.blocks[0].kind
        let newContentHash = contentHash(for: newKind)
        let oldContentHash = block.id.contentHash
        let oldHashCount = previous.blocks.filter { $0.id.contentHash == oldContentHash }.count
        let newHashAlreadyExists = previous.blocks.enumerated().contains { index, candidate in
            index != blockIndex && candidate.id.contentHash == newContentHash
        }
        guard oldHashCount == 1, !newHashAlreadyExists else { return nil }

        var blocks = previous.blocks
        blocks[blockIndex] = Block(
            id: BlockID(contentHash: newContentHash, occurrence: 0),
            kind: newKind,
            range: ByteRange(offset: block.range.offset, length: block.range.length + byteDelta)
        )
        shiftAndReassignIDs(&blocks, from: blockIndex, by: byteDelta)

        let shiftedOutline = previous.outline.map { heading in
            guard heading.range.offset > block.range.offset else { return heading }
            return HeadingInfo(
                id: heading.id,
                level: heading.level,
                title: heading.title,
                slug: heading.slug,
                range: ByteRange(offset: heading.range.offset + byteDelta, length: heading.range.length)
            )
        }

        var stats = previous.stats
        // Diff, not recount — same reasoning as the paragraph path.
        stats.characterCount += newSlice.count - oldSlice.count
        // Only code-block bodies feed the prose word count (mermaid and math
        // sources are diagrams, not words — see convertCodeBlock).
        if case .codeBlock(_, let oldCode) = block.kind,
           case .codeBlock(_, let newCode) = newKind {
            stats.wordCount += wordCount(in: newCode) - wordCount(in: oldCode)
        }

        return QuoinDocument(
            source: newSource,
            blocks: blocks,
            outline: shiftedOutline,
            stats: stats,
            sourceHash: SHA256Hex.hash(of: newSource),
            // The edit is strictly inside a fenced body — endmatter is
            // untouched, so its parsed metadata carries over verbatim
            // (dropping it made review history vanish per keystroke).
            reviewMetadata: previous.reviewMetadata
        )
    }

    /// True when both kinds belong to the same fenced-embed family, so an
    /// edit can't silently reclassify a block (mermaid → plain code, say)
    /// without the full parse seeing it.
    private static func sameEmbedFamily(_ a: BlockKind, _ b: BlockKind) -> Bool {
        switch (a, b) {
        case (.codeBlock(let la, _), .codeBlock(let lb, _)): return la == lb
        case (.mermaid, .mermaid): return true
        case (.mathBlock, .mathBlock): return true
        default: return false
        }
    }

    private static func plainParagraphFastPath(
        previous: QuoinDocument,
        edit: SourceEdit,
        newSource: String
    ) -> QuoinDocument? {
        guard previous.stats.suggestionCount == 0, // same staleness rule as the fenced path
              !edit.replacement.contains("\n"),
              previous.footnotes.isEmpty,
              let blockIndex = previous.blocks.firstIndex(where: {
                  $0.range.offset <= edit.range.offset && edit.range.upperBound <= $0.range.upperBound
              })
        else { return nil }

        let block = previous.blocks[blockIndex]
        guard case .paragraph(let oldInlines) = block.kind,
              oldInlines.allSatisfy({
                  switch $0 {
                  case .text, .softBreak:
                      return true
                  default:
                      return false
                  }
              }),
              let oldSlice = previous.source.substring(in: block.range)
        else { return nil }

        let relativeEdit = SourceEdit(
            range: ByteRange(offset: edit.range.offset - block.range.offset, length: edit.range.length),
            replacement: edit.replacement
        )
        guard let (newSlice, _) = try? relativeEdit.apply(to: oldSlice),
              isSafePlainParagraphSource(oldSlice),
              isSafePlainParagraphSource(newSlice)
        else { return nil }

        // Self-calibrating slice re-parse, never a hand-rolled imitation of
        // cmark: the parser applies smart punctuation (straight quotes come
        // out curly), so synthesizing inlines from the raw slice produced
        // documents that differed from a full parse wherever the paragraph
        // contained an apostrophe. Parse the slice with the real pipeline;
        // the old slice must reproduce the old block exactly, and the new
        // slice must stay one paragraph grown by exactly the edit's delta.
        let oldParse = parse(oldSlice)
        guard oldParse.blocks.count == 1, oldParse.blocks[0].kind == block.kind else { return nil }
        let sliceByteDelta = edit.replacement.utf8.count - edit.range.length
        let newParse = parse(newSlice)
        guard newParse.blocks.count == 1,
              case .paragraph = newParse.blocks[0].kind,
              newParse.blocks[0].range.offset == oldParse.blocks[0].range.offset,
              newParse.blocks[0].range.length == oldParse.blocks[0].range.length + sliceByteDelta
        else { return nil }

        let newKind = newParse.blocks[0].kind
        let newContentHash = contentHash(for: newKind)
        let oldContentHash = block.id.contentHash
        let oldHashCount = previous.blocks.filter { $0.id.contentHash == oldContentHash }.count
        let newHashAlreadyExists = previous.blocks.enumerated().contains { index, candidate in
            index != blockIndex && candidate.id.contentHash == newContentHash
        }
        guard oldHashCount == 1, !newHashAlreadyExists else { return nil }

        var blocks = previous.blocks
        blocks[blockIndex] = Block(
            id: BlockID(contentHash: newContentHash, occurrence: 0),
            kind: newKind,
            range: ByteRange(offset: block.range.offset, length: block.range.length + sliceByteDelta)
        )
        shiftAndReassignIDs(&blocks, from: blockIndex, by: sliceByteDelta)

        let shiftedOutline = previous.outline.map { heading in
            guard heading.range.offset > block.range.offset else { return heading }
            return HeadingInfo(
                id: heading.id,
                level: heading.level,
                title: heading.title,
                slug: heading.slug,
                range: ByteRange(offset: heading.range.offset + sliceByteDelta, length: heading.range.length)
            )
        }
        var stats = previous.stats
        // Diff, not recount: `newSource.count` walks every grapheme in the
        // document (tens of ms in a novel). The slice boundaries are
        // identical before and after, so the slice-count delta is exact.
        stats.characterCount += newSlice.count - oldSlice.count
        stats.wordCount += wordCount(in: newSlice) - wordCount(in: oldSlice)

        return QuoinDocument(
            source: newSource,
            blocks: blocks,
            outline: shiftedOutline,
            stats: stats,
            sourceHash: SHA256Hex.hash(of: newSource),
            // Same carry-over as the fenced path: the edited block is a
            // plain paragraph, never the endmatter.
            reviewMetadata: previous.reviewMetadata
        )
    }

    private static func contentHash(for kind: BlockKind) -> Int {
        var hasher = Hasher()
        hasher.combine(kind)
        return hasher.finalize()
    }

    private static func isSafePlainParagraphSource(_ source: String) -> Bool {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !source.contains("\n\n"), !source.contains("\r") else { return false }
        // Any character that could introduce inline structure or an
        // offset-carrying span forces the full parse: emphasis/code/link/
        // image markers (`*_`[]!`), block sigils (`#>|=`), math (`$`), HTML
        // (`<>&`), escapes (`\`), and CriticMarkup braces (`{}`). A slice
        // re-parse of any of these would stamp the new inline's range
        // SLICE-relative instead of document-absolute (panel review, HIGH).
        let forbidden = CharacterSet(charactersIn: "#>*_`[]!$=|<>&\\{}")
        guard source.rangeOfCharacter(from: forbidden) == nil else { return false }

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let leading = line.trimmingCharacters(in: .whitespaces)
            guard !leading.isEmpty else { return false }
            if leading.hasPrefix("- ") || leading.hasPrefix("+ ") || leading.hasPrefix("* ") { return false }
            if leading.hasPrefix("[TOC]") || leading.hasPrefix("[toc]") { return false }
            if leading.first?.isNumber == true,
               let marker = leading.firstIndex(where: { $0 == "." || $0 == ")" }),
               leading.index(after: marker) < leading.endIndex,
               leading[leading.index(after: marker)].isWhitespace {
                return false
            }
        }
        return true
    }

    private static func wordCount(in text: String) -> Int {
        WordCounting.count(in: text)
    }

    /// Shifts every block at `from+1`… by `delta` bytes AND re-derives block
    /// identities from `from` onward so the result is indistinguishable from
    /// a full parse.
    ///
    /// Two forces make plain range-shifting insufficient:
    /// - Container kinds (list / blockQuote / callout) embed their child
    ///   `Block`s — ranges included — so `BlockID.contentHash` (a hash of
    ///   the kind) CHANGES when a container merely moves. Keeping the old id
    ///   left stale identities on every container below the caret; a later
    ///   full parse would then assign different ids and defeat every
    ///   BlockID-keyed cache.
    /// - Occurrence numbering is global and assigned in the Builder's
    ///   makeBlock order (children before their container, document order
    ///   otherwise). Changing one block's hash can renumber a later
    ///   duplicate, so occurrences must be replayed, not preserved.
    ///
    /// The walk replays exactly that: counts are seeded from the untouched
    /// prefix (kinds unchanged there ⇒ existing hashes are the parser's),
    /// then every block from `from` onward gets its hash re-derived (only
    /// where the kind value actually changed) and its occurrence assigned
    /// in order.
    private static func shiftAndReassignIDs(_ blocks: inout [Block], from: Int, by delta: Int) {
        var seen: [Int: Int] = [:]
        for index in 0..<from {
            countInMakeOrder(blocks[index], into: &seen)
        }
        for index in from..<blocks.count {
            let shifted = index == from ? blocks[index] : shift(block: blocks[index], by: delta)
            blocks[index] = reassignIDs(shifted, seen: &seen)
        }
    }

    /// Replays the Builder's makeBlock counting order (children first) over
    /// an untouched block, using the existing ids' hashes.
    private static func countInMakeOrder(_ block: Block, into seen: inout [Int: Int]) {
        for child in childBlocks(of: block.kind) {
            countInMakeOrder(child, into: &seen)
        }
        seen[block.id.contentHash, default: 0] += 1
    }

    /// Re-derives ids for a (possibly shifted) block and its children in
    /// makeBlock order. Only container kinds embed ranges, so only they need
    /// a fresh hash; leaf kinds keep their content hash and just replay
    /// their occurrence.
    private static func reassignIDs(_ block: Block, seen: inout [Int: Int]) -> Block {
        let kind: BlockKind
        let hash: Int
        switch block.kind {
        case .list(let items, let ordered, let start):
            kind = .list(
                items: items.map { item in
                    ListItem(
                        blocks: item.blocks.map { reassignIDs($0, seen: &seen) },
                        task: item.task,
                        taskMarkerRange: item.taskMarkerRange
                    )
                },
                ordered: ordered, start: start
            )
            hash = contentHash(for: kind)
        case .blockQuote(let children):
            kind = .blockQuote(children: children.map { reassignIDs($0, seen: &seen) })
            hash = contentHash(for: kind)
        case .callout(let calloutKind, let children):
            kind = .callout(kind: calloutKind, children: children.map { reassignIDs($0, seen: &seen) })
            hash = contentHash(for: kind)
        default:
            kind = block.kind
            hash = block.id.contentHash
        }
        let occurrence = seen[hash, default: 0]
        seen[hash] = occurrence + 1
        return Block(id: BlockID(contentHash: hash, occurrence: occurrence), kind: kind, range: block.range)
    }

    /// A container kind's direct child blocks, in the Builder's makeBlock
    /// order (list items left to right).
    private static func childBlocks(of kind: BlockKind) -> [Block] {
        switch kind {
        case .list(let items, _, _): return items.flatMap(\.blocks)
        case .blockQuote(let children): return children
        case .callout(_, let children): return children
        default: return []
        }
    }

    private static func shift(block: Block, by delta: Int) -> Block {
        Block(
            id: block.id,
            kind: shift(kind: block.kind, by: delta),
            range: ByteRange(offset: block.range.offset + delta, length: block.range.length)
        )
    }

    private static func shift(kind: BlockKind, by delta: Int) -> BlockKind {
        switch kind {
        case .list(let items, let ordered, let start):
            return .list(
                items: items.map { item in
                    ListItem(
                        blocks: item.blocks.map { shift(block: $0, by: delta) },
                        task: item.task,
                        taskMarkerRange: item.taskMarkerRange.map {
                            ByteRange(offset: $0.offset + delta, length: $0.length)
                        }
                    )
                },
                ordered: ordered,
                start: start
            )
        case .blockQuote(let children):
            return .blockQuote(children: children.map { shift(block: $0, by: delta) })
        case .callout(let kind, let children):
            return .callout(kind: kind, children: children.map { shift(block: $0, by: delta) })
        default:
            return kind
        }
    }

    // MARK: - Builder

    private struct Builder {
        let source: String
        let sourceBytes: [UInt8]
        /// Line index of the segment currently being converted; rebound by
        /// `convert(segment:at:)` when display-math spans split the input.
        var lineIndex: LineIndex
        /// Byte offset of the current segment within the full source
        /// (nonzero when front matter was split off or a display-math span
        /// precedes the segment).
        var baseOffset: Int
        var slugger = Slugger()
        var outline: [HeadingInfo] = []
        var stats = DocumentStats()
        var occurrences: [Int: Int] = [:]
        var proseBuffer = ""
        var footnoteOrdinals: [String: Int] = [:]
        var footnoteDefinitions: [String: [Block]] = [:]
        /// Document-scoped math macros (`\newcommand`/`\def`), collected
        /// from the whole source before block conversion so a use resolves
        /// regardless of whether its definition came earlier or later.
        var macroTable = MathMacroTable()

        /// Expands math latex with the document's macros. A definition-ONLY
        /// block keeps its raw source so the renderer can show a "macros
        /// defined" chip instead of an empty box; everything else expands.
        func expandMathBlock(_ raw: String) -> String {
            MathMacros.isDefinitionOnly(raw, table: macroTable) ? raw : MathMacros.expand(raw, with: macroTable)
        }

        init(source: String, parseInput: String, baseOffset: Int) {
            self.source = source
            self.sourceBytes = Array(source.utf8)
            self.lineIndex = LineIndex(source: parseInput)
            self.baseOffset = baseOffset
        }

        /// Absolute byte range in the full source for a swift-markdown range
        /// (which is relative to the parsed remainder).
        func absoluteRange(of range: SourceRange?) -> ByteRange {
            let relative = lineIndex.byteRange(of: range)
            return ByteRange(offset: relative.offset + baseOffset, length: relative.length)
        }

        /// A heading's swift-markdown range ends at its trimmed content, so the
        /// trailing whitespace on the heading LINE (which the parser strips) is
        /// left unowned. That orphaned gap is where a space typed at the end of
        /// a heading used to land: the block never grew, the caret couldn't
        /// advance past its content, and repeated spaces piled up at one offset,
        /// corrupting the layout below. Extend the range to own that trailing
        /// whitespace (spaces/tabs up to — never including — the newline) so
        /// end-of-heading editing behaves. Scoped to headings on purpose:
        /// paragraphs use two trailing spaces as a hard line break.
        func extendingTrailingLineSpaces(_ range: ByteRange) -> ByteRange {
            var end = range.upperBound
            while end < sourceBytes.count,
                  sourceBytes[end] == UInt8(ascii: " ") || sourceBytes[end] == UInt8(ascii: "\t") {
                end += 1
            }
            return ByteRange(offset: range.offset, length: end - range.offset)
        }

        // MARK: Identity

        mutating func makeBlock(kind: BlockKind, range: ByteRange) -> Block {
            // One identity rule, shared with the fast paths' hash-uniqueness
            // gate — see `MarkdownConverter.contentHash(for:)`.
            let contentHash = MarkdownConverter.contentHash(for: kind)
            let occurrence = occurrences[contentHash, default: 0]
            occurrences[contentHash] = occurrence + 1
            return Block(id: BlockID(contentHash: contentHash, occurrence: occurrence), kind: kind, range: range)
        }

        // MARK: Block conversion

        /// Parses and converts one segment of the input (the text between
        /// display-math spans), with ranges shifted to absolute offsets.
        /// Builder state (slugger, outline, occurrences, stats, footnotes)
        /// carries across segments, so identity and numbering match what a
        /// single-pass parse of an unsplit document would assign.
        mutating func convert(segment: String, at offset: Int) -> [Block] {
            lineIndex = LineIndex(source: segment)
            baseOffset = offset
            let document = Markdown.Document(parsing: segment)
            return convert(children: document.children)
        }

        mutating func convert(children: MarkupChildren) -> [Block] {
            var blocks: [Block] = []
            for child in children {
                blocks.append(contentsOf: convert(markup: child))
            }
            return blocks
        }

        mutating func convert(markup: Markup) -> [Block] {
            let range = absoluteRange(of: markup.range)

            switch markup {
            case let heading as Markdown.Heading:
                return [convertHeading(heading, range: extendingTrailingLineSpaces(range))]

            case let paragraph as Markdown.Paragraph:
                return convertParagraph(paragraph, range: range)

            case let code as Markdown.CodeBlock:
                return [convertCodeBlock(code, range: range)]

            case let table as Markdown.Table:
                return [convertTable(table, range: range)]

            case let list as Markdown.UnorderedList:
                return [convertList(items: list.children, ordered: false, start: 1, range: range)]

            case let list as Markdown.OrderedList:
                return [convertList(items: list.children, ordered: true, start: Int(list.startIndex), range: range)]

            case let quote as Markdown.BlockQuote:
                let children = convert(children: quote.children)
                if let (kind, stripped) = calloutFrom(children) {
                    return [makeBlock(kind: .callout(kind: kind, children: stripped), range: range)]
                }
                return [makeBlock(kind: .blockQuote(children: children), range: range)]

            case is Markdown.ThematicBreak:
                return [makeBlock(kind: .thematicBreak, range: range)]

            case let html as Markdown.HTMLBlock:
                return [makeBlock(kind: .htmlBlock(html.rawHTML),
                                  range: repairedHTMLBlockRange(rawHTML: html.rawHTML, reported: range))]

            default:
                // Unknown block-level construct: preserve it as literal source
                // rather than dropping content on the floor.
                if let slice = source.substring(in: range), !slice.isEmpty {
                    return [makeBlock(kind: .paragraph(inlines: [.text(slice)]), range: range)]
                }
                return []
            }
        }

        /// cmark reports an HTML block's source range one LINE short when
        /// the block is closed by a terminator on its own line (a comment's
        /// `-->`): `rawHTML` carries the full content but the range stops at
        /// the previous line — so the block's "1:1" slice lost its closing
        /// marker (the reveal showed `<!--` but never `-->`, and the missing
        /// final line capped the revealed height). Anchor the range to
        /// rawHTML instead: when the source bytes at the block's offset
        /// literally spell the raw content, that length is the truth. Any
        /// byte mismatch keeps the reported range — never worse than cmark's.
        func repairedHTMLBlockRange(rawHTML: String, reported: ByteRange) -> ByteRange {
            // Block ranges exclude the trailing line terminator by
            // convention; cmark appends one to rawHTML even when the file
            // lacks it.
            var expected = rawHTML
            if expected.hasSuffix("\n") { expected.removeLast() }
            if expected.hasSuffix("\r") { expected.removeLast() }
            let length = expected.utf8.count
            guard length > reported.length,
                  source.substring(in: ByteRange(offset: reported.offset, length: length)) == expected
            else { return reported }
            return ByteRange(offset: reported.offset, length: length)
        }

        /// The shared inline post-pass chain: math, then highlights, then
        /// footnote references. Order matters — `==` inside math or `[^…]`
        /// inside code never reaches these because math/code are extracted
        /// first.
        mutating func postProcess(_ inlines: [Inline], math: Bool = true) -> [Inline] {
            var out = math ? spliceInlineMath(into: inlines) : inlines
            out = InlinePostPasses.spliceHighlights(into: out, stats: &stats)
            out = InlinePostPasses.spliceFootnoteReferences(into: out, ordinals: &footnoteOrdinals)
            return out
        }

        mutating func convertHeading(_ heading: Markdown.Heading, range: ByteRange) -> Block {
            let inlines = postProcess(convertInlines(heading.children))
            let title = inlines.plainText.trimmingCharacters(in: .whitespaces)
            let slug = slugger.slug(for: title)
            stats.headingCount += 1
            appendProse(title)
            let block = makeBlock(kind: .heading(level: heading.level, inlines: inlines, slug: slug), range: range)
            outline.append(HeadingInfo(id: block.id, level: heading.level, title: title, slug: slug, range: range))
            return block
        }

        mutating func convertParagraph(_ paragraph: Markdown.Paragraph, range: ByteRange) -> [Block] {
            let slice = source.substring(in: range)

            // `[TOC]` block: a paragraph that is exactly the marker.
            if let slice, slice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "[toc]" {
                return [makeBlock(kind: .tableOfContents, range: range)]
            }

            // Footnote definitions: `[^id]: content` — removed from the block
            // flow and gathered at document end. Consecutive definition lines
            // share ONE cmark paragraph, so the slice can hold several.
            if let slice {
                let definitions = parseFootnoteDefinitions(slice)
                if !definitions.isEmpty {
                    for definition in definitions {
                        let fragment = Markdown.Document(parsing: definition.content)
                        var blocks: [Block] = []
                        for child in fragment.children {
                            if let para = child as? Markdown.Paragraph {
                                let inlines = postProcess(convertInlines(para.children))
                                blocks.append(makeBlock(kind: .paragraph(inlines: inlines), range: range))
                            }
                        }
                        footnoteDefinitions[definition.id] = blocks
                    }
                    return []
                }
            }

            let inlines: [Inline]
            // Any `$` (even escaped) or a `\[` / `\(` LaTeX delimiter routes
            // through the raw-slice scanner: cmark unescapes `\$`→`$` and
            // `\[`→`[` in text nodes, so only the raw slice can tell a math
            // delimiter from an escaped literal.
            if let slice, CriticScanner.containsMark(slice), isSafeForSliceReparse(slice) {
                // CriticMarkup marks route through the raw slice for the same
                // reason math does (suggestions design §3): smart punctuation
                // en-dashes `{--` and GFM strikethrough consumes `{~~…~~}`
                // interiors before any post-pass could see them.
                inlines = postProcess(assembleCriticInlines(
                    from: CriticScanner.scan(slice), blockOffset: range.offset), math: false)
            } else if let slice,
               slice.contains("$") || slice.contains("\\[") || slice.contains("\\("),
               isSafeForSliceReparse(slice) {
                // The robust path: scan the raw source slice so that cmark's
                // emphasis parsing can't mangle `$a_b + c_d$`.
                let segments = MathScanner.scan(slice)
                if segments.count == 1, case .displayMath(let latex) = segments[0] {
                    stats.mathCount += 1
                    return [makeBlock(kind: .mathBlock(latex: expandMathBlock(latex)), range: range)]
                }
                inlines = postProcess(assembleInlines(from: segments), math: false)
            } else {
                inlines = postProcess(convertInlines(paragraph.children))
            }
            appendProse(inlines.plainText)
            stats.paragraphCount += 1
            return [makeBlock(kind: .paragraph(inlines: inlines), range: range)]
        }

        /// Parses `[^id]: content` at the start of a paragraph slice.
        func parseFootnoteDefinition(_ slice: String) -> (id: String, content: String)? {
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

        /// Every definition in a paragraph slice that OPENS with one:
        /// adjacent `[^id]:` lines share a single cmark paragraph, so each
        /// definition line starts a new entry and other lines continue the
        /// current one. Empty when the slice isn't a definition paragraph.
        func parseFootnoteDefinitions(_ slice: String) -> [(id: String, content: String)] {
            guard parseFootnoteDefinition(slice) != nil else { return [] }
            var definitions: [(id: String, content: String)] = []
            var current: (id: String, lines: [String])?
            // `\r\n` is one grapheme: split(separator: "\n") would keep CRLF
            // lines glued (line-walker rule).
            for line in slice.replacingOccurrences(of: "\r\n", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false) {
                if let next = parseFootnoteDefinition(String(line)) {
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

        /// Detects a design-spec callout: block quote whose first paragraph
        /// begins with `[!KIND]`. Returns the kind and children with the
        /// marker stripped.
        mutating func calloutFrom(_ children: [Block]) -> (CalloutKind, [Block])? {
            guard let first = children.first,
                  case .paragraph(var inlines) = first.kind,
                  case .text(let text) = inlines.first,
                  text.hasPrefix("[!"),
                  let close = text.firstIndex(of: "]"),
                  let kind = CalloutKind(marker: String(text[text.index(text.startIndex, offsetBy: 2)..<close]))
            else { return nil }

            let remainder = String(text[text.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
            if remainder.isEmpty {
                inlines.removeFirst()
            } else {
                inlines[0] = .text(remainder)
            }
            // Drop leading soft break left behind by `[!NOTE]\n`.
            if case .softBreak = inlines.first { inlines.removeFirst() }

            var stripped = children
            if inlines.isEmpty {
                stripped.removeFirst()
            } else {
                stripped[0] = makeBlock(kind: .paragraph(inlines: inlines), range: first.range)
            }
            return (kind, stripped)
        }

        /// Footnotes in reference order; referenced-but-undefined ids get a
        /// placeholder, defined-but-unreferenced ids are appended after.
        mutating func gatherFootnotes() -> [Footnote] {
            var footnotes: [Footnote] = []
            for (id, index) in footnoteOrdinals.sorted(by: { $0.value < $1.value }) {
                let blocks = footnoteDefinitions[id]
                    ?? [makeBlock(kind: .paragraph(inlines: [.text("Missing footnote: \(id)")]), range: ByteRange(offset: 0, length: 0))]
                footnotes.append(Footnote(id: id, index: index, blocks: blocks))
            }
            var nextIndex = footnoteOrdinals.count + 1
            for (id, blocks) in footnoteDefinitions.sorted(by: { $0.key < $1.key }) where footnoteOrdinals[id] == nil {
                footnotes.append(Footnote(id: id, index: nextIndex, blocks: blocks))
                nextIndex += 1
            }
            stats.footnoteCount = footnotes.count
            return footnotes
        }

        /// Slice re-parsing is only safe when the paragraph's raw lines are not
        /// decorated with container prefixes (`>` continuation inside block
        /// quotes) that would re-parse as different structure.
        func isSafeForSliceReparse(_ slice: String) -> Bool {
            guard slice.contains("\n") else { return true }
            for line in slice.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
                if line.drop(while: { $0 == " " || $0 == "\t" }).first == ">" { return false }
            }
            return true
        }

        /// Mid-paragraph boundary whitespace as inlines: spaces/tabs stay
        /// text, a newline is a soft break (exactly what cmark would have
        /// emitted had the segment not been re-parsed in isolation).
        func boundaryWhitespace(_ run: Substring) -> [Inline] {
            var result: [Inline] = []
            var spaces = ""
            for ch in run {
                if ch == "\n" {
                    if !spaces.isEmpty { result.append(.text(spaces)); spaces = "" }
                    result.append(.softBreak)
                } else {
                    spaces.append(ch)
                }
            }
            if !spaces.isEmpty { result.append(.text(spaces)) }
            return result
        }

        /// Turns critic-scanner segments into an inline list: text segments
        /// route through the math scanner + markdown re-parse exactly like an
        /// unmarked paragraph; each mark becomes an `Inline.suggestion` with
        /// its ABSOLUTE byte range (accept/reject in S2 splices those bytes)
        /// and markdown-parsed children (math inside mark bodies stays
        /// literal in v1 — documented limitation).
        mutating func assembleCriticInlines(
            from segments: [CriticScanner.Segment], blockOffset: Int
        ) -> [Inline] {
            var result: [Inline] = []
            for segment in segments {
                switch segment {
                case .text(let text):
                    result.append(contentsOf: assembleInlines(from: MathScanner.scan(text)))
                case .mark(let mark):
                    stats.suggestionCount += 1
                    let absolute = ByteRange(
                        offset: blockOffset + mark.range.offset, length: mark.range.length)
                    let kind: SuggestionKind
                    switch mark.payload {
                    case .insertion(let content):
                        kind = .insertion(assembleInlines(from: [.text(content)]))
                    case .deletion(let content):
                        kind = .deletion(assembleInlines(from: [.text(content)]))
                    case .substitution(let old, let new):
                        kind = .substitution(
                            old: assembleInlines(from: [.text(old)]),
                            new: assembleInlines(from: [.text(new)]))
                    case .comment(let text):
                        kind = .comment(text)
                    case .highlight(let content):
                        kind = .highlight(assembleInlines(from: [.text(content)]))
                    }
                    result.append(.suggestion(kind: kind, range: absolute, id: mark.id))
                }
            }
            return result
        }

        /// Turns math-scanner segments into an inline list, re-parsing text
        /// segments as inline markdown.
        mutating func assembleInlines(from segments: [MathSegment]) -> [Inline] {
            var result: [Inline] = []
            for segment in segments {
                switch segment {
                case .inlineMath(let latex), .displayMath(let latex):
                    stats.mathCount += 1
                    result.append(.math(latex: MathMacros.expand(latex, with: macroTable)))
                case .text(let text):
                    // cmark trims a fragment's leading/trailing whitespace,
                    // but these segments are MID-PARAGRAPH boundaries (text
                    // around a math span or a CriticMarkup mark) — dropping
                    // the spaces glued "a $x$ b" into "a$x$b" (and, live,
                    // "plain {++portable++} markdown" into
                    // "plainportablemarkdown"). Re-attach them.
                    result.append(contentsOf: boundaryWhitespace(text.prefix(
                        while: { $0 == " " || $0 == "\t" || $0 == "\n" })))
                    let fragment = Markdown.Document(parsing: text)
                    for child in fragment.children {
                        if let para = child as? Markdown.Paragraph {
                            result.append(contentsOf: convertInlines(para.children))
                        } else {
                            let plain = child.format()
                            if !plain.isEmpty { result.append(.text(plain)) }
                        }
                    }
                    let trailing = text.reversed().prefix(
                        while: { $0 == " " || $0 == "\t" || $0 == "\n" })
                    // Avoid double-counting a segment that is ALL whitespace.
                    if trailing.count < text.count {
                        result.append(contentsOf: boundaryWhitespace(String(trailing.reversed())[...]))
                    }
                }
            }
            return result
        }

        mutating func convertCodeBlock(_ code: Markdown.CodeBlock, range: ByteRange) -> Block {
            var body = code.code
            if body.hasSuffix("\n") { body.removeLast() }
            let language = code.language?.trimmingCharacters(in: .whitespaces).lowercased()

            switch language {
            case "mermaid":
                stats.diagramCount += 1
                return makeBlock(kind: .mermaid(source: body), range: range)
            case "math", "latex", "tex":
                stats.mathCount += 1
                return makeBlock(kind: .mathBlock(latex: expandMathBlock(body)), range: range)
            default:
                stats.codeBlockCount += 1
                appendProse(body)
                return makeBlock(kind: .codeBlock(language: code.language, code: body), range: range)
            }
        }

        mutating func convertTable(_ table: Markdown.Table, range: ByteRange) -> Block {
            let header = table.head.children.compactMap { $0 as? Markdown.Table.Cell }.map { convertCell($0) }
            var rows: [[TableCell]] = []
            for row in table.body.children {
                guard let row = row as? Markdown.Table.Row else { continue }
                rows.append(row.children.compactMap { $0 as? Markdown.Table.Cell }.map { convertCell($0) })
            }
            let alignments: [TableAlignment] = table.columnAlignments.map { alignment in
                switch alignment {
                case .left: return .left
                case .center: return .center
                case .right: return .right
                case nil: return .none
                }
            }
            stats.tableCount += 1
            return makeBlock(kind: .table(header: header, rows: rows, alignments: alignments), range: range)
        }

        mutating func convertCell(_ cell: Markdown.Table.Cell) -> TableCell {
            let inlines = postProcess(convertInlines(cell.children))
            appendProse(inlines.plainText)
            return TableCell(inlines: inlines)
        }

        mutating func convertList(items: MarkupChildren, ordered: Bool, start: Int, range: ByteRange) -> Block {
            var listItems: [ListItem] = []
            for item in items {
                guard let item = item as? Markdown.ListItem else { continue }
                let itemRange = absoluteRange(of: item.range)
                let blocks = convert(children: item.children)
                var task: TaskState?
                var markerRange: ByteRange?
                if let checkbox = item.checkbox {
                    task = checkbox == .checked ? .checked : .unchecked
                    markerRange = locateTaskMarker(in: itemRange)
                    stats.taskTotal += 1
                    if task == .checked { stats.taskDone += 1 }
                }
                listItems.append(ListItem(blocks: blocks, task: task, taskMarkerRange: markerRange))
            }
            return makeBlock(kind: .list(items: listItems, ordered: ordered, start: start), range: range)
        }

        /// Finds the exact byte range of the `[ ]`/`[x]` marker inside a task
        /// list item: skip the bullet or ordinal, skip whitespace, expect the
        /// three-byte marker. Returns nil if the source doesn't match, in
        /// which case write-back is refused rather than risked.
        func locateTaskMarker(in itemRange: ByteRange) -> ByteRange? {
            var i = itemRange.offset
            let end = min(itemRange.upperBound, sourceBytes.count)
            // Leading indentation.
            while i < end, sourceBytes[i] == UInt8(ascii: " ") || sourceBytes[i] == UInt8(ascii: "\t") { i += 1 }
            // Bullet (- + *) or ordinal (digits followed by . or )).
            if i < end, [UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "*")].contains(sourceBytes[i]) {
                i += 1
            } else {
                var j = i
                while j < end, sourceBytes[j] >= UInt8(ascii: "0"), sourceBytes[j] <= UInt8(ascii: "9") { j += 1 }
                guard j > i, j < end, sourceBytes[j] == UInt8(ascii: ".") || sourceBytes[j] == UInt8(ascii: ")") else { return nil }
                i = j + 1
            }
            // Whitespace between marker and checkbox.
            while i < end, sourceBytes[i] == UInt8(ascii: " ") || sourceBytes[i] == UInt8(ascii: "\t") { i += 1 }
            // The `[x]` marker itself.
            guard i + 2 < end,
                  sourceBytes[i] == UInt8(ascii: "["),
                  sourceBytes[i + 2] == UInt8(ascii: "]"),
                  [UInt8(ascii: " "), UInt8(ascii: "x"), UInt8(ascii: "X")].contains(sourceBytes[i + 1])
            else { return nil }
            return ByteRange(offset: i, length: 3)
        }

        // MARK: Inline conversion

        mutating func convertInlines(_ children: MarkupChildren) -> [Inline] {
            var result: [Inline] = []
            for child in children {
                if let inline = convertInline(child) {
                    result.append(inline)
                }
            }
            return result
        }

        mutating func convertInline(_ markup: Markup) -> Inline? {
            switch markup {
            case let text as Markdown.Text:
                return .text(text.string)
            case let code as Markdown.InlineCode:
                return .code(code.code)
            case let emphasis as Markdown.Emphasis:
                return .emphasis(convertInlines(emphasis.children))
            case let strong as Markdown.Strong:
                return .strong(convertInlines(strong.children))
            case let strike as Markdown.Strikethrough:
                return .strikethrough(convertInlines(strike.children))
            case let link as Markdown.Link:
                stats.linkCount += 1
                return .link(destination: link.destination, children: convertInlines(link.children))
            case let image as Markdown.Image:
                stats.imageCount += 1
                let alt = image.children.compactMap { ($0 as? Markdown.Text)?.string }.joined()
                return .image(source: image.source, alt: alt)
            case is Markdown.SoftBreak:
                return .softBreak
            case is Markdown.LineBreak:
                return .lineBreak
            case let html as Markdown.InlineHTML:
                return .html(html.rawHTML)
            default:
                // Preserve anything unrecognized as its plain text.
                let text = markup.format()
                return text.isEmpty ? nil : .text(text)
            }
        }

        /// The fallback math pass for contexts that can't use slice re-parsing
        /// (headings, table cells, block-quoted paragraphs): scans individual
        /// text runs for `$…$` spans.
        mutating func spliceInlineMath(into inlines: [Inline]) -> [Inline] {
            var result: [Inline] = []
            for inline in inlines {
                guard case .text(let text) = inline, MathScanner.containsMathDelimiter(text) else {
                    result.append(inline)
                    continue
                }
                for segment in MathScanner.scan(text) {
                    switch segment {
                    case .text(let t):
                        result.append(.text(t))
                    case .inlineMath(let latex), .displayMath(let latex):
                        stats.mathCount += 1
                        result.append(.math(latex: MathMacros.expand(latex, with: macroTable)))
                    }
                }
            }
            return result
        }

        // MARK: Stats

        mutating func appendProse(_ text: String) {
            guard !text.isEmpty else { return }
            proseBuffer.append(text)
            proseBuffer.append("\n")
        }

        mutating func finalizeStats() {
            stats.characterCount = source.count
            stats.wordCount = WordCounting.count(in: proseBuffer)
        }
    }
}
