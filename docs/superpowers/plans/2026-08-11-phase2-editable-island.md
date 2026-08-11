# Phase 2 — One Editable Island Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the block you click in the read-only recycler EDITABLE — promote it to a `BlockEditorCell` hosting a real editable `NSTextView` seeded with the block's raw Markdown source; native typing/caret/selection/IME work; edits reconcile back to the document; and the Phase-0 headless harness drives the real edit path end-to-end. Behind the existing `QuoinEditorRecycler` flag. No structural ops yet.

**Architecture:** `BlockEditorCell` (a real editable `NSTextView` in a recycler row) + an `IslandController`/`SwapState` machine that, on click, flushes any pending island, swaps exactly one row from `BlockRenderCell`→`BlockEditorCell` (via a second reuse identifier + `editingRow` gate, NOT row-view hand-swapping), seeds the raw source, and places the caret. Island edits reconcile through the **KEEP** session apply path — `IslandController` (in `QuoinEditorKit`, which cannot see `ReaderModel`) emits an `onReconcile(ByteRange, String)` closure the app installs to call `ReaderModel.applyAbsolute(edit, caretUTF8: nil)`; the resulting document's `revision` bump refreshes the recycler exactly as Phase 1 already observes. The caret round-trips island-local UTF-16 ↔ document bytes via the Phase-0 `UTF8IndexMap`. Return is a soft newline reconciled verbatim — if a reparse splits the block, the island simply deactivates (Phase 3 owns split/merge).

**Tech Stack:** Swift 5 (QuoinEditorKit), AppKit view-based NSTableView + real editable NSTextView, TextKit 2, XCTest offscreen. Spec: `docs/superpowers/specs/2026-08-11-editable-islands-design.md` §4, §5, §10 Phase 2, §13b.

## Global Constraints

