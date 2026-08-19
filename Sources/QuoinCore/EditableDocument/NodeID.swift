import Foundation

/// A stable identity for an editable block. NOT content-hashed (unlike
/// `BlockID`): it must survive edits to the block's own content, so split/join
/// and caret tracking can follow a block as its text changes.
public struct NodeID: Hashable, Sendable {
    private let raw: UInt64

    private init(raw: UInt64) { self.raw = raw }

    /// A process-unique counter. Deterministic within a run (no `Date`/random —
    /// which are also unavailable to some sandboxes), monotonic, thread-safe.
    private static let counter = Counter()

    public static func fresh() -> NodeID { NodeID(raw: counter.next()) }

    private final class Counter: @unchecked Sendable {
        private var value: UInt64 = 0
        private let lock = NSLock()
        func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }
}
