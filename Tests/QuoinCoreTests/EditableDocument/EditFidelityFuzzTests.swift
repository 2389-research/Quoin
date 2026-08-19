import XCTest
@testable import QuoinCore

/// The elimination proof. These are the exact behaviors that were broken in the
/// string-as-truth model; here they hold by construction.
final class EditFidelityFuzzTests: XCTestCase {

    private func blockIDs(_ d: EditableDocument) -> [NodeID] {
        d.segments.compactMap { if case .block(let b) = $0 { return b.id } else { return nil } }
    }

    /// Return then Backspace at the same seam is the IDENTITY — byte-identical to
    /// the original. (In the old model this corrupted the heading.)
    func testSplitThenJoinIsIdentity() {
        for source in ["# How to do things", "Hello", "a\n\nb\n\nc", "# H\n\nbody\n"] {
            let d = EditableDocument.build(parsing: source)
            for id in blockIDs(d) {
                let len = (d.block(id)!.text as NSString).length
                for offset in [0, len / 2, len] {
                    var work = d
                    let caret = work.splitBlock(at: EditPosition(block: id, offsetUTF16: offset))
                    let back = work.joinWithPrevious(caret.block)
                    XCTAssertEqual(work.serialized(), d.serialized(),
                                   "split@\(offset) then join not identity for \(source.debugDescription)")
                    XCTAssertNotNil(back)
                }
            }
        }
    }

    /// The headline scenario, end to end: type a heading, Return, type, delete it
    /// back, Backspace to the heading — the heading is NEVER corrupted.
    func testHeadingReturnTypeDeleteBackspaceKeepsHeadingIntact() {
        var d = EditableDocument.build(parsing: "# How to do things")
        let heading = blockIDs(d)[0]
        let afterReturn = d.splitBlock(at: EditPosition(
            block: heading, offsetUTF16: ("# How to do things" as NSString).length))
        // Type "clint" into the new empty paragraph.
        var caret = afterReturn
        for ch in "clint" { caret = d.insertText(String(ch), at: caret) }
        XCTAssertEqual(d.serialized(), "# How to do things\n\nclint")
        // Delete "clint" back to empty.
        caret = d.deleteRange(inBlock: caret.block, 0..<("clint" as NSString).length)
        // Backspace at the start of the now-empty paragraph → join into heading.
        _ = d.joinWithPrevious(caret.block)
        XCTAssertEqual(d.serialized(), "# How to do things",
                       "the heading survives byte-for-byte — no eaten 'g'")
    }

    /// An edit to ONE block leaves every other block byte-identical (retained
    /// spans re-emit verbatim).
    func testEditingOneBlockLeavesOthersByteIdentical() {
        var d = EditableDocument.build(parsing: "alpha\n\nbeta\n\ngamma")
        let ids = blockIDs(d)
        _ = d.insertText("X", at: EditPosition(block: ids[1], offsetUTF16: 2))  // "beta" -> "beXta"
        XCTAssertEqual(d.serialized(), "alpha\n\nbeXta\n\ngamma")
    }
}