- macOS 14+. New code is AppKit, `#if canImport(AppKit)`; QuoinEditorKit is **Swift 5 language mode**. `QuoinEditorKit` links `QuoinCore` + `QuoinRender` only — it **cannot** reference `ReaderModel` (app target). All model mutation goes through an app-installed closure.
- **Behind the default-OFF `QuoinEditorRecycler` flag.** Flag OFF ⇒ the projection reader is byte-for-byte unchanged. Phase 2 only touches the recycler path + adds one KEEP method to `ReaderModel`.
- **NO structural ops** (Return-split / Backspace-merge across block boundaries). Return inside the island is a literal `\n` reconciled to source; if the reparse changes the block's 1:1 identity, END the edit session (swap back to read) — do NOT hop the caret into a split block or merge. Phase 3 owns that.
- **Byte-lossless:** the only bytes written are the user's real edits, spliced as one `SourceEdit(range: islandByteRange, replacement: islandString)` through the session.
- **Reuse the KEEP session apply path** (`ReaderModel.applyAbsolute(_:caretUTF8:...)` with `caretUTF8: nil`, or `EditorCore.apply` / `DocumentSession.applyEdit`) — NEVER the RIP projection-caret machinery (`activateBlock`, `restoreCaret`, `applyEdit(relativeRange:...)`, `EditMapping.sourceOffset`). The island owns its native caret.
- **Refuse swap/flush/reconcile while `textView.hasMarkedText()`** (IME composition): queue the intent, run it on `unmarkText`.
- No new third-party deps. Revert `Package.resolved` before each commit. Commit + push to `main` after each task with trailers:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_013hf6D4MU3MgzEXSY3qZXEv`.
- `swift test` (UNPIPED) full suite green throughout; app build (`cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build`) green after the wiring tasks.

## Reference anchors (verified)

- Recycler: `Sources/QuoinEditorKit/BlockRecyclerView.swift` — `cellIdentifier` (:101), `viewFor` (:336), `heightOfRow`/`rowHeight(atRow:)` (:332/:204), `setDocument` (:174), `contentDidSettle`→`noteHeightOfRows(withIndexesChanged:)` (:228), `selectionHighlightStyle = .none` (:142). NO click hook exists — build one.
- `BlockRenderCell.configure(block:document:renderer:theme:width:)`; AX/edit-action stub at `:218-220`.
- Session apply (KEEP): `SourceEdit { range: ByteRange; replacement: String }` (`Sources/QuoinCore/SourceEdit.swift:7`); `DocumentSession.applyEdit(_:baseRevision:publishSnapshot:actionName:) throws -> QuoinDocument` (:513); `EditorCore.apply(edit:baseRevision:actionName:publishSnapshot:) async throws -> QuoinDocument` (:224). `ByteRange(offset:length:)`.
- `ReaderModel` (App/macOS): `applyAbsolute(_:caretUTF8:spliceHint:actionName:onError:)` (:1345 — pass `caretUTF8: nil`), `perform(_:on:)` (:825), `ingest(_:contentRevision:)` (:386), `document` (:67) / `rendered` (:20) `@Observable`. RIP (do NOT use): `activateBlock` (:614), `restoreCaret` (:1565), `applyEdit(relativeRange:...)` (:774).
- `BlockRecyclerReaderView.apply(to:coordinator:initial:)` refreshes only on `rendered.revision` change (`BlockRecyclerReaderView.swift:97`); `ReaderScreen.swift:211` constructs it.
- Harness: `Sources/QuoinEditorKit/EditorTestHarness.swift` — `textView` (:31), `type`/`pressReturn`/`pressBackspace`/`move`/`quiesce`/`caretRect` (:79-120), `assertInsertionBar` (test-side `HarnessInsertionBar.swift:14`).
- Phase-0 types: `IslandUnit { id: IslandUnitID; byteRange: Range<Int>; originBlockID: BlockID }`, `BlockListModel(document:)`/`record(at:)`/`mintIsland(at:)` (`IslandUnit.swift`); `UTF8IndexMap(_:)`/`utf8(fromUTF16:)`/`utf16(fromUTF8:)`. Source styling (public): `AttributedRenderer.renderEditableSourceFragment(_:caretOffset:block:document:) -> RevealedFragment` (:402).
- Known gaps to close: `Range<Int>`↔`ByteRange` bridge; `record(at:)` boundary tie-break; capture `baseRevision` at island mint; re-anchor after reconcile (BlockID is content-hash, changes on edit).

## File Structure

- `Sources/QuoinEditorKit/BlockEditorCell.swift` — the editable cell (real NSTextView).
- `Sources/QuoinEditorKit/IslandCaretMapping.swift` — island-local UTF-16 ↔ document byte, `Range<Int>`↔`ByteRange` bridge.
- `Sources/QuoinEditorKit/IslandController.swift` — the `SwapState` machine + activation/flush/reconcile orchestration + the `onReconcile` closure seam.
- `Sources/QuoinEditorKit/BlockRecyclerView.swift` (modify) — click seam + `editingRow`-gated `viewFor`.
- `Sources/QuoinEditorKit/BlockRecyclerReaderView.swift` (modify) — forward the `onReconcile`/click wiring.
- `Sources/QuoinEditorKit/EditorTestHarness.swift` (modify) — `init(adopting:)`.
- `App/macOS/Sources/ReaderModel.swift` (modify) — add `reconcileIsland(byteRange:replacement:)` (KEEP path).
- `App/macOS/Sources/ReaderScreen.swift` (modify) — install the reconcile closure.
- Tests under `Tests/QuoinEditorKitTests/`.

Task 5 (IslandController + SwapState) is the hardest; isolate it.

---

### Task 1: `BlockEditorCell` — a real editable NSTextView leaf

**Files:**
- Create: `Sources/QuoinEditorKit/BlockEditorCell.swift`
- Test: `Tests/QuoinEditorKitTests/BlockEditorCellTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor public final class BlockEditorCell: NSView {
      public init()
      public var islandTextView: NSTextView { get }        // the real editable view (harness + controller use it)
      public func configure(slice: String, blockID: BlockID, width: CGFloat)   // seed raw source
      public private(set) var blockID: BlockID?
      public var onTextDidChange: (() -> Void)?             // fired on live edits (drives debounce + height)
      public var fittingHeightForConfiguredWidth: CGFloat { get }   // from the live text layout
  }
  ```
- Config MUST mirror the harness/spec: `isEditable = true`, `isRichText = false`, and OFF: `isAutomaticQuoteSubstitutionEnabled`, `isAutomaticDashSubstitutionEnabled`, `isAutomaticTextReplacementEnabled`, `isAutomaticSpellingCorrectionEnabled` (Markdown source must never be auto-rewritten). Layer-backed; monospace source is fine for Phase 2 (styling is optional/deferred).

- [ ] **Step 1: Write the failing test** (offscreen window, mirror `EditorTestHarness` window setup)

```swift
#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinEditorKit

