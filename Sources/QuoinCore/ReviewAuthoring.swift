import Foundation

// MARK: - Creating a review (suggestions design §3.6, S3a)

/// Builds the ONE atomic annotation edit behind every S3a selection
/// gesture: the CriticMarkup mark wrapped around the selection's bytes
/// PLUS the endmatter entry (`by:`/`at:`), as a single spanning splice —
/// one ⌘Z removes the whole annotation, exactly the inverse of
/// `combinedResolutionEdit`.
///
/// A review never changes the prose: every kind here wraps or annotates
/// the selected bytes verbatim; only RESOLVING a suggestion changes what
/// the document says.
///
/// Validation is SELF-CALIBRATION (the incremental fast paths'
/// philosophy): the candidate source is parsed and the edit is returned
/// only when exactly the expected mark comes back at the expected offset
/// carrying the allocated id. That one rule subsumes the constraint list —
/// code/math opacity (a mark born inside a code span parses as literal →
/// refused), block-spanning selections (unbalanced per-slice → refused),
/// and sigil collisions in the selection (early close detaches the id →
/// refused). Conservative rejections are always safe: the caller beeps or
/// disables the gesture.
public enum ReviewAuthoring {

    public enum Kind: Equatable, Sendable {
        /// `{==sel==}{>>body<<}{#cN}` — the anchored-comment shape the
        /// panel renders as one card. With an EMPTY range: a document-level
        /// comment (endmatter-only entry with `body:`; no inline mark).
        case comment(body: String)
        /// `{~~sel~>new~~}{#sN}`
        case replacement(new: String)
        /// `{--sel--}{#sN}`
        case deletion
        /// `{==sel==}{#sN}`
        case highlight
        /// `{++text++}{#sN}` at a caret (range length 0).
        case insertion(text: String)
        /// A standalone `{>>body<<}{#cN}` paragraph inserted AFTER the
        /// block at `range` — how code blocks, tables, diagrams, and math
        /// get commented (#68): marks cannot live INSIDE opaque content
        /// (RDFM opacity is normative), so the comment sits beside it,
        /// fully portable. `range` is the whole block; its bytes are the
        /// drift check.
        case blockComment(body: String)
    }

