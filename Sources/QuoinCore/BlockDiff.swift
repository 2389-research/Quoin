import Foundation

/// The result of diffing two block lists by identity. Because `BlockID` is
/// content hash + occurrence index, an unchanged block keeps its identity
/// across re-parses, so the renderer patches only what changed and cached
/// attachments (diagrams, math, images) are reused.
public struct BlockDiff: Sendable {
    /// IDs present in both old and new documents.
    public let unchanged: Set<BlockID>
    /// IDs only in the new document — need rendering.
    public let inserted: Set<BlockID>
    /// IDs only in the old document — can be discarded.
    public let removed: Set<BlockID>

    public static func between(old: [Block], new: [Block]) -> BlockDiff {
        let oldIDs = Set(old.map(\.id))
        let newIDs = Set(new.map(\.id))
        return BlockDiff(
            unchanged: oldIDs.intersection(newIDs),
            inserted: newIDs.subtracting(oldIDs),
            removed: oldIDs.subtracting(newIDs)
        )
    }

    /// A stable anchor for preserving scroll position across a reload: the
    /// first unchanged block at or before the given block in the old order.
    public static func scrollAnchor(near blockID: BlockID, old: [Block], diff: BlockDiff) -> BlockID? {
        guard let index = old.firstIndex(where: { $0.id == blockID }) else {
            return old.first(where: { diff.unchanged.contains($0.id) })?.id
        }
        for i in stride(from: index, through: 0, by: -1) where diff.unchanged.contains(old[i].id) {
            return old[i].id
        }
        return old.dropFirst(index).first(where: { diff.unchanged.contains($0.id) })?.id
    }
}
