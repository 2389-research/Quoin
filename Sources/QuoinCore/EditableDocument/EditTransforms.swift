import Foundation

public extension EditableDocument {
    /// Run `body` against the block with `id` in place. Returns nil if absent.
    @discardableResult
    mutating func withBlock<T>(_ id: NodeID, _ body: (inout EditableBlock) -> T) -> T? {
        for i in segments.indices {
            if case .block(var b) = segments[i], b.id == id {
                let result = body(&b)
                b.pristine = false          // any withBlock mutation dirties it
                segments[i] = .block(b)
                return result
            }
        }
        return nil
    }

    mutating func insertText(_ s: String, at pos: EditPosition) -> EditPosition {
        guard isValid(pos) else { return pos }
        withBlock(pos.block) { b in
            let ns = b.text as NSString
            b.text = ns.replacingCharacters(in: NSRange(location: pos.offsetUTF16, length: 0), with: s)
        }
        return EditPosition(block: pos.block, offsetUTF16: pos.offsetUTF16 + (s as NSString).length)
    }

    mutating func deleteRange(inBlock id: NodeID, _ range: Range<Int>) -> EditPosition {
        withBlock(id) { b in
            let ns = b.text as NSString
            guard range.lowerBound >= 0, range.upperBound <= ns.length else { return }
            b.text = ns.replacingCharacters(
                in: NSRange(location: range.lowerBound, length: range.count), with: "")
        }
        return EditPosition(block: id, offsetUTF16: range.lowerBound)
    }

    /// Return: split the caret's block into [before] and [after], inserting a
    /// canonical "\n\n" trivia between them. The new caret sits at offset 0 of
    /// the AFTER block. An end-of-block split leaves AFTER empty — a real empty
    /// paragraph node, not a virtual line.
    mutating func splitBlock(at pos: EditPosition) -> EditPosition {
        guard isValid(pos), let segIndex = blockIndex(of: pos.block),
              case .block(let original) = segments[segIndex] else { return pos }
        let ns = original.text as NSString
        let before = ns.substring(to: pos.offsetUTF16)
        let after = ns.substring(from: pos.offsetUTF16)

        var head = original
        head.text = before
        head.sourceSpan = nil          // edited: no longer a verbatim span
        head.pristine = false

        let tail = EditableBlock(
            id: .fresh(), kind: original.kind, text: after, sourceSpan: nil, pristine: false)

        segments.replaceSubrange(segIndex...segIndex, with: [
            .block(head), .trivia("\n\n"), .block(tail),
        ])
        return EditPosition(block: tail.id, offsetUTF16: 0)
    }
}
