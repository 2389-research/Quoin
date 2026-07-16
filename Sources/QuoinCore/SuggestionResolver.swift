import Foundation

/// Accept/reject for CriticMarkup marks (suggestions design, S2): each
/// resolution is ONE byte splice — computed from the mark's bytes AS THEY
/// ARE NOW (re-scanned from the current source, never trusted from a stale
/// projection), applied through the session's ordinary edit path so undo,
/// autosave, and stale-base protection come for free.
public enum SuggestionResolver {

    public enum Action: Sendable {
        case accept
        case reject
    }

    /// The splice that resolves the mark at `range`, or nil when the bytes
    /// there no longer parse as exactly one whole mark (the document changed
    /// since the projection was built — the caller surfaces "suggestion
    /// moved", never splices blind).
    ///
    /// Byte semantics (CriticMarkup consensus — exact bytes, no whitespace
    /// normalization; what's inside the delimiters is exactly what lands):
    /// accept insertion → body; reject → nothing; deletion inverse;
    /// substitution → chosen half; comment → removed either way (an
    /// annotation); highlight → unwrapped either way (MMD-6 behavior:
    /// the text was never in question, only flagged).
    public static func edit(
        resolving range: ByteRange, in source: String, action: Action
    ) -> SourceEdit? {
        let bytes = Array(source.utf8)
        guard range.offset >= 0, range.length > 0,
              range.offset + range.length <= bytes.count else { return nil }
        let slice = String(decoding: bytes[range.offset..<(range.offset + range.length)], as: UTF8.self)
        let segments = CriticScanner.scan(slice)
        guard segments.count == 1, case .mark(let mark) = segments[0],
              mark.range.offset == 0, mark.range.length == range.length else { return nil }

        let replacement: String
        switch (mark.payload, action) {
        case (.insertion(let body), .accept): replacement = body
        case (.insertion, .reject): replacement = ""
        case (.deletion, .accept): replacement = ""
        case (.deletion(let body), .reject): replacement = body
        case (.substitution(_, let new), .accept): replacement = new
        case (.substitution(let old, _), .reject): replacement = old
        case (.comment, _): replacement = ""
        case (.highlight(let body), _): replacement = body
        }
        return SourceEdit(range: range, replacement: replacement)
    }

    /// THE resolution edit: mark replacement AND the endmatter resolution
    /// record as ONE atomic splice (mark start → endmatter end, unchanged
    /// middle carried verbatim), so a single ⌘Z restores both. The two-edit
    /// version left a chimera after one undo: the mark back in the text
    /// with metadata still saying resolved — cards visible but actionless,
    /// counts wrong (live screenshot, 2026-07-14). Falls back to the
    /// mark-only edit when the mark has no {#id} or no endmatter entry.
    public static func combinedResolutionEdit(
        resolving markRange: ByteRange, in source: String, action: Action
    ) -> SourceEdit? {
        guard let markEdit = edit(resolving: markRange, in: source, action: action) else { return nil }
        guard let summary = resolutionSummary(at: markRange, in: source, action: action)
        else { return markEdit }
        // EVERY resolution is recorded ("the review tab goes away" redline):
        // a mark without a {#id} gets one synthesized, and a document
        // without endmatter grows one — history must not depend on the
        // author having used RDFM metadata.
        let isComment: Bool
        if case .comment = payload(at: markRange, in: source) { isComment = true }
        else { isComment = false }
        let recordEdit: SourceEdit?
        if let id = markID(at: markRange, in: source) {
            // A mark can carry an id its endmatter never declared — the
            // record is then APPENDED under that same id, never skipped
            // (panel review, MEDIUM).
            recordEdit = ReviewEndmatter.resolutionRecordEdit(
                resolving: id, summary: summary, in: source)
                ?? ReviewEndmatter.appendedRecordEdit(
                    summary: summary, asComment: isComment, reusing: id, in: source)
        } else {
            recordEdit = ReviewEndmatter.appendedRecordEdit(
                summary: summary, asComment: isComment, in: source)
        }
        guard let recordEdit,
              recordEdit.range.offset >= markRange.offset + markRange.length
        else { return markEdit }

        let bytes = Array(source.utf8)
        let middle = String(decoding: bytes[
            (markRange.offset + markRange.length)..<recordEdit.range.offset], as: UTF8.self)
        return SourceEdit(
            range: ByteRange(
                offset: markRange.offset,
                length: (recordEdit.range.offset + recordEdit.range.length) - markRange.offset),
            replacement: markEdit.replacement + middle + recordEdit.replacement)
    }

