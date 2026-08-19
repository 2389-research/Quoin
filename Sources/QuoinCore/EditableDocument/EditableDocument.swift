import Foundation

public struct EditableBlock: Sendable {
    public let id: NodeID
    public var kind: BlockKind
    /// The block's editable source text (its exact bytes when pristine).
    public var text: String
    /// The file byte range this block was parsed from; nil once it is born or
    /// re-homed in-editor.
    public var sourceSpan: Range<Int>?
    /// False once this block's text has been edited — a pristine block
    /// re-serializes verbatim from `text` (which still equals the source).
    public var pristine: Bool

    public init(id: NodeID, kind: BlockKind, text: String, sourceSpan: Range<Int>?, pristine: Bool) {
        self.id = id; self.kind = kind; self.text = text
        self.sourceSpan = sourceSpan; self.pristine = pristine
    }
}

public enum Segment: Sendable {
    case trivia(String)
    case block(EditableBlock)
}

public struct EditableDocument: Sendable {
    public var segments: [Segment]

    public init(segments: [Segment]) { self.segments = segments }

    public static func build(parsing source: String) -> EditableDocument {
        build(from: MarkdownConverter.parse(source))
    }

    /// The Phase 0 span decomposition, made mutable. Every byte of
    /// `doc.source` lands in exactly one segment: leading trivia, then each
    /// top-level block with the trivia that follows it.
    public static func build(from doc: QuoinDocument) -> EditableDocument {
        let source = doc.source
        // Work in UTF-8 byte space to match ByteRange; slice via a byte view.
        let bytes = Array(source.utf8)
        func slice(_ range: Range<Int>) -> String {
            String(decoding: bytes[range], as: UTF8.self)
        }
        let ordered = doc.blocks
            .map { $0.range }
            .sorted { $0.offset < $1.offset }
        var segments: [Segment] = []
        var cursor = 0
        for r in ordered {
            let start = r.offset
            let end = r.offset + r.length
            if start > cursor {
                segments.append(.trivia(slice(cursor..<start)))
            }
            let text = slice(start..<end)
            // Recover the kind by matching the block at this offset.
            let kind = doc.blocks.first { $0.range.offset == start }?.kind ?? .paragraph(inlines: [])
            segments.append(.block(EditableBlock(
                id: .fresh(), kind: kind, text: text, sourceSpan: start..<end, pristine: true)))
            cursor = end
        }
        if cursor < bytes.count {
            segments.append(.trivia(slice(cursor..<bytes.count)))
        }
        return EditableDocument(segments: segments)
    }
}
