import Foundation
import QuoinCore

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
    public init(id: IslandUnitID, byteRange: Range<Int>, originBlockID: BlockID) {
        self.id = id; self.byteRange = byteRange; self.originBlockID = originBlockID
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
    public func record(at byteOffset: Int) -> BlockRecord? {
        records.first { $0.byteRange.contains(byteOffset) }
    }
    public mutating func mintIsland(at byteOffset: Int) -> IslandUnit? {
        guard let rec = record(at: byteOffset) else { return nil }
        return IslandUnit(id: .mint(), byteRange: rec.byteRange, originBlockID: rec.blockID)
    }
}
