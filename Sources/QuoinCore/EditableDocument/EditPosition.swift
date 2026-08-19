import Foundation

/// A caret as a STRUCTURAL position — a block identity plus a UTF-16 offset
/// within that block's text. It cannot desync from bytes the way a document
/// byte offset can, because it names the block directly.
public struct EditPosition: Hashable, Sendable {
    public let block: NodeID
    public let offsetUTF16: Int
    public init(block: NodeID, offsetUTF16: Int) {
        self.block = block; self.offsetUTF16 = offsetUTF16
    }
}

public extension EditableDocument {
    func blockIndex(of id: NodeID) -> Int? {
        segments.firstIndex { if case .block(let b) = $0 { return b.id == id }; return false }
    }

    func block(_ id: NodeID) -> EditableBlock? {
        for s in segments { if case .block(let b) = s, b.id == id { return b } }
        return nil
    }

    func isValid(_ pos: EditPosition) -> Bool {
        guard let b = block(pos.block) else { return false }
        return pos.offsetUTF16 >= 0 && pos.offsetUTF16 <= (b.text as NSString).length
    }
}