    /// The combined mark + endmatter-entry edit, or nil when the
    /// annotation cannot be represented faithfully at that range.
    /// `timestamp` is threaded as a parameter (the session stamps it at
    /// apply time) so this stays a pure, testable function.
    public static func annotationEdit(
        kind: Kind, range: ByteRange, in source: String,
        reviewer: String, timestamp: String
    ) -> SourceEdit? {
        let bytes = Array(source.utf8)
        guard range.offset >= 0, range.length >= 0,
              range.offset + range.length <= bytes.count else { return nil }
        let slice = String(decoding: bytes[range.offset..<(range.offset + range.length)], as: UTF8.self)

        // Field lines shared by every entry this file writes.
        func entryFields(body: String? = nil) -> [String] {
            var fields = [
                "by: \(ReviewEndmatter.fieldValue(reviewer))",
                "at: \"\(ReviewEndmatter.escapedScalar(timestamp))\"",
            ]
            if let body {
                fields.append("body: \"\(ReviewEndmatter.escapedScalar(body))\"")
            }
            return fields
        }

        // Document-level comment: no selection, no mark — pure endmatter.
        if case .comment(let body) = kind, range.length == 0 {
            let flattened = flattenedInline(body)
            guard !flattened.isEmpty else { return nil }
            return ReviewEndmatter.appendedEntryEdit(
                fieldLines: entryFields(body: flattened),
                asComment: true, reusing: nil, in: source)?.edit
        }

        // Block comment: nothing is wrapped — a fresh paragraph lands
        // after the block, plus the endmatter entry, as ONE spanning edit.
        if case .blockComment(let body) = kind {
            return blockCommentEdit(
                body: body, afterBlock: range, in: source,
                fields: entryFields(), bytes: bytes)
        }

        // Inline marks require a real selection (insertion: a caret).
        switch kind {
        case .insertion: guard range.length == 0 else { return nil }
        default: guard range.length > 0 else { return nil }
        }

        let asComment: Bool
        if case .comment = kind { asComment = true } else { asComment = false }
        let id = ReviewEndmatter.allocateID(asComment: asComment, in: source)

        let markText: String
        switch kind {
        case .comment(let body):
            let flattened = flattenedInline(body)
            guard !flattened.isEmpty else { return nil }
            markText = "{==\(slice)==}{>>\(flattened)<<}{#\(id)}"
        case .replacement(let new):
            // The new half inherits the styling delimiters the selection
            // snap pulled into the old half: replacing rendered "bold"
            // (source **bold**) with "strong" must suggest **strong**,
            // not strip the emphasis (live report, 2026-07-15).
            let preserved = replacementPreservingDelimiters(
                flattenedInline(new), around: slice)
            markText = "{~~\(slice)~>\(preserved)~~}{#\(id)}"
        case .deletion:
            markText = "{--\(slice)--}{#\(id)}"
        case .highlight:
            markText = "{==\(slice)==}{#\(id)}"
        case .insertion(let text):
            let flattened = flattenedInline(text)
            guard !flattened.isEmpty else { return nil }
            markText = "{++\(flattened)++}{#\(id)}"
        case .blockComment:
            return nil // handled above
        }

        guard let (entryEdit, _) = ReviewEndmatter.appendedEntryEdit(
            fieldLines: entryFields(),
            asComment: asComment, reusing: id, in: source),
            // The entry lands AFTER the mark (endmatter is at EOF); a
            // selection inside the endmatter itself can't be annotated.
            entryEdit.range.offset >= range.offset + range.length
        else { return nil }

        // ONE spanning splice: mark + unchanged middle + endmatter entry.
        let middle = String(decoding: bytes[
            (range.offset + range.length)..<entryEdit.range.offset], as: UTF8.self)
        let combined = SourceEdit(
            range: ByteRange(
                offset: range.offset,
                length: (entryEdit.range.offset + entryEdit.range.length) - range.offset),
            replacement: markText + middle + entryEdit.replacement)

        // Self-calibration: the candidate must parse back to a mark
        // carrying OUR id whose range starts exactly at the selection.
        var candidateBytes = bytes
        candidateBytes.replaceSubrange(
            combined.range.offset..<(combined.range.offset + combined.range.length),
            with: Array(combined.replacement.utf8))
        let candidate = String(decoding: candidateBytes, as: UTF8.self)
        let beforeMarks = SuggestionResolver.marks(in: MarkdownConverter.parse(source))
        let afterMarks = SuggestionResolver.marks(in: MarkdownConverter.parse(candidate))
        let expectedStart = range.offset
        let expectedEnd = range.offset + markText.utf8.count
        guard afterMarks.contains(where: { mark in
            mark.id == id
                && mark.range.offset >= expectedStart
                && mark.range.offset + mark.range.length == expectedEnd
        }) else { return nil }
        // …and it must not CONSUME any existing mark: wrapping a mark in a
        // highlight parses "cleanly" while silently turning the inner mark
        // into literal payload and orphaning its metadata. Every mark that
        // existed before must survive, plus exactly ours. (The anchored
        // comment counts as two: its highlight + its comment.)
        let added = { if case .comment = kind { return 2 } else { return 1 } }()
        let beforeIDs = Set(beforeMarks.compactMap(\.id))
        let afterIDs = Set(afterMarks.compactMap(\.id))
        guard afterMarks.count == beforeMarks.count + added,
              beforeIDs.subtracting(afterIDs).isEmpty else { return nil }
        // …and the document's STRUCTURE must survive: wrapping a list
        // item's marker in `{==` erased the marker, restructured the list,
        // and renumbered everything — an annotation that changes what the
        // document IS, not just what it says (live report, 2026-07-15).
        let beforeDoc = MarkdownConverter.parse(source)
        let afterDoc = MarkdownConverter.parse(candidate)
        guard structuralSignature(beforeDoc) == structuralSignature(afterDoc) else { return nil }

        return combined
    }

