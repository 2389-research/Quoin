import QuoinCore

public struct BoundaryID: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case interBlock, blockStart, blockEnd }
    public let left: BlockID?; public let right: BlockID?; public let kind: Kind
    public init(left: BlockID?, right: BlockID?, kind: Kind) { self.left = left; self.right = right; self.kind = kind }
}

public struct ByteAnchor: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case byte(Int); case boundary(BoundaryID) }
    public enum Affinity: Hashable, Sendable { case before, after }
    public var kind: Kind; public var affinity: Affinity
    public var goalColumn: Int?; public var revision: Int
    public init(kind: Kind, affinity: Affinity, goalColumn: Int?, revision: Int) {
        self.kind = kind; self.affinity = affinity; self.goalColumn = goalColumn; self.revision = revision
    }
    public static func byte(_ offset: Int, affinity: Affinity, revision: Int, goalColumn: Int?) -> ByteAnchor {
        ByteAnchor(kind: .byte(offset), affinity: affinity, goalColumn: goalColumn, revision: revision)
    }
}

public struct SelectionAnchorRange: Hashable, Sendable {
    public var start: ByteAnchor; public var end: ByteAnchor
    public init(start: ByteAnchor, end: ByteAnchor) { self.start = start; self.end = end }
    public var isCaret: Bool { start == end }
}