@MainActor
final class BlockEditorCellTests: XCTestCase {
    func testSeedsRawSourceAndIsEditableWithRealCaret() {
        let doc = MarkdownConverter.parse("# Heading\n\nBody.")
        let slice = doc.source.substring(in: doc.blocks[0].range)!   // "# Heading"
        let cell = BlockEditorCell()
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:600,height:200), styleMask:[.borderless], backing:.buffered, defer:false)
        window.contentView = cell; window.makeKeyAndOrderFront(nil)
        cell.configure(slice: slice, blockID: doc.blocks[0].id, width: 600)
        window.makeFirstResponder(cell.islandTextView)
        XCTAssertEqual(cell.islandTextView.string, "# Heading")   // RAW source, with the '#'
        XCTAssertTrue(cell.islandTextView.isEditable)
        XCTAssertFalse(cell.islandTextView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertEqual(cell.blockID, doc.blocks[0].id)
        // Real caret bar (not a 2pt dot): place caret at end, read firstRect height.
        cell.islandTextView.setSelectedRange(NSRange(location: 9, length: 0))
        cell.islandTextView.textLayoutManager?.ensureLayout(for: cell.islandTextView.textContentStorage!.documentRange)
        var actual = NSRange()
        let rect = cell.islandTextView.firstRect(forCharacterRange: cell.islandTextView.selectedRange(), actualRange: &actual)
        XCTAssertGreaterThan(rect.height, 8)
    }
    func testTypingFiresOnTextDidChange() {
        let cell = BlockEditorCell()
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:400,height:100), styleMask:[.borderless], backing:.buffered, defer:false)
        window.contentView = cell; window.makeKeyAndOrderFront(nil)
        cell.configure(slice: "ab", blockID: BlockID(contentHash: 1, occurrence: 0), width: 400)
        window.makeFirstResponder(cell.islandTextView)
        var fired = 0; cell.onTextDidChange = { fired += 1 }
        cell.islandTextView.insertText("c", replacementRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(cell.islandTextView.string, "abc")
        XCTAssertGreaterThan(fired, 0)
    }
}
#endif
```

- [ ] **Step 2: Run — verify it fails.** `swift test --filter BlockEditorCellTests` → `BlockEditorCell` undefined.

- [ ] **Step 3: Implement** — a layer-backed `NSView` embedding a real `NSTextView` (TextKit-2 content storage/layout manager/container at `width`), configured per the Interfaces block. Set the text view's delegate (or use `NSTextDidChangeNotification`) to fire `onTextDidChange`. `configure(slice:...)` sets `islandTextView.string = slice`, records `blockID`, re-lays out. `fittingHeightForConfiguredWidth` measures the live layout (ensureLayout + fragment heights). Do NOT wire session/reconcile here (Task 6).

- [ ] **Step 4: Run — verify it passes.** `swift test --filter BlockEditorCellTests` → PASS.

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/BlockEditorCell.swift Tests/QuoinEditorKitTests/BlockEditorCellTests.swift
git commit -m "Phase 2: BlockEditorCell — real editable NSTextView seeded with raw block source"
git push origin main
```

---

### Task 2: Click seam on the recycler

**Files:**
- Modify: `Sources/QuoinEditorKit/BlockRecyclerView.swift`
- Test: `Tests/QuoinEditorKitTests/RecyclerClickTests.swift`

**Interfaces:**
- Produces on `BlockRecyclerView`:
  ```swift
  public var onBlockClicked: ((BlockID, CGPoint) -> Void)?   // (block, cell-local point) on a single click
  func blockAndPoint(forWindowPoint: CGPoint) -> (BlockID, CGPoint)?   // test hook: resolve a window point → (block, cell-local)
  ```
- Consumes: existing `rowByBlockID`, `document.blocks`.

- [ ] **Step 1: Write the failing test** — configure a recycler with a few blocks in an offscreen window, call `blockAndPoint(forWindowPoint:)` for a point over the 2nd row, assert it returns `blocks[1].id` and a sensible cell-local point.

