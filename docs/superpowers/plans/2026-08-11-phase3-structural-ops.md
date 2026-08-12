# Phase 3 — Island Hardening + Structural Ops (Return-split / Backspace-merge) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the editable island solid for real prose editing — fix the parked async-race so the island survives its own reconcile order-independently; deactivate on blur; drain the IME retry — then add the structural ops that fix the ORIGINAL bugs: **Return at a block boundary creates a new block and the caret follows into it** (staying editable), **Backspace at block start merges with the previous block**, and list/quote Return continuation. Still behind the default-OFF `QuoinEditorRecycler` flag.

**Architecture:** Introduce one `IslandTextView: NSTextView` subclass — the missing seam for `resignFirstResponder` (blur) and `doCommandBy(insertNewline:/deleteBackward:)` (Return/Backspace interception), without clobbering the cell-owned `ChangeForwarder` delegate. The async-race fix re-anchors the editing row by the island's **stable start byte offset** (`BlockListModel.record(at:)`) instead of the mutating content-hash `BlockID`, making both racing writers idempotent. Return-split and Backspace-merge share ONE primitive: *apply a structural `SourceEdit` through the KEEP path, then re-activate the block containing the reconcile-time caret byte* — inverting Phase 2's split→teardown.

**Tech Stack:** Swift 5 (QuoinEditorKit), AppKit NSTextView subclass + view-based NSTableView, TextKit 2, XCTest offscreen. Spec: `docs/superpowers/specs/2026-08-11-editable-islands-design.md` §5, §10 Phase 3, §13d.

## Global Constraints

