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
}
