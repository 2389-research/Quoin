import XCTest
@testable import QuoinCore

/// #29: the Edit menu names the action it will reverse ("Undo Typing",
/// "Undo Move Block") and disables on an empty stack. These pin the naming
/// derivation and the way a name rides a step across undo→redo.
final class UndoActionNameTests: XCTestCase {

    // MARK: - Pure derivation

    func testSingleCharInsertIsTyping() {
        XCTAssertEqual(
            UndoActionName.inferred(replacementIsInsert: true, replacementCount: 1, deletedCount: 0),
            .typing)
    }

    func testSingleCharDeleteIsTyping() {
        XCTAssertEqual(
            UndoActionName.inferred(replacementIsInsert: false, replacementCount: 0, deletedCount: 1),
            .typing)
    }

    func testWhitespaceStillCountsAsTyping() {
        // The COALESCER treats whitespace as a boundary, but a space press is
        // still "Typing" as far as the menu label goes.
        XCTAssertEqual(
            UndoActionName.inferred(replacementIsInsert: true, replacementCount: 1, deletedCount: 0),
            .typing)
    }

    func testMultiCharInsertIsGenericEdit() {
        XCTAssertEqual(
            UndoActionName.inferred(replacementIsInsert: true, replacementCount: 6, deletedCount: 0),
            .edit)
    }

    func testReplacementIsGenericEdit() {
        // A one-char replacement of a one-char range (length 1) is not an
        // insert (replacementIsInsert=false) — it's an Edit, not Typing.
        XCTAssertEqual(
            UndoActionName.inferred(replacementIsInsert: false, replacementCount: 1, deletedCount: 1),
            .edit)
    }

    func testMenuTitles() {
        XCTAssertEqual(UndoActionName.typing.menuTitle, "Typing")
        XCTAssertEqual(UndoActionName.moveBlock.menuTitle, "Move Block")
        XCTAssertEqual(UndoActionName.properties.menuTitle, "Edit Properties")
    }

    // MARK: - Session integration

    func testEmptyStacksHaveNoName() async {
        let s = DocumentSession(source: "hi")
        let undo = await s.undoActionName
        let redo = await s.redoActionName
        XCTAssertNil(undo)
        XCTAssertNil(redo)
    }

    func testTypingNamesTheUndo() async throws {
        let s = DocumentSession(source: "")
        _ = try await s.applyEdit(SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "a"))
        let name = await s.undoActionName
        XCTAssertEqual(name, .typing)
    }

    func testExplicitNameSurvivesAndRidesToRedo() async throws {
        let s = DocumentSession(source: "one\n\ntwo")
        // Simulate a Move Block edit: a whole-region replacement with an
        // explicit action name.
        _ = try await s.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 8), replacement: "two\n\none"),
            actionName: .moveBlock)
        let afterEdit = await s.undoActionName
        XCTAssertEqual(afterEdit, .moveBlock)

        _ = try await s.undo()
        let afterUndo = await s.undoState
        XCTAssertNil(afterUndo.undoActionName, "nothing left to undo")
        XCTAssertEqual(afterUndo.redoActionName, .moveBlock, "the step keeps its name on the redo stack")

        _ = try await s.redo()
        let afterRedo = await s.undoActionName
        XCTAssertEqual(afterRedo, .moveBlock, "redoing restores the named step to the undo stack")
    }

    func testExplicitOneCharNameDoesNotCoalesceIntoTyping() async throws {
        let s = DocumentSession(source: "")
        // A one-character insert that carries an explicit intent must start
        // its OWN named group, not extend an anonymous typing run.
        _ = try await s.applyEdit(SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "a"))
        _ = try await s.applyEdit(
            SourceEdit(range: ByteRange(offset: 1, length: 0), replacement: "b"),
            actionName: .replace)
        let named = await s.undoActionName
        XCTAssertEqual(named, .replace)
        // Undo the named step; the earlier typing remains, correctly named.
        let afterFirstUndo = try await s.undo()
        XCTAssertEqual(afterFirstUndo?.source, "a")
        let remaining = await s.undoActionName
        XCTAssertEqual(remaining, .typing)
    }

    func testCoalescedTypingStaysOneTypingGroup() async throws {
        let s = DocumentSession(source: "")
        for (i, ch) in "word".enumerated() {
            _ = try await s.applyEdit(
                SourceEdit(range: ByteRange(offset: i, length: 0), replacement: String(ch)))
        }
        let name = await s.undoActionName
        XCTAssertEqual(name, .typing)
        let undone = try await s.undo()
        XCTAssertEqual(undone?.source, "", "one Typing group")
        let after = await s.undoActionName
        XCTAssertNil(after)
    }
}