- macOS 14+. AppKit code `#if canImport(AppKit)`; QuoinEditorKit Swift 5. Links QuoinCore + QuoinRender only; the app closure (`onReconcile`) is the only bridge to `ReaderModel`.
- **Behind the default-OFF `QuoinEditorRecycler` flag.** Flag OFF ⇒ the projection reader is byte-for-byte unchanged (the only app-target change permitted is threading a caret into `ReaderModel.reconcileIsland`, additive; the `MarkdownReaderView` else-branch stays untouched). The flag-flip default-on + projection-RIP deletion is a SEPARATE later cutover, NOT this plan.
- **Byte-lossless** and the **empty-splice guard is sacred:** every structural edit computes its range from `BlockListModel` records; a nil/missing record must ABORT the edit, never splice an empty string (this is the data-loss failure mode Phase 2's flush guard was written against — see `IslandController.flushActiveIsland`).
- **Reuse the KEEP session path** (`onReconcile → ReaderModel.reconcileIsland → applyAbsolute(caretUTF8:nil)`); NEVER the RIP projection-caret machinery.
- **Refuse structural ops while `hasMarkedText()`** (IME) — same rule as Phase 2.
- Do NOT clobber `BlockEditorCell`'s `ChangeForwarder` delegate (drives `onTextDidChange`/height re-notify).
- No new third-party deps. Revert `Package.resolved` before each commit. Commit + push to `main` after each task with trailers:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_013hf6D4MU3MgzEXSY3qZXEv`.
- `swift test` (UNPIPED) full suite green throughout; app build green after any app-target touch.

## Reference anchors (verified, Phase-2 code)

- `Sources/QuoinEditorKit/BlockEditorCell.swift`: bare `private let textView: NSTextView` (:43, built :53); `ChangeForwarder` delegate (:48,70-71,134-137) — do NOT clobber.
- `Sources/QuoinEditorKit/IslandController.swift`: `reconcileNow` (:286 fires `onReconcile(range, text, caret)`), `applyReconciled` (re-anchor `reanchorEditing` :323; `record(at:)` :305; **split→`teardownIsland`** :306-309; live caret re-read :325 — unsafe after split; `IslandCaretMapping.documentByte` :326), `deactivate` (:178-186 flush+clear), `activate` (doc param :121-122; `.blockedIME` :125-130; `pendingIntent` declared :96 / assigned :126-127 / **never read**; `mintIsland(at: block.range.offset)` :150), `islandTextDidChange` `wasComposing` commit edge (:240-247), `currentHasMarkedText` (:372-375), `reconcileInFlight` (:70-77,274-277), `flushActiveIsland` bail guard (:200-214).
- `Sources/QuoinEditorKit/BlockRecyclerView.swift`: `updateDocumentPreservingEditing` (:262-296; guard `contains{$0.id==editID}` :263-267 → falls back to `setDocument`), `setDocument`→`clearEditingWithoutReload` (:224-238), `reanchorEditing` (:305-313; no-op when `oldID==newID` :306), `ClickReportingTableView` (overrides only `mouseDown` :665-673), `document` private (:66), NotificationCenter observer pattern (:215-217, deinit :165-167).
- `Sources/QuoinEditorKit/BlockRecyclerReaderView.swift`: `onReconcile` closure **drops the caret** `{ range, text, _ in … }` (:126-132); coordinator carries `document`/`baseRevision` (:202-204); `apply(initial:false)` (:151-166).
- `App/macOS/Sources/ReaderModel.swift`: `reconcileIsland(byteRange:replacement:)` (:1362-1367).
- `Sources/QuoinCore/ReturnSemantics.swift`: `mode(for: BlockKind) -> Mode` (:31-49): `.paragraphBreak/.listAware/.quoteAware/.tableRow/.verbatim` — a classifier only; marker-continuation text is net-new.
- `Sources/QuoinEditorKit/IslandCaretMapping.swift`: `documentByte(localUTF16:islandSource:islandByteStart:)` / `localUTF16(documentByte:…)`.
- `Sources/QuoinEditorKit/EditorTestHarness.swift`: `init(adopting:appliedRevision:)` (:59-64); `pressReturn` native `insertNewline` (:122-125); `pressBackspace` native (:127-130).

## File Structure

- `Sources/QuoinEditorKit/IslandTextView.swift` — NEW `NSTextView` subclass: `resignFirstResponder` hook + `doCommandBy` for Return/Backspace (hooks the controller).
- `Sources/QuoinEditorKit/BlockEditorCell.swift` (modify) — host `IslandTextView`; expose the hooks.
- `Sources/QuoinEditorKit/IslandController.swift` (modify) — blur→deactivate, IME drain, the re-activate-at-caret primitive, Return-split, Backspace-merge, list/quote continuation.
- `Sources/QuoinEditorKit/BlockRecyclerView.swift` (modify) — order-independent preserve (re-anchor by start offset); window-blur observe.
- `Sources/QuoinEditorKit/BlockRecyclerReaderView.swift` + `App/macOS/Sources/ReaderModel.swift` (modify) — thread the reconcile-time caret through.
- Tests under `Tests/QuoinEditorKitTests/`.

Task 4 (re-activate-at-caret primitive) is the hardest — it inverts Phase-2's split-safety and must derive the caret target from the reconcile-time byte, never a live re-read.

---

### Task 1: `IslandTextView` subclass + blur → deactivate

**Files:**
- Create: `Sources/QuoinEditorKit/IslandTextView.swift`
- Modify: `Sources/QuoinEditorKit/BlockEditorCell.swift` (host the subclass; expose hooks), `Sources/QuoinEditorKit/IslandController.swift` (wire blur → deactivate)
- Test: `Tests/QuoinEditorKitTests/IslandBlurTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor public final class IslandTextView: NSTextView {
      public var onResignFirstResponder: (() -> Void)?
      public var onInsertNewline: (() -> Bool)?      // return true to consume (Task 5); default nil → native
      public var onDeleteBackward: (() -> Bool)?     // return true to consume (Task 7); default nil → native
      // override resignFirstResponder() -> Bool { onResignFirstResponder?(); return super.resignFirstResponder() }
      // override doCommand(by:) — route insertNewline:/deleteBackward: through the hooks, else super
  }
  ```
- `BlockEditorCell.islandTextView` now returns the `IslandTextView` (same public type `NSTextView` to callers; internally the subclass). The `ChangeForwarder` delegate is UNCHANGED (blur/Return/Backspace are responder overrides, not delegate methods — no clobber).
- `IslandController` sets `cell.islandTextView`'s `onResignFirstResponder = { [weak self] in self?.deactivate() }` when it configures the island; and observes `NSWindow.didResignKeyNotification` to flush the active island.

- [ ] **Step 1: Write the failing test** (offscreen window; a second focusable view to steal first responder)

```swift
#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

@MainActor
final class IslandBlurTests: XCTestCase {
    func testResigningFirstResponderDeactivatesIsland() {
        // Stand up recycler + controller (mirror IslandControllerTests setup).
        let doc = MarkdownConverter.parse("First para.\n\nSecond para.")
        let recycler = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:640,height:400), styleMask:[.borderless], backing:.buffered, defer:false)
        let other = NSTextField(frame: .zero)   // a view to move first responder to
        let host = NSView(frame: NSRect(x:0,y:0,width:640,height:400)); host.addSubview(recycler); host.addSubview(other)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        recycler.frame = NSRect(x:0,y:0,width:640,height:360)
        recycler.setDocument(doc, contentWidth: 600); recycler.layoutSubtreeIfNeeded()
        let controller = IslandController(recycler: recycler)
        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)
        XCTAssertNotNil(controller.activeIsland)
        // Move first responder away → the island's resignFirstResponder fires → deactivate.
        window.makeFirstResponder(other)
        XCTAssertNil(controller.activeIsland, "resigning first responder deactivates the island")
        XCTAssertFalse(recycler.isEditingRow(0), "row swapped back to read-only")
    }
}
#endif
```
NOTE: confirm the real recycler/controller setup + test hooks (`isEditingRow`) from `IslandControllerTests.swift` and mirror them; adjust the fixture to whatever makes the first-responder handoff deterministic.

- [ ] **Step 2: Run — verify it fails.** `swift test --filter IslandBlurTests` → the island stays active (no blur seam yet).

- [ ] **Step 3: Implement** the `IslandTextView` subclass (override `resignFirstResponder()` to fire `onResignFirstResponder` then `super`; `doCommand(by:)` routing `insertNewline:`/`deleteBackward:` through the optional hooks, falling through to `super` when the hook is nil or returns false). Host it in `BlockEditorCell` (replace the bare `textView`). In `IslandController.activate`, set `onResignFirstResponder = { [weak self] in self?.deactivate() }` on the promoted cell's text view; add the `NSWindow.didResignKeyNotification` observer (flush the active island) and remove it in deinit. Keep the `ChangeForwarder` delegate assignment as-is.

- [ ] **Step 4: Run — verify it passes.** `swift test --filter IslandBlurTests` + prior island suites (`IslandControllerTests`, `BlockEditorCellTests`) green.

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/IslandTextView.swift Sources/QuoinEditorKit/BlockEditorCell.swift Sources/QuoinEditorKit/IslandController.swift Tests/QuoinEditorKitTests/IslandBlurTests.swift
git commit -m "Phase 3: IslandTextView subclass; blur (resignFirstResponder / window resign-key) deactivates the island"
git push origin main
```