    /// The human-readable record a resolution writes into the endmatter
    /// (`resolved:`): what happened, to what text.
    public static func resolutionSummary(
        at range: ByteRange, in source: String, action: Action
    ) -> String? {
        let bytes = Array(source.utf8)
        guard range.offset >= 0, range.length > 0,
              range.offset + range.length <= bytes.count else { return nil }
        let slice = String(decoding: bytes[range.offset..<(range.offset + range.length)], as: UTF8.self)
        let segments = CriticScanner.scan(slice)
        guard segments.count == 1, case .mark(let mark) = segments[0] else { return nil }
        func clip(_ text: String) -> String {
            // One physical line, always: a raw newline in the summary would
            // split the quoted YAML scalar across lines — the strict parser
            // then rejects the WHOLE endmatter and it re-renders as prose
            // (panel review, HIGH). Marks can span soft line breaks, so
            // newlines here are a normal case, not an edge.
            let flattened = text
                .components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return flattened.count <= 60 ? flattened : String(flattened.prefix(59)) + "…"
        }
        switch (mark.payload, action) {
        case (.insertion(let body), .accept): return "accepted · \(clip(body))"
        case (.insertion(let body), .reject): return "rejected · \(clip(body))"
        case (.deletion(let body), .accept): return "accepted · removed \(clip(body))"
        case (.deletion(let body), .reject): return "rejected · kept \(clip(body))"
        case (.substitution(let old, let new), .accept): return "accepted · \(clip(old)) → \(clip(new))"
        case (.substitution(let old, let new), .reject): return "rejected · kept \(clip(old)) over \(clip(new))"
        case (.comment(let text), _): return "dismissed · \(clip(text))"
        case (.highlight(let body), _): return "resolved · \(clip(body))"
        }
    }

    static func payload(at range: ByteRange, in source: String) -> CriticMark.Payload? {
        let bytes = Array(source.utf8)
        guard range.offset >= 0, range.length > 0,
              range.offset + range.length <= bytes.count else { return nil }
        let slice = String(decoding: bytes[range.offset..<(range.offset + range.length)], as: UTF8.self)
        let segments = CriticScanner.scan(slice)
        guard segments.count == 1, case .mark(let mark) = segments[0] else { return nil }
        return mark.payload
    }

    /// The `{#id}` of the mark at `range`, when the bytes there parse as
    /// exactly one whole mark. Used to maintain the endmatter on resolution.
    public static func markID(at range: ByteRange, in source: String) -> String? {
        let bytes = Array(source.utf8)
        guard range.offset >= 0, range.length > 0,
              range.offset + range.length <= bytes.count else { return nil }
        let slice = String(decoding: bytes[range.offset..<(range.offset + range.length)], as: UTF8.self)
        let segments = CriticScanner.scan(slice)
        guard segments.count == 1, case .mark(let mark) = segments[0] else { return nil }
        return mark.id
    }

    /// Every unresolved mark in the document, in source order — the walk
    /// Accept All / Reject All and the review rail share.
    public static func marks(in document: QuoinDocument) -> [(kind: SuggestionKind, range: ByteRange, id: String?)] {
        var found: [(SuggestionKind, ByteRange, String?)] = []
        func walk(_ inlines: [Inline]) {
            for inline in inlines {
                switch inline {
                case .suggestion(let kind, let range, let id):
                    found.append((kind, range, id))
                case .emphasis(let c), .strong(let c), .strikethrough(let c), .highlight(let c, _):
                    walk(c)
                case .link(_, let c):
                    walk(c)
                default:
                    break
                }
            }
        }
        func walkBlocks(_ blocks: [Block]) {
            for block in blocks {
                switch block.kind {
                case .paragraph(let inlines), .heading(_, let inlines, _):
                    walk(inlines)
                case .blockQuote(let children), .callout(_, let children):
                    walkBlocks(children)
                case .list(let items, _, _):
                    for item in items { walkBlocks(item.blocks) }
                default:
                    break
                }
            }
        }
        walkBlocks(document.blocks)
        return found.sorted { $0.1.offset < $1.1.offset }
    }
}

// MARK: - Review items (the rail's data — suggestions design §3.5)

/// One review-rail card: a mark + its endmatter metadata + thread.
public struct ReviewItem: Hashable, Sendable {
    public enum Body: Hashable, Sendable {
        /// Comment text, with the anchor text when the comment directly
        /// follows a `{==highlight==}` (the RDFM anchored-comment form).
        case comment(text: String, anchor: String?)
        case insertion(String)
        case deletion(String)
        case substitution(old: String, new: String)
    }
    public struct Reply: Hashable, Sendable {
        public let by: String?
        public let at: String?
        public let body: String
    }
    public let body: Body
    /// The whole mark's absolute byte range (resolution splices this). For
    /// anchored comments this is the COMMENT mark's range; the anchor
    /// highlight resolves with it in S4 (v1 leaves the highlight in place).
    public let markRange: ByteRange
    public let id: String?
    public let by: String?
    public let at: String?
    public let replies: [Reply]
    public let isResolved: Bool

    /// True for suggestions (accept/reject); false for comments (dismiss).
    public var isSuggestion: Bool {
        switch body {
        case .comment: return false
        default: return true
        }
    }
}

extension SuggestionResolver {

