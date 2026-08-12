#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 3, Task 6: LIST / QUOTE Return continuation + empty-item-exit.
///
/// Two layers, both the contract:
///   1. PURE marker logic (`ListContinuation.list` / `.quote`) — exhaustive
///      marker cases: unordered `-`/`*`/`+`, ordered increment (incl. `9.`→`10.`)
///      with `.`/`)` delimiters, nested indent, task items (fresh box), quote
///      continuation + nesting, and every EMPTY-marker → `.exit`.
///   2. END-TO-END via the adopting harness + stub session (mirrors
///      `IslandReturnSplitTests`): island on a list/quote block, Return through
///      the REAL command path, source gains a new item with the right marker and
///      the island stays alive on the SAME block; Return on an empty item exits.
@MainActor
final class IslandListReturnTests: XCTestCase {

    // MARK: - PURE: unordered bullets

    func testUnorderedDashContinues() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "- item"), .continue("\n- "))
    }

    func testUnorderedStarPreservesBullet() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "* item"), .continue("\n* "))
    }

    func testUnorderedPlusPreservesBullet() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "+ item"), .continue("\n+ "))
    }

    func testNestedIndentPreserved() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "  - a"), .continue("\n  - "))
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "    * a"), .continue("\n    * "))
    }

    // MARK: - PURE: ordered increment

    func testOrderedIncrements() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "1. item"), .continue("\n2. "))
    }

    func testOrderedRollover() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "9. item"), .continue("\n10. "))
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "99. item"), .continue("\n100. "))
    }

    func testOrderedParenDelimiterPreserved() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "1) item"), .continue("\n2) "))
    }

    func testOrderedNestedIndent() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "   3. x"), .continue("\n   4. "))
    }

    // MARK: - PURE: task items (fresh unchecked box)

    func testTaskItemContinuesUnchecked() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "- [ ] a"), .continue("\n- [ ] "))
    }

    func testCheckedTaskItemResetsBox() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "- [x] done"), .continue("\n- [ ] "))
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "- [X] done"), .continue("\n- [ ] "))
    }

    func testEmptyTaskItemExits() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "- [ ] "), .exit)
    }

    // MARK: - PURE: empty items exit

    func testEmptyDashExits() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "- "), .exit)
    }

    func testEmptyOrderedExits() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "1. "), .exit)
    }

    func testEmptyNestedExits() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "  - "), .exit)
    }

    func testMarkerWithTrailingSpacesIsEmpty() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "-   "), .exit)
    }

    // MARK: - PURE: fallbacks (never crash)

    func testNonMarkerLineFallsBackToNewline() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "plain text"), .continue("\n"))
    }

    func testGluedBulletFallsBack() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: "-text"), .continue("\n"))
    }

    func testEmptyLineFallsBack() {
        XCTAssertEqual(ListContinuation.list(lineUpToCaret: ""), .continue("\n"))
    }

    // MARK: - PURE: quotes

    func testQuoteContinues() {
        XCTAssertEqual(ListContinuation.quote(lineUpToCaret: "> hello"), .continue("\n> "))
    }

    func testNestedQuoteContinues() {
        XCTAssertEqual(ListContinuation.quote(lineUpToCaret: "> > deep"), .continue("\n> > "))
    }

    func testEmptyQuoteExits() {
        XCTAssertEqual(ListContinuation.quote(lineUpToCaret: "> "), .exit)
        XCTAssertEqual(ListContinuation.quote(lineUpToCaret: ">"), .exit)
    }

    func testEmptyNestedQuoteExits() {
        XCTAssertEqual(ListContinuation.quote(lineUpToCaret: "> > "), .exit)
    }

    func testNonQuoteLineFallsBack() {
        XCTAssertEqual(ListContinuation.quote(lineUpToCaret: "plain"), .continue("\n"))
    }

    // MARK: - End-to-end harness

    private func makeRecycler(_ md: String) -> (BlockRecyclerView, QuoinDocument, NSWindow) {
        let doc = MarkdownConverter.parse(md)
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = OffscreenTestWindow.make(width: 640, height: 480)
        window.contentView = v
        window.makeKeyAndOrderFront(nil)
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()
        return (v, doc, window)
    }

    /// The Task-4 stub: applies each `SourceEdit` through the real incremental
    /// parse and hands the new document + flush-time `caretDocByte` back.
    private func installStub(
        _ controller: IslandController, startingFrom doc: QuoinDocument
    ) -> (doc: () -> QuoinDocument, rev: () -> Int) {
        final class Box { var doc: QuoinDocument; var rev = 0; init(_ d: QuoinDocument) { doc = d } }
        let box = Box(doc)
        controller.onReconcile = { [weak controller] range, newText, caret in
            let edit = SourceEdit(range: range, replacement: newText)
            let result = try! MarkdownConverter.parseAfterEdit(previous: box.doc, edit: edit)
            box.doc = result.document
            box.rev += 1
            let caretDocByte = IslandCaretMapping.documentByte(
                localUTF16: caret, islandSource: newText, islandByteStart: range.offset)
            controller?.applyReconciled(result.document, caretDocByte: caretDocByte)
        }
        return ({ box.doc }, { box.rev })
    }

    // MARK: - List continuation, then empty-item exit

    func testListReturnAddsItemThenEmptyExits() {
        let (v, doc, window) = makeRecycler("- a")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let stub = installStub(controller, startingFrom: doc)

        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)
        XCTAssertNotNil(controller.activeIsland)
        XCTAssertEqual(controller.activeIslandKind.map(ReturnSemantics.mode(for:)), .listAware,
                       "a list block classifies as .listAware Return")
        let cell = v.editorCellForEditingRow()!
        cell.islandTextView.setSelectedRange(NSRange(location: 3, length: 0)) // end of "- a"

        // Return at end of a non-empty item → a fresh "- " item, island stays on
        // the SAME list block, caret after the new marker.
        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: stub.rev)
        harness.pressReturn()
        controller.flushPendingReconcile()

        XCTAssertEqual(stub.doc().source, "- a\n- ", "a new bullet was continued")
        XCTAssertNotNil(controller.activeIsland, "the island stays alive on the list")
        XCTAssertEqual(controller.activeIslandKind.map(ReturnSemantics.mode(for:)), .listAware,
                       "still a list-aware block (in-block KEEP path, no split)")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "- a\n- ")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 6,
                       "caret sits after the freshly inserted marker")

        // Return AGAIN on the now-empty trailing item → EXIT (marker removed).
        let cell2 = v.currentEditorCell!
        let harness2 = EditorTestHarness(adopting: cell2.islandTextView, appliedRevision: stub.rev)
        harness2.pressReturn()
        controller.flushPendingReconcile()

        XCTAssertEqual(stub.doc().source, "- a\n",
                       "the empty marker was deleted — the list exits to a blank line")
    }

    // MARK: - Ordered list increments end-to-end

    func testOrderedListReturnIncrements() {
        let (v, doc, window) = makeRecycler("1. a")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let stub = installStub(controller, startingFrom: doc)

        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = v.editorCellForEditingRow()!
        cell.islandTextView.setSelectedRange(NSRange(location: 4, length: 0)) // end of "1. a"
        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: stub.rev)
        harness.pressReturn()
        controller.flushPendingReconcile()

        XCTAssertEqual(stub.doc().source, "1. a\n2. ", "the ordered marker incremented to 2.")
        XCTAssertNotNil(controller.activeIsland, "island stays alive on the ordered list")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 8,
                       "caret after the new '2. ' marker")
    }

    // MARK: - Quote continuation, then empty-quote exit

    func testQuoteReturnContinuesThenExits() {
        let (v, doc, window) = makeRecycler("> hello")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let stub = installStub(controller, startingFrom: doc)

        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)
        XCTAssertNotNil(controller.activeIsland)
        XCTAssertEqual(controller.activeIslandKind.map(ReturnSemantics.mode(for:)), .quoteAware,
                       "a block-quote classifies as .quoteAware Return")
        let cell = v.editorCellForEditingRow()!
        cell.islandTextView.setSelectedRange(NSRange(location: 7, length: 0)) // end of "> hello"

        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: stub.rev)
        harness.pressReturn()
        controller.flushPendingReconcile()

        XCTAssertEqual(stub.doc().source, "> hello\n> ", "the quote prefix continued")
        XCTAssertNotNil(controller.activeIsland, "island stays alive on the quote")
        XCTAssertEqual(controller.activeIslandKind.map(ReturnSemantics.mode(for:)), .quoteAware)
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "> hello\n> ")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 10,
                       "caret after the continued '> ' prefix")

        // Return again on the empty quoted line → EXIT.
        let cell2 = v.currentEditorCell!
        let harness2 = EditorTestHarness(adopting: cell2.islandTextView, appliedRevision: stub.rev)
        harness2.pressReturn()
        controller.flushPendingReconcile()

        XCTAssertEqual(stub.doc().source, "> hello\n",
                       "the empty quote prefix was deleted — the quote exits")
    }
}
#endif