---

### Task 2: Order-independent island preservation (fix the parked async race)

**Files:**
- Modify: `Sources/QuoinEditorKit/BlockRecyclerView.swift` (`updateDocumentPreservingEditing`), `Sources/QuoinEditorKit/BlockRecyclerReaderView.swift` (thread `islandStart`)
- Test: `Tests/QuoinEditorKitTests/IslandRefreshOrderTests.swift`

**Interfaces:**
- `BlockRecyclerView.updateDocumentPreservingEditing(_ document:contentWidth:islandStartByte: Int?)` — instead of locating the editing row by the (mutating) content-hash `_editingBlockID`, locate it by the island's STABLE start byte: `BlockListModel(document).record(at: islandStartByte)`. If found (and block count matches numberOfRows), re-point `_editingBlockID` + `liveEditorCell.blockID` to `record.blockID`, rebuild `rowByBlockID`, reload only non-editing rows, and KEEP the editing cell/first-responder/caret. This makes the refresh idempotent with `applyReconciled` regardless of order.
- The coordinator threads the active island's `byteRange.lowerBound` (from `IslandController.activeIsland`) into `apply`.

- [ ] **Step 1: Write the failing test** — the both-orders gate. Drive the real refresh in BOTH orders and assert the island survives:

```swift
#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

@MainActor
final class IslandRefreshOrderTests: XCTestCase {
    // Simulate: reconcile produced a NEW document (block content changed → new content-hash id).
    // Refresh runs BEFORE applyReconciled re-anchors (the losing race). Island must survive.
    func testRefreshBeforeReanchorPreservesIsland() {
        let doc0 = MarkdownConverter.parse("Alpha.\n\nBravo.")
        let recycler = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:640,height:400), styleMask:[.borderless], backing:.buffered, defer:false)
        window.contentView = recycler; window.makeKeyAndOrderFront(nil); recycler.frame = NSRect(x:0,y:0,width:640,height:400)
        recycler.setDocument(doc0, contentWidth: 600); recycler.layoutSubtreeIfNeeded()
        let controller = IslandController(recycler: recycler)
        let start = doc0.blocks[0].range.offset   // island start byte (stable)
        controller.activate(blockID: doc0.blocks[0].id, localPoint: .zero, in: doc0, baseRevision: 0)
        // The edited doc: "Alpha." -> "AlphaX." (block[0] content-hash id CHANGES).
        let doc1 = MarkdownConverter.parse("AlphaX.\n\nBravo.")
        // Refresh FIRST (before any applyReconciled), located by island start byte:
        recycler.updateDocumentPreservingEditing(doc1, contentWidth: 600, islandStartByte: start)
        XCTAssertTrue(recycler.isEditingRow(0), "editing row preserved via start-byte re-anchor, not stale id")
        XCTAssertEqual(recycler.currentEditorCell?.blockID, doc1.blocks[0].id, "editing id re-pointed to the new content-hash id")
    }
}
#endif
```