    /// The #68 edit: `\n\n{>>body<<}{#cN}` inserted at the block's end +
    /// the endmatter entry, one atomic splice. Self-calibration: the
    /// comment mark must come back carrying our id, every prior mark must
    /// survive, and the document must gain exactly one paragraph.
    private static func blockCommentEdit(
        body: String, afterBlock range: ByteRange, in source: String,
        fields: [String], bytes: [UInt8]
    ) -> SourceEdit? {
        let flattened = flattenedInline(body)
        guard !flattened.isEmpty, range.length > 0 else { return nil }
        let id = ReviewEndmatter.allocateID(asComment: true, in: source)
        let markText = "{>>\(flattened)<<}{#\(id)}"
        let insertion = "\n\n" + markText
        let insertAt = range.offset + range.length

        guard let (entryEdit, _) = ReviewEndmatter.appendedEntryEdit(
            fieldLines: fields, asComment: true, reusing: id, in: source),
            entryEdit.range.offset >= insertAt
        else { return nil }
        let middle = String(decoding: bytes[insertAt..<entryEdit.range.offset], as: UTF8.self)
        let combined = SourceEdit(
            range: ByteRange(
                offset: insertAt,
                length: (entryEdit.range.offset + entryEdit.range.length) - insertAt),
            replacement: insertion + middle + entryEdit.replacement)

        var candidateBytes = bytes
        candidateBytes.replaceSubrange(
            combined.range.offset..<(combined.range.offset + combined.range.length),
            with: Array(combined.replacement.utf8))
        let candidate = String(decoding: candidateBytes, as: UTF8.self)
        let beforeDoc = MarkdownConverter.parse(source)
        let afterDoc = MarkdownConverter.parse(candidate)
        let beforeMarks = SuggestionResolver.marks(in: beforeDoc)
        let afterMarks = SuggestionResolver.marks(in: afterDoc)
        guard afterMarks.contains(where: { $0.id == id }),
              afterMarks.count == beforeMarks.count + 1,
              Set(beforeMarks.compactMap(\.id))
                .subtracting(Set(afterMarks.compactMap(\.id))).isEmpty
        else { return nil }
        // Exactly one new paragraph, everything else structurally intact.
        let expected = structuralSignature(beforeDoc)
        let got = structuralSignature(afterDoc)
        guard firstInsertedParagraph(expected: expected, got: got) != nil else { return nil }
        return combined
    }

    /// Index of the single inserted "p" in `got`, or nil when the diff is
    /// not exactly one inserted paragraph.
    private static func firstInsertedParagraph(expected: [String], got: [String]) -> Int? {
        guard got.count == expected.count + 1 else { return nil }
        var i = 0
        while i < expected.count, expected[i] == got[i] { i += 1 }
        guard i < got.count, got[i] == "p" else { return nil }
        guard Array(got[(i + 1)...]) == Array(expected[i...]) else { return nil }
        return i
    }

    /// Block-level shape of a document — kinds and container arity, ignoring
    /// inline content (which the annotation legitimately changes) and any
    /// trailing endmatter (which the annotation legitimately creates).
    private static func structuralSignature(_ document: QuoinDocument) -> [String] {
        func shape(_ block: Block) -> String {
            switch block.kind {
            case .paragraph: return "p"
            case .heading(let level, _, _): return "h\(level)"
            case .list(let items, let ordered, _):
                return "list(\(items.count),\(ordered),[\(items.map { $0.blocks.map(shape).joined() }.joined(separator: "|"))])"
            case .blockQuote(let children): return "q[\(children.map(shape).joined())]"
            case .callout(_, let children): return "callout[\(children.map(shape).joined())]"
            case .codeBlock: return "code"
            case .mermaid: return "mermaid"
            case .mathBlock: return "math"
            case .table(_, let rows, _): return "table(\(rows.count))"
            case .frontMatter: return "front"
            case .reviewEndmatter: return "endmatter"
            case .tableOfContents: return "toc"
            case .thematicBreak: return "hr"
            case .htmlBlock: return "html"
            }
        }
        var shapes = document.blocks.map(shape)
        if shapes.last == "endmatter" { shapes.removeLast() }
        return shapes
    }

    /// When a selection starts inside a line's STRUCTURAL prefix (list
    /// marker, task checkbox, quote `>`), annotating from there would erase
    /// the structure. Returns the first CONTENT offset at or after
    /// `position` on its line — a whole-item selection annotates the item's
    /// text, marker excluded. UTF-16 offsets (the projection mapper's
    /// currency).
    public static func clampPastLinePrefix(_ position: Int, in slice: String) -> Int {
        let chars = Array(slice.utf16)
        guard position >= 0, position <= chars.count else { return position }
        let newline = UInt16(UnicodeScalar("\n").value)
        var lineStart = position
        while lineStart > 0, chars[lineStart - 1] != newline { lineStart -= 1 }

        var i = lineStart
        func skip(_ scalar: Unicode.Scalar) -> Bool {
            guard i < chars.count, chars[i] == UInt16(scalar.value) else { return false }
            i += 1
            return true
        }
        func skipSpaces() { while i < chars.count, chars[i] == UInt16(UnicodeScalar(" ").value) || chars[i] == UInt16(UnicodeScalar("\t").value) { i += 1 } }

        skipSpaces()
        // Quote prefixes, possibly stacked: `> > `
        while skip(">") { skipSpaces() }
        // List marker: -/*/+ or digits + ./) — must be followed by a space.
        let checkpoint = i
        if skip("-") || skip("*") || skip("+") {
            if !skip(" ") { i = checkpoint }
        } else {
            var digits = 0
            while i < chars.count, chars[i] >= UInt16(UnicodeScalar("0").value),
                  chars[i] <= UInt16(UnicodeScalar("9").value) { i += 1; digits += 1 }
            if digits > 0, digits <= 9, skip(".") || skip(")") {
                if !skip(" ") { i = checkpoint }
            } else {
                i = checkpoint
            }
        }
        skipSpaces()
        // Task checkbox: `[ ] ` / `[x] `
        if i + 3 <= chars.count, chars[i] == UInt16(UnicodeScalar("[").value),
           i + 2 < chars.count, chars[i + 2] == UInt16(UnicodeScalar("]").value) {
            i += 3
            skipSpaces()
        }
        return max(position, min(i, chars.count))
    }