    /// Composes the rail's cards from the document: marks + metadata +
    /// threads. Anchored comments absorb their preceding highlight (one
    /// card, not two); standalone highlights get no card (spec: not
    /// required to produce a review item — they stay inline-rendered).
    public static func reviewItems(in document: QuoinDocument) -> [ReviewItem] {
        let all = marks(in: document)
        let metadata = document.reviewMetadata
        var items: [ReviewItem] = []
        var pendingAnchor: (text: String, endOffset: Int)?

        // Kind-aware: on an id collision across sections, entry(for:)
        // prefers comments — attributing a suggestion card to the comment's
        // author (panel review). Look in the mark's OWN section first.
        func entry(_ id: String?, isSuggestion: Bool) -> ReviewEntry? {
            guard let id, let metadata else { return nil }
            return isSuggestion
                ? metadata.suggestions[id] ?? metadata.comments[id]
                : metadata.comments[id] ?? metadata.suggestions[id]
        }
        func replies(to id: String?) -> [ReviewItem.Reply] {
            guard let id, let metadata else { return [] }
            return metadata.comments
                .filter { $0.value.re == id && $0.value.body != nil }
                .sorted { ($0.value.at ?? $0.key) < ($1.value.at ?? $1.key) }
                .map { ReviewItem.Reply(by: $0.value.by, at: $0.value.at, body: $0.value.body ?? "") }
        }

        for mark in all {
            let isSuggestion: Bool
            switch mark.kind {
            case .insertion, .deletion, .substitution: isSuggestion = true
            case .comment, .highlight: isSuggestion = false
            }
            let meta = entry(mark.id, isSuggestion: isSuggestion)
            // MARK WINS: a live mark is actionable no matter what stale
            // metadata says (an undo or a hand edit can restore a mark
            // whose record still reads resolved — the mark's presence is
            // truth; its record is excluded from history until it resolves
            // again, see ReviewEndmatter.resolvedRecords).
            let resolved = false
            switch mark.kind {
            case .highlight(let children):
                // Hold; a directly-following comment claims it as anchor.
                pendingAnchor = (children.plainText, mark.range.offset + mark.range.length)
                continue
            case .comment(let text):
                let anchor: String?
                if let pending = pendingAnchor, pending.endOffset == mark.range.offset {
                    anchor = pending.text
                } else {
                    anchor = nil
                }
                items.append(ReviewItem(
                    body: .comment(text: text, anchor: anchor),
                    markRange: mark.range, id: mark.id,
                    by: meta?.by, at: meta?.at,
                    replies: replies(to: mark.id), isResolved: resolved))
            case .insertion(let children):
                items.append(ReviewItem(
                    body: .insertion(children.plainText),
                    markRange: mark.range, id: mark.id,
                    by: meta?.by, at: meta?.at,
                    replies: replies(to: mark.id), isResolved: resolved))
            case .deletion(let children):
                items.append(ReviewItem(
                    body: .deletion(children.plainText),
                    markRange: mark.range, id: mark.id,
                    by: meta?.by, at: meta?.at,
                    replies: replies(to: mark.id), isResolved: resolved))
            case .substitution(let old, let new):
                items.append(ReviewItem(
                    body: .substitution(old: old.plainText, new: new.plainText),
                    markRange: mark.range, id: mark.id,
                    by: meta?.by, at: meta?.at,
                    replies: replies(to: mark.id), isResolved: resolved))
            }
            pendingAnchor = nil
        }
        return items
    }
}

extension SuggestionResolver {

    /// Accept All / Reject All as ONE atomic edit (design §3.5: "one undo
    /// group"): sequentially resolves every insertion/deletion/substitution
    /// (comments and highlights are annotations — bulk actions leave them),
    /// re-scanning after each step, then collapses the whole outcome into a
    /// single SourceEdit from the first changed byte to EOF. One ⌘Z
    /// restores the entire batch.
    public static func resolveAllEdit(in source: String, action: Action) -> SourceEdit? {
        var current = source
        var iterations = 0
        while iterations < 10_000 {
            iterations += 1
            let document = MarkdownConverter.parse(current)
            let next = marks(in: document).first { mark in
                switch mark.kind {
                case .insertion, .deletion, .substitution: return true
                default: return false
                }
            }
            guard let next else { break }
            guard let edit = combinedResolutionEdit(
                resolving: next.range, in: current, action: action) else { break }
            var bytes = Array(current.utf8)
            bytes.replaceSubrange(
                edit.range.offset..<(edit.range.offset + edit.range.length),
                with: Array(edit.replacement.utf8))
            current = String(decoding: bytes, as: UTF8.self)
        }
        guard current != source else { return nil }

        // One spanning edit: first differing byte → EOF.
        let a = Array(source.utf8)
        let b = Array(current.utf8)
        var first = 0
        while first < min(a.count, b.count), a[first] == b[first] { first += 1 }
        return SourceEdit(
            range: ByteRange(offset: first, length: a.count - first),
            replacement: String(decoding: b[first...], as: UTF8.self))
    }
}
