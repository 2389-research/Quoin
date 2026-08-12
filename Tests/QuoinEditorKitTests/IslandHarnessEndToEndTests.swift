#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 2 MILESTONE: the standing end-to-end regression gate that makes
/// "green-but-broken editing" impossible for within-block edits.
///
/// The Phase-0 `EditorTestHarness` drove a bare offscreen `NSTextView`; here it
/// is repointed — via `init(adopting:appliedRevision:)` — at the REAL editable
/// island (`BlockEditorCell.islandTextView`) promoted by an `IslandController`
/// on a live recycler. The SAME drivers (`type`) and the SAME insertion-bar gate
/// (`assertInsertionBar`) now exercise the actual edit path: keystroke through
/// the real `NSTextInputClient` → island reconcile debounce → `SourceEdit`
/// splice into the document, with the caret proven a REAL bar in the REAL island.
///
/// The `onReconcile` stub applies the edit through the real incremental parse
/// (`MarkdownConverter.parseAfterEdit`, exactly what `DocumentSession` uses) and
/// hands the new document back via `applyReconciled` — the same two-phase seam
/// the app uses. Flushing is deterministic (`flushPendingReconcile()`); no
/// sleeping on the 200 ms debounce. Headless, in an offscreen borderless window.
@MainActor
final class IslandHarnessEndToEndTests: XCTestCase {

    func testHarnessDrivesRealIslandEditPathEndToEnd() throws {
        // A live recycler in an offscreen window (same recipe as IslandReconcileTests).
        let md = "# Title\n\nHello world.\n\nTail."
        let doc = MarkdownConverter.parse(md)
        let recycler = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = OffscreenTestWindow.make(width: 640, height: 480)
        window.contentView = recycler
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        recycler.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        recycler.setDocument(doc, contentWidth: 600)
        recycler.layoutSubtreeIfNeeded()

        // The stub session: apply each SourceEdit through the real incremental
        // parse, hand the new doc back, and bump a monotonic applied-revision — the
        // real "an edit landed" signal the adopting harness keys its quiescence off.
        final class Session {
            var doc: QuoinDocument
            var revision = 0
            init(_ d: QuoinDocument) { doc = d }
        }
        let session = Session(doc)
        let controller = IslandController(recycler: recycler)
        controller.onReconcile = { [weak controller] range, newText, _ in
            let edit = SourceEdit(range: range, replacement: newText)
            let result = try! MarkdownConverter.parseAfterEdit(previous: session.doc, edit: edit)
            session.doc = result.document
            session.revision += 1
            controller?.applyReconciled(result.document)
        }

        // Sanity: block[1] is the middle paragraph "Hello world." at byte offset 9.
        XCTAssertEqual(doc.source.substring(in: doc.blocks[1].range), "Hello world.")
        XCTAssertEqual(doc.blocks[1].range.offset, 9)

        // Activate the block — the recycler promotes a row to a BlockEditorCell and
        // the island text view appears.
        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell,
                                 "activation did not promote an editor cell")
        let islandTextView = cell.islandTextView

        // Repoint the Phase-0 harness at the REAL island. The applied-revision
        // closure sources the orchestrator's real applied-edit signal.
        let harness = EditorTestHarness(adopting: islandTextView,
                                        appliedRevision: { session.revision })

        // Drive a keystroke through the real input path, then reconcile.
        harness.type("Z")
        harness.quiesce()
        controller.flushPendingReconcile()

        // (a) The document reflects the Z BYTE-EXACTLY inside block[1]'s range.
        // Activation placed the caret at localPoint .zero → block start, so the Z
        // splices at the head of "Hello world." → "ZHello world." (offset 9); every
        // untouched region is byte-identical.
        XCTAssertEqual(session.doc.source, "# Title\n\nZHello world.\n\nTail.")
        XCTAssertEqual(session.doc.source.substring(in: session.doc.blocks[1].range),
                       "ZHello world.", "the Z landed inside block[1]'s byte range")
        XCTAssertEqual(String(session.doc.source.prefix(9)), "# Title\n\n",
                       "block[0] + gap untouched")
        XCTAssertTrue(session.doc.source.hasSuffix("\n\nTail."),
                      "gap + block[2] untouched")
        // EXACTLY one applied edit, not ">= 1": the loose bound is satisfied by a
        // signal that fired twice (a duplicate KEEP-then-terminal flush — a real
        // bug class this suite has already shipped once, see IslandIMEDrainTests).
        XCTAssertEqual(harness.appliedRevision, 1,
                       "the real applied-edit signal ticked exactly once for one keystroke")

        // (b) The caret is a REAL insertion bar in the REAL island — the standing
        // 2pt-dot gate, now on the actual edit path.
        harness.assertInsertionBar(minHeight: 8, file: #filePath, line: #line)

        // (c) No residual marked text — the input path committed cleanly.
        XCTAssertFalse(islandTextView.hasMarkedText(),
                       "no dangling IME composition after the driven keystroke")
    }
}
#endif
