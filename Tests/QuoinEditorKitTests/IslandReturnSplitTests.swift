#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 3, Task 5: RETURN-SPLIT — Return at a prose boundary creates a new block
/// and the caret FOLLOWS into it (staying editable). This is the EXACT original
/// bug: Return at the end of a heading/paragraph produced a dead/dot caret and the
/// next keystroke landed on the wrong block.
///
/// Return now routes through the REAL command path
/// (`IslandTextView.doCommand(by: insertNewline:)` → `onInsertNewline` →
/// `IslandController.handleReturn`) — the test drives it via `harness.pressReturn()`
/// so the subclass override is genuinely exercised, NOT bypassed. `handleReturn`
/// branches on `ReturnSemantics.mode(for: island block kind)`:
///
/// - `.paragraphBreak` (paragraph/heading): insert `\n\n` natively; the debounce
///   reconcile + Task-4 re-activate-at-caret primitive re-homes the island into the
///   caret's new block.
/// - `.verbatim` (code/math/…): insert a plain `\n`; the newline stays IN-block
///   (KEEP path re-seeds 1:1, no split).
///
/// ## A cmark reality the test pins honestly
///
/// Markdown has NO representation for an empty trailing paragraph: `"Hello\n\n"`
/// re-parses to ONE block, not two. So Return at the very end of the document's
/// last paragraph cannot immediately yield a second block — the new block
/// MATERIALIZES on the first keystroke. Between the two, the island stays alive on
/// the last block with its slice extended through EOF (the design doc's "last block
/// absorbs through EOF"), caret on the now-occupiable blank line — which is exactly
/// the fix for the dead-caret bug. The test asserts that live intermediate state
/// AND the materialized two-block result after typing.
///
/// Headless, on a real recycler in an offscreen borderless window; the stub
/// `onReconcile` applies the `SourceEdit` through the real incremental parse and
/// hands the new document + flush-time `caretDocByte` back (the Task-4 stub wiring).
@MainActor
final class IslandReturnSplitTests: XCTestCase {

    private func makeRecycler(_ md: String) -> (BlockRecyclerView, QuoinDocument, NSWindow) {
        let doc = MarkdownConverter.parse(md)
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = v
        window.makeKeyAndOrderFront(nil)
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()
        return (v, doc, window)
    }

    /// The Task-4 stub, plus a monotonic applied-revision the adopting harness keys
    /// its quiescence off. Applies each `SourceEdit` through the real incremental
    /// parse, computes `caretDocByte` at flush, and hands the result back.
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

    // MARK: - The original bug: Return at the end of a paragraph, caret follows

    func testReturnAtEndOfParagraphCreatesNewBlockAndCaretFollows() {
        let (v, doc, window) = makeRecycler("Hello")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let stub = installStub(controller, startingFrom: doc)

        // Activate the paragraph, caret at its END.
        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)
        XCTAssertNotNil(controller.activeIsland)
        let cell = v.editorCellForEditingRow()!
        cell.islandTextView.setSelectedRange(NSRange(location: 5, length: 0))

        // Press Return through the REAL command path (adopt the live island so
        // `doCommand(insertNewline:)` hits the `IslandTextView` override → hook →
        // handleReturn). NOT a native `insertNewline(nil)` that skips the override.
        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: stub.rev)
        harness.pressReturn()
        controller.flushPendingReconcile()

        // The island SURVIVED (the original bug: it died to a dead/dot caret) and now
        // hosts the paragraph plus the occupiable blank line, caret past the break.
        XCTAssertEqual(stub.doc().source, "Hello\n\n")
        XCTAssertNotNil(controller.activeIsland,
                        "Return at end keeps the island alive (the original bug killed it)")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "Hello\n\n")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 7,
                       "caret sits on the new occupiable blank line, past the paragraph break")

        // Typing lands in the NEW block: the keystroke materializes the second
        // paragraph and the island re-homes onto it (Task-4 primitive).
        let c2 = v.editorCellForEditingRow()!
        c2.islandTextView.insertText("X", replacementRange: NSRange(location: 7, length: 0))
        c2.islandTextView.setSelectedRange(NSRange(location: 8, length: 0))
        controller.flushPendingReconcile()

        let newDoc = stub.doc()
        XCTAssertEqual(newDoc.source, "Hello\n\nX",
                       "the caret followed into the new block; the X landed there")
        XCTAssertEqual(newDoc.blocks.count, 2, "two blocks now: \"Hello\" + \"X\"")
        XCTAssertEqual(newDoc.source.substring(in: newDoc.blocks[0].range), "Hello")
        XCTAssertEqual(newDoc.source.substring(in: newDoc.blocks[1].range), "X")
        XCTAssertNotNil(controller.activeIsland, "island still active, now on the second block")
        XCTAssertEqual(newDoc.source.substring(in: ByteRange(controller.activeIsland!.byteRange)),
                       "X", "the island re-homed onto the NEW second block")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "X")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 1,
                       "caret after the typed X in the new block")
    }

    // MARK: - Heading is paragraphBreak too

    func testReturnAtEndOfHeadingSplits() {
        let (v, doc, window) = makeRecycler("# Title\n\nBody.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let stub = installStub(controller, startingFrom: doc)

        // Activate the heading "# Title" (block[0]); caret between the two words so
        // the `\n\n` genuinely SPLITS into two blocks that both exist immediately.
        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = v.editorCellForEditingRow()!
        // "# Title" — caret after "# Ti" (offset 4): splits into "# Ti" + "tle".
        cell.islandTextView.setSelectedRange(NSRange(location: 4, length: 0))
        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: stub.rev)
        harness.pressReturn()
        controller.flushPendingReconcile()

        // "# Title" split at the caret; the island re-homed onto the caret's block.
        XCTAssertEqual(stub.doc().source, "# Ti\n\ntle\n\nBody.")
        XCTAssertNotNil(controller.activeIsland, "heading Return keeps the island alive")
        XCTAssertEqual(stub.doc().source.substring(in: ByteRange(controller.activeIsland!.byteRange)),
                       "tle", "island re-homed onto the block containing the caret")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "tle")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 0,
                       "caret at the start of the new block")
    }

    // MARK: - Verbatim: Return inside a code block stays in-block (no split)

    func testReturnInsideCodeBlockStaysInBlock() {
        let (v, doc, window) = makeRecycler("```\nlet x = 1\n```")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let stub = installStub(controller, startingFrom: doc)

        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)
        XCTAssertNotNil(controller.activeIsland)
        XCTAssertEqual(controller.activeIslandKind.map(ReturnSemantics.mode(for:)), .verbatim,
                       "a code block classifies as .verbatim Return")
        let cell = v.editorCellForEditingRow()!
        // Caret in the middle of the code line (offset 7, before the space in "let ").
        cell.islandTextView.setSelectedRange(NSRange(location: 7, length: 0))
        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: stub.rev)
        harness.pressReturn()
        controller.flushPendingReconcile()

        // Exactly ONE "\n" was inserted (NOT a "\n\n" paragraph break): the block does
        // NOT split and the island stays active on the SAME code block.
        XCTAssertEqual(stub.doc().source, "```\nlet\n x = 1\n```")
        XCTAssertEqual(stub.doc().blocks.count, 1, "a verbatim newline does not split the block")
        XCTAssertNotNil(controller.activeIsland, "island stays active in the code block")
        XCTAssertEqual(controller.activeIslandKind.map(ReturnSemantics.mode(for:)), .verbatim)
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "```\nlet\n x = 1\n```")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 8,
                       "caret advanced past the single inserted newline")
    }
}
#endif
