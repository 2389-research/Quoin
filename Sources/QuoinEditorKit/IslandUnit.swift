import Foundation
import QuoinCore

// MARK: - ByteRange <-> Range<Int> bridge
//
// QuoinCore's `ByteRange` (offset/length) and the stdlib `Range<Int>` are
// both used to express UTF-8 byte spans; Phase 2 bridges island geometry
// to `DocumentSession`'s edit API, which speaks `ByteRange`.

public extension ByteRange {
    /// Half-open range -> ByteRange: offset is the lower bound, length is the count.
    init(_ r: Range<Int>) {
        self.init(offset: r.lowerBound, length: r.count)
    }
}

public extension Range where Bound == Int {
    /// ByteRange -> half-open range: `offset ..< offset + length`.
    init(_ b: ByteRange) {
        self = b.offset ..< (b.offset + b.length)
    }
}

public struct IslandUnitID: Hashable, Sendable {
    private let raw: Int
    private static let counter = Counter()
    fileprivate init(raw: Int) { self.raw = raw }
    static func mint() -> IslandUnitID { IslandUnitID(raw: counter.next()) }
    // A tiny thread-safe monotonic source (islands are minted on the main actor in
    // practice; the lock keeps the type self-contained and Sendable-safe).
    final class Counter: @unchecked Sendable {
        private var value = 0; private let lock = NSLock()
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }
}

public struct IslandUnit: Sendable {
    public let id: IslandUnitID
    public var byteRange: Range<Int>
    public var originBlockID: BlockID
    /// The document revision in effect when this island was minted. Reconciliation
    /// (Phase 2) diffs the island's edits against this base to detect drift.
    public var baseRevision: Int
    public init(id: IslandUnitID, byteRange: Range<Int>, originBlockID: BlockID, baseRevision: Int) {
        self.id = id; self.byteRange = byteRange; self.originBlockID = originBlockID
        self.baseRevision = baseRevision
    }
}

public struct BlockRecord: Sendable, Hashable {
    public let blockID: BlockID; public let kind: BlockKind; public var byteRange: Range<Int>
    public init(blockID: BlockID, kind: BlockKind, byteRange: Range<Int>) {
        self.blockID = blockID; self.kind = kind; self.byteRange = byteRange
    }
}

public struct BlockListModel: Sendable {
    public private(set) var records: [BlockRecord]
    public init(document: QuoinDocument) {
        records = document.blocks.map {
            BlockRecord(blockID: $0.id, kind: $0.kind,
                        byteRange: $0.range.offset ..< ($0.range.offset + $0.range.length))
        }
    }
    /// Resolves the block whose half-open range CONTAINS `byteOffset`. Boundary
    /// offsets fall out of that rule naturally (a block-end offset equals the
    /// next block's start, which contains it) EXCEPT the document-end offset,
    /// which is contained by nothing (it's one-past the last block's upper
    /// bound); that case is special-cased to resolve to the LAST block.
    public func record(at byteOffset: Int) -> BlockRecord? {
        if let rec = records.first(where: { $0.byteRange.contains(byteOffset) }) {
            return rec
        }
        if let last = records.last, byteOffset == last.byteRange.upperBound {
            return last
        }
        return nil
    }
    /// Mints a fresh island at `byteOffset`, carrying `baseRevision` (the document
    /// revision in effect at mint time) for Phase 2 reconciliation.
    public mutating func mintIsland(at byteOffset: Int, baseRevision: Int) -> IslandUnit? {
        guard let rec = record(at: byteOffset) else { return nil }
        return IslandUnit(id: .mint(), byteRange: rec.byteRange, originBlockID: rec.blockID,
                           baseRevision: baseRevision)
    }
    /// Convenience for callers that don't yet track a document revision (e.g. Phase 0 tests).
    public mutating func mintIsland(at byteOffset: Int) -> IslandUnit? {
        mintIsland(at: byteOffset, baseRevision: 0)
    }
}