    /// Outward snap over emphasis delimiter runs (`*_~=`) so a rendered
    /// whole-span selection wraps complete syntax. Backticks are
    /// deliberately excluded — swallowing one edge of a code span would
    /// unbalance it. The snap only stands when it captures a BALANCED wrap
    /// (leading delimiter run == trailing run, the same rule
    /// `replacementPreservingDelimiters` transfers by): a selection at a
    /// span's EDGE would otherwise pull in one `**` while the other stays
    /// outside the mark — accepting then deletes half the pair and leaves
    /// literal asterisks (live report, 2026-07-09). Lopsided captures
    /// revert BOTH endpoints to the positions given. UTF-16 offsets (the
    /// projection mapper's currency).
    public static func balancedDelimiterSnap(
        start: Int, end: Int, in slice: String
    ) -> (start: Int, end: Int) {
        let chars = Array(slice.utf16)
        guard start >= 0, start <= end, end <= chars.count else { return (start, end) }
        let snapSet: Set<UInt16> = Set("*_~=".utf16)
        var snappedStart = start
        var snappedEnd = end
        while snappedStart > 0, snapSet.contains(chars[snappedStart - 1]) { snappedStart -= 1 }
        while snappedEnd < chars.count, snapSet.contains(chars[snappedEnd]) { snappedEnd += 1 }
        guard snappedStart < start || snappedEnd > end else { return (start, end) }

        // Delimiter runs of the SNAPPED slice (what annotationEdit will
        // see): equal runs with real content between = a complete wrap.
        var contentStart = snappedStart
        while contentStart < snappedEnd, snapSet.contains(chars[contentStart]) { contentStart += 1 }
        var contentEnd = snappedEnd
        while contentEnd > contentStart, snapSet.contains(chars[contentEnd - 1]) { contentEnd -= 1 }
        guard contentStart < contentEnd,
              Array(chars[snappedStart..<contentStart]) == Array(chars[contentEnd..<snappedEnd])
        else { return (start, end) }
        return (snappedStart, snappedEnd)
    }

    /// When the OLD half is delimiter-wrapped (`**bold**`), the NEW half
    /// wraps in the same delimiters — accepting must keep the styling.
    /// Only symmetric wraps transfer (leading run == trailing run); a
    /// lopsided snap passes the text through untouched, and the
    /// self-calibration still owns final say.
    static func replacementPreservingDelimiters(
        _ new: String, around snappedSlice: String
    ) -> String {
        let delimiters: Set<Character> = ["*", "_", "~", "="]
        let leading = String(snappedSlice.prefix(while: { delimiters.contains($0) }))
        let trailing = String(snappedSlice.reversed().prefix(while: { delimiters.contains($0) }).reversed())
        guard !leading.isEmpty, leading == trailing,
              leading.count + trailing.count < snappedSlice.count,
              !new.hasPrefix(leading) || !new.hasSuffix(trailing)
        else { return new }
        return leading + new + trailing
    }

    /// Mark bodies live INSIDE an inline span: line breaks would change
    /// block structure (a blank line splits the paragraph mid-mark), so
    /// popover input flattens to one line — same rule as the resolution
    /// summaries.
    private static func flattenedInline(_ text: String) -> String {
        // Single-line input passes through UNTOUCHED (an insertion's
        // trailing space is meaningful: "{++really ++}"); only real line
        // breaks flatten. Whitespace-only input becomes empty (refused by
        // the callers).
        guard text.contains(where: \.isNewline) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
        }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
