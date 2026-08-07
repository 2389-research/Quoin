import XCTest
@testable import QuoinCore

/// N files dropped on the Dock icon must become N TABS IN ONE WINDOW — never N
/// windows, and never a blank orphan (issue #41).
final class EntryPathRoutingTests: XCTestCase {

    func testMultipleOpensCoalesceIntoOneBatch() {
        var slot = PendingOpenSlot()
        slot.enqueue(URL(fileURLWithPath: "/tmp/a.md"))
        slot.enqueue(URL(fileURLWithPath: "/tmp/b.md"))
        slot.enqueue(URL(fileURLWithPath: "/tmp/c.md"))
        XCTAssertEqual(slot.drain().count, 3, "one drain takes all three")
        XCTAssertTrue(slot.drain().isEmpty, "a second drainer must see nothing")
    }

    func testPeekDoesNotConsume() {
        var slot = PendingOpenSlot()
        slot.enqueue(URL(fileURLWithPath: "/tmp/a.md"))
        XCTAssertTrue(slot.hasPending)
        XCTAssertEqual(slot.drain().count, 1, "peeking must not have consumed it")
    }
}