```swift
#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

@MainActor
final class RecyclerClickTests: XCTestCase {
    func testResolvesClickToBlockAndLocalPoint() {
        let doc = MarkdownConverter.parse("First para.\n\nSecond para.\n\nThird para.")
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:640,height:480), styleMask:[.borderless], backing:.buffered, defer:false)
        window.contentView = v; window.makeKeyAndOrderFront(nil); v.frame = NSRect(x:0,y:0,width:640,height:480)
        v.setDocument(doc, contentWidth: 600); v.layoutSubtreeIfNeeded()
        // A window point inside the 2nd row: below the first row's height, small x.
        let row0H = v.rowHeightForTest(0)
        let p = CGPoint(x: 40, y: row0H + 6)   // flipped/table coords — helper converts
        let hit = v.blockAndPoint(forWindowPoint: v.windowPointForTableY(p))   // helper maps table-y → window
        XCTAssertEqual(hit?.0, doc.blocks[1].id)
    }
}
#endif
```
NOTE: the exact coordinate conversion depends on the scroll/flip setup; the implementer adds whatever tiny test helpers (`rowHeightForTest`, `windowPointForTableY`) make the assertion deterministic. The contract is: a click over row N resolves to `blocks[N].id`.

- [ ] **Step 2: Run — verify it fails.** `swift test --filter RecyclerClickTests` → undefined.