- [ ] **Step 2: Run — verify it fails.** With the current id-equality guard, `doc1` doesn't contain the old id → falls back to `setDocument` → `isEditingRow(0)` is false.

- [ ] **Step 3: Implement** the start-byte re-anchor in `updateDocumentPreservingEditing` (fold `reanchorEditing`'s body into the preserve path; keep the `_editingBlockID == nil` early fall-through to `setDocument` so the read-only/flag-off path is byte-identical). Thread `islandStartByte` from the coordinator (`activeIsland?.byteRange.lowerBound`).

- [ ] **Step 4: Run — verify it passes + the Phase-2 survival test still green.** `swift test --filter IslandRefreshOrderTests` and `swift test --filter IslandRefreshSurvivalTests` and the island suites.

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/BlockRecyclerView.swift Sources/QuoinEditorKit/BlockRecyclerReaderView.swift Tests/QuoinEditorKitTests/IslandRefreshOrderTests.swift
git commit -m "Phase 3: order-independent island preservation — re-anchor the editing row by stable start byte, not content-hash id"
git push origin main
```

---

### Task 3: IME-retry drain

**Files:**
- Modify: `Sources/QuoinEditorKit/IslandController.swift`
- Test: `Tests/QuoinEditorKitTests/IslandIMEDrainTests.swift`

**Interfaces:**
- The parked `pendingIntent` (set on `.blockedIME` in `activate`) is DRAINED when marked text clears — in the `wasComposing` commit edge of `islandTextDidChange` (`IslandController.swift:240-247`): after the flush, if `pendingIntent != nil`, replay `activate(...)` from the parked intent and clear it. Store the intent as a small struct `{ blockID; localPoint; document; baseRevision }`.

- [ ] **Step 1: Write the failing test** — with a `hasMarkedText` test seam (the controller already has `currentHasMarkedText` overridable/injectable per Task-5 Phase-2 pattern): activate block A; begin "composition" (stub `hasMarkedText` true); `activate(block B)` → parks in `.blockedIME`, no swap; clear composition + fire the commit edge → the parked activation for B runs (island B active, A flushed).

- [ ] **Step 2: Run — verify it fails.** The parked intent is never drained today.

- [ ] **Step 3: Implement** the drain in the commit edge. Guard against re-entrancy (clear `pendingIntent` before replaying).

- [ ] **Step 4: Run — verify it passes** + island suites green.

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/IslandController.swift Tests/QuoinEditorKitTests/IslandIMEDrainTests.swift
git commit -m "Phase 3: drain the parked IME activation intent when marked text clears"
git push origin main
```

---

### Task 4: The re-activate-at-caret primitive (the hardest task)

**Files:**
- Modify: `Sources/QuoinEditorKit/IslandController.swift` (`applyReconciled` split branch; thread the reconcile-time caret), `Sources/QuoinEditorKit/BlockRecyclerReaderView.swift` (undo the caret drop), `App/macOS/Sources/ReaderModel.swift` (thread caret — additive)
- Test: `Tests/QuoinEditorKitTests/IslandReactivateAtCaretTests.swift`

**Interfaces:**
- Thread the **reconcile-time caret** end to end: `onReconcile(range, text, caret)` no longer drops `caret` (`BlockRecyclerReaderView.swift:126` `{ range, text, caret in }`); the app applies + returns the new doc; the controller's `applyReconciled(newDocument, caretDocByte:)` receives the absolute caret byte.
- `caretDocByte = island.byteRange.lowerBound + UTF8IndexMap(flushedText).utf8(fromUTF16: caret)` — computed at flush time (bytes before the caret don't move), NOT from a live `textView.selectedRange()` (the cell may be gone after a split).
- `applyReconciled` split branch changes from "no 1:1 → `teardownIsland`" to: `let rec = BlockListModel(newDocument).record(at: caretDocByte)`; if `rec != nil`, **re-activate** the caret's block — re-anchor the island onto `rec` (`reanchorEditing`), re-seed the island cell's source from `rec`'s bytes, and seat the caret via `IslandCaretMapping.localUTF16(documentByte: caretDocByte, islandSource: rec source, islandByteStart: rec.byteRange.lowerBound)`. If `rec == nil` (caret in a separator gap — shouldn't happen for a real caret) → `teardownIsland` (safe fallback). NEVER splice; this only re-anchors + re-seeds the view.
- KEEP path (no split): unchanged 1:1 re-anchor (still uses `caretDocByte` for the caret re-seed instead of the live re-read at :325).

- [ ] **Step 1: Write the failing test** — drive a stub `onReconcile` that applies to a local session and hands back the new doc + calls `applyReconciled(newDoc, caretDocByte:)`. Type a mid-paragraph `\n\n` into an island seeded from block[1] (source "Hello world.") splitting it into two paragraphs; assert the controller stays active (state not idle), the island re-anchored to the block CONTAINING the caret (the second paragraph), and the caret is at that block's start — NOT torn down. Also a KEEP case (type "X", no split) still re-anchors 1:1 with the caret preserved.

- [ ] **Step 2: Run — verify it fails.** Today the split path tears down (`teardownIsland`).

- [ ] **Step 3: Implement** — thread the caret; compute `caretDocByte` at flush; rewrite the `applyReconciled` split branch to re-activate at the caret's block; keep the empty-splice-proof property (this branch does no `onReconcile`/splice, only re-anchor + re-seed the view). Compose with `reconcileInFlight` (clear it as today).

- [ ] **Step 4: Run — verify it passes** + island suites + `IslandRefreshSurvivalTests` + full `swift test`.

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/IslandController.swift Sources/QuoinEditorKit/BlockRecyclerReaderView.swift App/macOS/Sources/ReaderModel.swift Tests/QuoinEditorKitTests/IslandReactivateAtCaretTests.swift
git commit -m "Phase 3: re-activate-at-caret primitive — a split re-homes the island into the caret's new block (no teardown)"
git push origin main
```

---

### Task 5: Return-split (Return creates a new block, caret follows)

**Files:**
- Modify: `Sources/QuoinEditorKit/IslandTextView.swift` (wire `onInsertNewline`), `Sources/QuoinEditorKit/IslandController.swift` (Return handling)
- Test: `Tests/QuoinEditorKitTests/IslandReturnSplitTests.swift`

**Interfaces:**
- The island's `IslandTextView.onInsertNewline` returns true (consume) and asks the controller to handle Return per `ReturnSemantics.mode(for: island block kind)`. For `.paragraphBreak` (paragraph/heading): insert `\n\n` at the caret in the island source (native `insertText`), then the debounce reconcile + Task-4 primitive re-homes the island into the caret's new block. For `.verbatim` (code/etc.): insert a plain `\n` (native). List/quote are Task 6. Refuse (fall through to native / no-op) while `hasMarkedText()`.
- The controller needs the island's block kind — carry it (`BlockRecord.kind`, threaded at activate).

- [ ] **Step 1: Write the failing test** — end-to-end through the harness + a stub session: activate a paragraph "Hello", caret at end, `harness.pressReturn()` (now routed through `onInsertNewline`), flush; assert the document now has TWO blocks ("Hello" + an empty paragraph), the island is active on the SECOND (new) block with the caret at its start, and typing "X" lands in the new block ("Hello\n\nX"). This is the exact original bug (Return at end of a heading/paragraph), now correct.

- [ ] **Step 2: Run — verify it fails.** Today `pressReturn` is native → a plain `\n` → soft break, not a split with caret-follow.

- [ ] **Step 3: Implement** — wire `onInsertNewline` → controller Return handler → per-mode insertion (paragraphBreak `\n\n`, verbatim `\n`); the Task-4 primitive does the caret-follow. Update the harness `pressReturn` note if needed (it drives the real view; the override now consumes).

- [ ] **Step 4: Run — verify it passes** + full suite.

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/IslandTextView.swift Sources/QuoinEditorKit/IslandController.swift Tests/QuoinEditorKitTests/IslandReturnSplitTests.swift
git commit -m "Phase 3: Return-split — Return at a prose boundary creates a new block; the caret follows into it"
git push origin main
```

---

### Task 6: List / quote Return continuation + empty-item-exit

**Files:**
- Modify: `Sources/QuoinEditorKit/IslandController.swift` (list/quote Return), possibly a new `Sources/QuoinEditorKit/ListContinuation.swift` (pure marker logic)
- Test: `Tests/QuoinEditorKitTests/IslandListReturnTests.swift`

**Interfaces:**
- Pure marker logic (net-new; `ReturnSemantics` only classifies): given the current island line, compute the continuation. `.listAware`: non-empty item → insert `\n` + the same marker/indent (`- `, `1. `→`2. `, nested indent); empty item (marker only) → delete the marker (exit to paragraph). `.quoteAware`: continue `> ` prefix; empty quoted line → exit. Put the marker parsing in a pure, unit-tested helper.

- [ ] **Step 1: Write the failing tests** (pure + end-to-end): a pure test of the marker continuation (`"- item"` → `"\n- "`, `"1. item"` → `"\n2. "`, `"- "` empty → exit); an end-to-end test: island on a list block, caret at end of a non-empty item, Return → a new item with the marker; Return on an empty item → exits the list.

- [ ] **Step 2: Run — verify it fails.**

- [ ] **Step 3: Implement** the pure marker helper + wire it into the controller's Return handler for `.listAware`/`.quoteAware`.

- [ ] **Step 4: Run — verify it passes** + full suite.

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/ListContinuation.swift Sources/QuoinEditorKit/IslandController.swift Tests/QuoinEditorKitTests/IslandListReturnTests.swift
git commit -m "Phase 3: list/quote Return continuation + empty-item-exits-list"
git push origin main
```

---

### Task 7: Backspace-merge (Backspace at block start merges with the previous block)

**Files:**
- Modify: `Sources/QuoinEditorKit/IslandTextView.swift` (wire `onDeleteBackward`), `Sources/QuoinEditorKit/IslandController.swift` (merge handling; thread current-document access)
- Test: `Tests/QuoinEditorKitTests/IslandBackspaceMergeTests.swift`

**Interfaces:**
- `IslandTextView.onDeleteBackward` returns true (consume) ONLY when `selectedRange() == {0,0}` (caret at island start, no selection) AND the controller confirms a previous block exists; otherwise returns false → native delete. The controller needs the current document (thread it — mirror how `onBlockClicked` reads `coordinator.document`, or have the controller retain the last activate/reconcile document). Compute the merge: predecessor = `BlockListModel(document)` record whose range ends before the island start; if present, the edit range = `[prevRecord.byteRange.upperBound, island.byteRange.lowerBound)` (the inter-block separator) replaced by `""` (or a single `\n` join per the block kinds — start with `""` i.e. join into one block; document the rule). Route through the KEEP `onReconcile`/`reconcileIsland` path; the caret target byte = `prevRecord.byteRange.lowerBound + prevContentLength` (the join point); Task-4 primitive re-homes the island onto the merged block with the caret at the join. If no predecessor → return false (native no-op). NEVER splice with a nil record.

- [ ] **Step 1: Write the failing test** — end-to-end: doc "First\n\nSecond", activate "Second", caret at offset 0, `harness.pressBackspace()` (routed through `onDeleteBackward`), flush; assert the document merged to "FirstSecond" (one block, or "First\nSecond" per the chosen join rule — assert the exact rule), the island is active on the merged block, and the caret is at the join (offset 5, after "First"). Plus a counter-test: Backspace NOT at offset 0 does a normal within-island delete (returns false → native).

- [ ] **Step 2: Run — verify it fails.** Today `deleteBackward` at offset 0 is a native no-op (nothing before the island text).

- [ ] **Step 3: Implement** the merge: thread document access, the caret-at-0 + previous-block detection, the separator-delete `SourceEdit` through KEEP, the Task-4 re-home with caret at the join, and the empty-splice guard (nil predecessor → native no-op, never a splice).

- [ ] **Step 4: Run — verify it passes** + full `swift test` + app build (you touched ReaderModel in Task 4; confirm the app still builds).

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/IslandTextView.swift Sources/QuoinEditorKit/IslandController.swift Tests/QuoinEditorKitTests/IslandBackspaceMergeTests.swift
git commit -m "Phase 3: Backspace-merge — Backspace at block start merges with the previous block, caret at the join"
git push origin main
```

---

## Final verification

- [ ] `swift test` full suite green (all new island tests + no existing test broken except additive changes); app builds.
- [ ] **The original bugs are fixed, by test:** Return at the end of a heading/paragraph creates a new block with the caret in it (`IslandReturnSplitTests`); typing lands in the right block; Backspace at block start merges (`IslandBackspaceMergeTests`); the island survives its own reconcile in both orders (`IslandRefreshOrderTests`); blur deactivates cleanly (`IslandBlurTests`). The insertion-bar gate (`assertInsertionBar`) still passes on the real island through these ops.
- [ ] Flag OFF ⇒ projection reader unchanged (only additive `reconcileIsland` caret param + QuoinEditorKit changes).
- [ ] **Manual (user, flag ON, `-QuoinEditorRecycler YES`):** click a paragraph, type, press Return → a new paragraph appears and the caret is in it; keep typing → lands there; Backspace at a line start merges up; click away → the block reconciles and goes read-only cleanly (no drop-to-read-only mid-edit, no data loss). Judge zoomed.
- [ ] `Package.resolved` unchanged.

## Notes for the next steps

Deferred to **Phase 3b** (a separate focused plan): block selection — `SelectedBlockRange { anchor: BlockID; focus: BlockID }` + a `Set<BlockID>` model + overlay draw; ⌘A selects all blocks, Shift-click/Shift-arrow extends, Delete removes (contiguous byte-range `SourceEdit` through KEEP), copy assembles bytes; entering selection deactivates the island; lower `SelectedBlockRange → SelectionAnchorRange` via `BoundaryID.blockStart/blockEnd` (finally consuming the Phase-0 anchors). Then the **cutover** (a separate, explicitly user-gated step): flip `QuoinEditorRecycler` default-on and delete the projection RIP machinery (`editableSlice`/blank-line synthesis/`caretMapping`/reveal clamps + the RIP parts of `ReaderCoordinator`/`ReaderModel`), resolving all §13b/§13c/§13d carry-forwards. That cutover needs the user's explicit sign-off after validating the recycler editor.