- [ ] **Step 3: Implement** — override `mouseDown(_:)` on `BlockRecyclerView` (or set the table's `target`/`action`): convert `event.locationInWindow` to the table view's coords, `tableView.row(at:)` → the block (via the ordered `document.blocks[row]`), convert to the cell-local point, and fire `onBlockClicked(blockID, localPoint)`. Add the `blockAndPoint(forWindowPoint:)` pure resolver + the test helpers. Do NOT swap cells yet (Task 5); this task only REPORTS clicks. Keep `selectionHighlightStyle = .none`.

- [ ] **Step 4: Run — verify it passes.**

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/BlockRecyclerView.swift Tests/QuoinEditorKitTests/RecyclerClickTests.swift
git commit -m "Phase 2: recycler click seam — resolve a click to (BlockID, cell-local point)"
git push origin main
```

---

### Task 3: `Range<Int>`↔`ByteRange` bridge + island mint hardening

**Files:**
- Modify: `Sources/QuoinEditorKit/IslandUnit.swift`
- Test: `Tests/QuoinEditorKitTests/IslandMintTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public extension ByteRange { init(_ r: Range<Int>) }               // offset=r.lowerBound, length=r.count
  public extension Range where Bound == Int { init(_ b: ByteRange) } // b.offset ..< b.offset+b.length
  // On IslandUnit: capture the base revision at mint (for reconciliation's baseRevision).
  public struct IslandUnit { …; public var baseRevision: Int }        // add field
  public extension BlockListModel {
      mutating func mintIsland(at byteOffset: Int, baseRevision: Int) -> IslandUnit?
  }
  ```
- Fix `record(at:)` boundary tie-break: an offset exactly at a block-end / between two blocks resolves to the block whose range CONTAINS it, and the document-end offset resolves to the LAST block (define + test the rule).

- [ ] **Step 1: Write the failing test** — round-trip `ByteRange(1..<5)`↔`Range`; mint at an interior offset, at a block boundary, and at the document-end offset, asserting the expected block each time and that `baseRevision` is carried; two mints get distinct `IslandUnitID`.

- [ ] **Step 2: Run — verify it fails.**

- [ ] **Step 3: Implement** the bridges, the `baseRevision` field + parameter, and the boundary tie-break in `record(at:)`.

- [ ] **Step 4: Run — verify it passes.**

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/IslandUnit.swift Tests/QuoinEditorKitTests/IslandMintTests.swift
git commit -m "Phase 2: ByteRange<->Range bridge; island mint carries baseRevision; boundary tie-break"
git push origin main
```

---

### Task 4: Island caret round-trip (island UTF-16 ↔ document byte)

**Files:**
- Create: `Sources/QuoinEditorKit/IslandCaretMapping.swift`
- Test: `Tests/QuoinEditorKitTests/IslandCaretMappingTests.swift`

**Interfaces:**
- Consumes: `UTF8IndexMap`, `IslandUnit`.
- Produces:
  ```swift
  public enum IslandCaretMapping {
      // island-local UTF-16 caret (from NSTextView.selectedRange().location) → absolute document byte offset
      public static func documentByte(localUTF16 caret: Int, islandSource: String, islandByteStart: Int) -> Int?
      // absolute document byte offset → island-local UTF-16 (to re-seed the caret after reconcile)
      public static func localUTF16(documentByte offset: Int, islandSource: String, islandByteStart: Int) -> Int?
  }
  ```

- [ ] **Step 1: Write the failing test** — for `islandSource = "a😀b"` (bytes: a=1, 😀=4, b=1; UTF-16: a=1,😀=2,b=1) at `islandByteStart = 10`: local UTF-16 caret 0→byte 10; caret after "a" (1)→byte 11; caret after "😀" (3)→byte 15; caret at end (4)→byte 16; and the inverse round-trips. Mid-surrogate/mid-scalar returns nil.

- [ ] **Step 2: Run — verify it fails.**

- [ ] **Step 3: Implement** — thin composition over `UTF8IndexMap`: `documentByte = islandByteStart + UTF8IndexMap(islandSource).utf8(fromUTF16: caret)`; inverse via `utf16(fromUTF8: offset - islandByteStart)`. Return nil on out-of-range / non-boundary.

- [ ] **Step 4: Run — verify it passes.**

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/IslandCaretMapping.swift Tests/QuoinEditorKitTests/IslandCaretMappingTests.swift
git commit -m "Phase 2: island caret round-trip (island UTF-16 <-> document byte via UTF8IndexMap)"
git push origin main
```

---

### Task 5: `IslandController` + `SwapState` machine (the hardest task)

**Files:**
- Create: `Sources/QuoinEditorKit/IslandController.swift`
- Modify: `Sources/QuoinEditorKit/BlockRecyclerView.swift` (an `editingRow`/`editingBlockID` field gates `viewFor` to a `BlockEditorCell`; add a second reuse identifier)
- Test: `Tests/QuoinEditorKitTests/IslandControllerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor public final class IslandController {
      public enum SwapState: Equatable { case idle, pendingFlush(BlockID), swapping, blockedIME(BlockID) }
      public private(set) var state: SwapState
      public private(set) var activeIsland: IslandUnit?
      public init(recycler: BlockRecyclerView)
      // Activation intent (from the recycler click seam):
      public func activate(blockID: BlockID, localPoint: CGPoint, in document: QuoinDocument, baseRevision: Int)
      public func deactivate()                              // blur → flush + swap back to read
      public var onReconcile: ((ByteRange, String, _ islandUTF16Caret: Int) -> Void)?  // app installs → KEEP apply
      public var refuseWhileMarkedText: Bool                // true; the machine checks hasMarkedText
  }
  ```
- On `BlockRecyclerView`: `var editingBlockID: BlockID?` + a `blockEditorCellIdentifier`; `viewFor` returns a configured `BlockEditorCell` for that one row, `BlockRenderCell` otherwise; a `reloadEditingRow()` that `reloadData(forRowIndexes:)` for the row transitioning read↔edit; the editing row is EXCLUDED from `settledHeights`/heightRenderer sizing (its height comes from the live island layout, re-notified via `noteHeightOfRows` on `onTextDidChange`).

- THE SWAP (activate): if `hasMarkedText` on any current island → `blockedIME`, queue. Else: `pendingFlush` the old island (fire `onReconcile` for it), set `editingBlockID`, `reloadData(forRowIndexes:)` for that row → `viewFor` yields a `BlockEditorCell` seeded via `document.source.substring(in: block.range)`, make its `islandTextView` first responder, place the caret from `localPoint` (nearest line/column via the cell's layout; safe default: nearest-line-by-height then column-by-x). Mint the `IslandUnit` (Task 3, with `baseRevision`). Deactivate reverses it.

- [ ] **Step 1: Write the failing tests** — headless state-machine transitions on a real recycler in an offscreen window: `activate(block1)` → `state == .idle` after swap, `activeIsland?.originBlockID == block1`, exactly ONE row is a `BlockEditorCell` (assert via a recycler test hook `editingRowForTest`), `liveCells` recycling still bounded; `activate(block2)` while block1 active → block1 flushed (assert `onReconcile` fired for block1) then block2 active; a `blockedIME` case — with `hasMarkedText` stubbed true, `activate` parks in `.blockedIME` and does NOT swap. Use a test seam to simulate `hasMarkedText`.

- [ ] **Step 2: Run — verify it fails.**

- [ ] **Step 3: Implement** the state machine + the recycler `editingRow` gate. Keep it a pure-ish controller: it drives the recycler (reload one row, first responder, caret) and emits `onReconcile`; it does NOT call any session directly. Enforce the IME refusal. Ensure the read↔edit swap goes through `reloadData(forRowIndexes:)` (NOT hand-swapping the row view — that corrupts `settledHeights`/`rowByBlockID`).

- [ ] **Step 4: Run — verify it passes.**

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/IslandController.swift Sources/QuoinEditorKit/BlockRecyclerView.swift Tests/QuoinEditorKitTests/IslandControllerTests.swift
git commit -m "Phase 2: IslandController + SwapState — click promotes one row to an editable island (recycler-safe)"
git push origin main
```

---

### Task 6: Reconciliation — island text → document (debounced, KEEP path)

**Files:**
- Modify: `Sources/QuoinEditorKit/IslandController.swift`
- Test: `Tests/QuoinEditorKitTests/IslandReconcileTests.swift`

**Interfaces:**
- The controller debounces `onTextDidChange` (~200 ms; flush immediately on swap/deactivate/`hasMarkedText`-clear), builds `SourceEdit(range: ByteRange(activeIsland.byteRange), replacement: islandTextView.string)`, and fires `onReconcile(byteRange, newText, islandUTF16Caret)`. The app closure applies it and returns/produces the new document; the controller then **re-anchors** the island against the new document (re-run `BlockListModel`; if the origin block no longer maps 1:1 to a single block — a structural change from an interior `\n` — call `deactivate()` per the no-structural-ops rule) and re-seeds the caret via `IslandCaretMapping`.

- [ ] **Step 1: Write the failing test** — drive it with a stub `onReconcile` that applies the `SourceEdit` to a local `DocumentSession`/`EditorCore` and returns the new doc: type "X" into an island seeded from block[1], flush, assert `document.source` is spliced byte-exactly (the X lands in block[1]'s range, untouched regions identical), the `IslandUnit.id` is preserved when the block stays 1:1, and — for an interior `\n` that splits the block — the controller deactivates (state `.idle`, no active island) rather than editing across the split.

- [ ] **Step 2: Run — verify it fails.**

- [ ] **Step 3: Implement** the debounce + SourceEdit build + re-anchor + caret re-seed + the split→deactivate guard.

- [ ] **Step 4: Run — verify it passes.**

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/IslandController.swift Tests/QuoinEditorKitTests/IslandReconcileTests.swift
git commit -m "Phase 2: island reconciliation — debounced SourceEdit through the KEEP path; re-anchor; split->deactivate"
git push origin main
```

---

### Task 7: App wiring — `ReaderModel.reconcileIsland` + closure install + click→controller

**Files:**
- Modify: `App/macOS/Sources/ReaderModel.swift` (add KEEP method), `Sources/QuoinEditorKit/BlockRecyclerReaderView.swift` (own the IslandController; forward click→activate + install `onReconcile`), `App/macOS/Sources/ReaderScreen.swift` (pass the reconcile closure)
- Test: `Tests/QuoinEditorKitTests/IslandWiringTests.swift`

**Interfaces:**
- `ReaderModel.reconcileIsland(byteRange: ByteRange, replacement: String) async` — builds `SourceEdit`, calls `applyAbsolute(edit, caretUTF8: nil, actionName: .typing)` (the KEEP path; `caretUTF8: nil` skips projection caret), which bumps `rendered.revision` → the recycler refreshes via `updateNSView` (Phase 1). It does NOT touch `activateBlock`/`restoreCaret`.
- `BlockRecyclerReaderView` constructs/owns an `IslandController(recycler:)`, wires `recycler.onBlockClicked → controller.activate(...)`, and installs `controller.onReconcile = { range, text, _ in Task { await onReconcile(range, text) } }` where `onReconcile` is the closure passed from `ReaderScreen` (calls `model.reconcileIsland`).

- [ ] **Step 1: Write the failing test** — a SwiftUI-free drive of `BlockRecyclerReaderView.apply(to:coordinator:initial:)`: feed a document, simulate a click (via the recycler seam) → island activates; simulate typing + flush → the installed `onReconcile` fires with the right `(ByteRange, String)`; feed the reconciled document (new revision) → `setDocument` re-runs (recycler refreshes). Assert the closure payload + the revision-driven refresh.

- [ ] **Step 2: Run — verify it fails.**

- [ ] **Step 3: Implement** the `ReaderModel.reconcileIsland` KEEP method, the controller ownership + wiring in `BlockRecyclerReaderView`, and the `onReconcile` closure param threaded from `ReaderScreen` (only in the `useRecycler` branch — flag-off path unchanged).

- [ ] **Step 4: Run — full suite + app build.** `swift test` (UNPIPED) green; `cd App/macOS && xcodegen && xcodebuild ... build` BUILD SUCCEEDED.

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add App/macOS/Sources/ReaderModel.swift Sources/QuoinEditorKit/BlockRecyclerReaderView.swift App/macOS/Sources/ReaderScreen.swift Tests/QuoinEditorKitTests/IslandWiringTests.swift
git commit -m "Phase 2: wire island edits to ReaderModel.reconcileIsland (KEEP apply) via the recycler reader"
git push origin main
```

---

### Task 8: Harness repoint — the end-to-end gate (milestone)

**Files:**
- Modify: `Sources/QuoinEditorKit/EditorTestHarness.swift` (add `init(adopting:)`)
- Test: `Tests/QuoinEditorKitTests/IslandHarnessEndToEndTests.swift`

**Interfaces:**
- `EditorTestHarness.init(adopting textView: NSTextView, appliedRevision: @escaping () -> Int)` — skips window/stack construction; `textView` points at a live `BlockEditorCell.islandTextView`; all drivers (`type`/`pressReturn`/`pressBackspace`/`move`) + `quiesce`/`caretRect`/`assertInsertionBar` work unchanged against the real island.

- [ ] **Step 1: Write the failing end-to-end test** — stand up a recycler + IslandController in an offscreen window with a stub `onReconcile` applying edits to a local session; activate a block (island appears); `EditorTestHarness(adopting: cell.islandTextView, appliedRevision: …)`; `harness.type("Z")`; `harness.quiesce()`; flush; assert (a) `document.source` reflects the Z in that block's range, (b) `harness.assertInsertionBar(minHeight: 8)` — the caret is a real bar in the real island (the standing 2pt-dot gate, now on the actual edit path), (c) no residual marked text.

- [ ] **Step 2: Run — verify it fails.** `swift test --filter IslandHarnessEndToEndTests`.

- [ ] **Step 3: Implement** the adopting init.

- [ ] **Step 4: Run — verify it passes + full suite.**

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/EditorTestHarness.swift Tests/QuoinEditorKitTests/IslandHarnessEndToEndTests.swift
git commit -m "Phase 2: repoint EditorTestHarness at the real island — end-to-end edit gate"
git push origin main
```

---

## Final verification

- [ ] `swift test` full suite green (all new QuoinEditorKitTests + no existing test changed except additive); app builds.
- [ ] The end-to-end harness test drives the REAL island edit path (type → reconcile → document splice) with the insertion-bar gate passing — the "green-but-broken" failure mode is now impossible for within-block editing.
- [ ] Flag OFF ⇒ projection reader unchanged (`ReaderScreen` else-branch untouched; the only app change is the additive `reconcileIsland` method + the `useRecycler`-branch closure).
- [ ] **Manual (user, flag ON, `-QuoinEditorRecycler YES`):** click a paragraph → it becomes editable (real caret, a normal bar not a dot); type → text appears where the caret is, in that block; click another block → the first reconciles and the second becomes editable; a large doc stays smooth. Return inside a paragraph inserts a newline (does NOT yet split into a new block — that's Phase 3); if it would split, the island deactivates cleanly (no crash, no caret in the wrong place). IME composition (if testable) doesn't swap mid-composition.
- [ ] `Package.resolved` unchanged.

## Notes for the next phase

Phase 3 adds STRUCTURAL OPS: Return-split (a `\n` at a block boundary creates a new block and the caret follows into it, staying editable), Backspace-merge, and block selection + ⌘A-delete — consuming `ByteAnchor`/`BoundaryID`/`SelectionAnchorRange` (built in Phase 0, not yet used) for caret survival across the reparse. It also deletes the projection reader's `editableSlice`/blank-line-synthesis machinery and flips the flag default-on. The §13b/§13c carry-forwards (move()-ticks-revision decision; separator-memo textScale key; per-cell wordWrap) are resolved as the recycler becomes the default.
