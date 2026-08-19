# Tree-as-truth Phase 2 — the live editor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Phase-1 `EditableDocument` tree the live editing truth behind a single macOS `NSTextView`, so Return/Backspace/typing/undo are structural tree operations with no document byte offsets on the interaction path — killing the Return-does-nothing / Backspace-eats-a-character bug class at its root.

**Architecture:** One `NSTextView` backed by the **stock** `NSTextContentStorage`. The tree is the truth; the storage is a write-only downstream projection the tree patches with **strictly-structural** updates (re-project only the changed block's storage range; caret is `EditPosition(NodeID, offsetUTF16)` mapped to a storage offset by per-element length bookkeeping). No byte-diff reconcile, no markdown-string round-trip on the edit path. `DocumentSession` narrows to persistence; its bridge is crossed on edit-commit (dirty), save, and external change only. A new `QuoinTreeEditor` flag is a **temporary development scaffold** to build parity behind; Phase 2 ends by making the tree editor the SOLE editor and DELETING the monolith, the island recycler view layer, the interim guard, and the flag.

**Product stance (governs this whole plan):** Quoin has **no installed base**. Breaking changes are free, and clearing accumulated clutter to rebuild fresh is always preferred over preserving/patching old code. So Phase 2 does not ship two coexisting paths and does not defer removal to a later "cutover phase" — it replaces and deletes.

**Tech Stack:** Swift 6 (QuoinCore) / Swift 5 (QuoinRender AppKit), TextKit 2 (`NSTextContentStorage`/`NSTextLayoutManager`/`NSTextView`), swift-markdown/cmark-gfm, `EditableDocument` (Phase 1), `EditMapping` (QuoinCore), `NSUndoManager`.

**Spec:** `docs/superpowers/specs/2026-08-19-tree-as-truth-phase2-design-v4.md` (READY TO PLAN; four review rounds + a code-grounded wiring verification). Read it alongside this plan — the plan argues from it. Its lineage (v1→v4) and the master spec `2026-08-19-tree-as-truth-editing-design.md` carry the rationale.

## Global Constraints

- **No document byte offset and no byte-`SourceEdit` reconcile on the interaction path.** The caret is always `EditPosition(NodeID, offsetUTF16-in-block.text)`. `EditMapping.sourceOffset` is used ONLY for the activation click (rendered→source), never on the typing/structural path. Any task reintroducing a document-byte caret or a diff-back-to-string reconcile is wrong by construction.
- **Storage is a projection, not a truth.** After any tree transform, the storage patch re-projects only the changed block range(s); the markdown string is produced only by `serialized()` on save.
- **Byte-lossless for untouched regions** (Phase-1 serializer property) must hold through every save path added here.
- **Two recognizers must agree**: the storage substring displayed for a block MUST be byte-identical to the `renderedText` passed to `EditMapping` — both come from the one whole-document projection, never a second parse. (CLAUDE.md two-recognizer-divergence rule.)
- **Viewport invariant** (user directive): on any projection change, the caret/click line must not move on screen; edit mode keeps the block's vertical skeleton. Enforced by RevealFidelityTests / CaretLineAnchorTests — extend BOTH for the tree path. Patch-vs-full-render equivalence via ProjectorEquivalenceTests — extend when touching a projection path.
- **Swift 6 modules** (QuoinCore, macOS app target, QuoinUITests) stay warning-clean under strict concurrency; QuoinRender is Swift 5. Language mode is per-module.
- **Dependency policy**: no new third-party dependency. swift-markdown only.
- **No installed base — Phase 2 REPLACES the monolith, it does not coexist with it.** The `QuoinTreeEditor` flag is a *temporary development scaffold* so Tasks 1–10 build the tree path and prove parity against the still-present monolith (the parity oracle, whose `AttributedRenderer` the tree reuses). Don't gratuitously break the monolith mid-development (it's the oracle), but the Phase-2 END STATE is: the tree editor is the SOLE editor, and the monolith reader path, the island recycler view layer (`QuoinEditorKit`), the interim guard (`ReaderCoordinator.caretStrandedAboveBlankLine`), the now-dead `DocumentSession` edit machinery, and the flag itself are all DELETED (Tasks 11–12). Clearing this clutter is Phase 2, not a deferred phase.
- **Commit and push after every task, to `main`** is the repo norm, BUT this plan runs in a worktree/branch under subagent-driven-development; commit per task on the branch and integrate at the end via finishing-a-development-branch. Do not push to `main` mid-plan.

---

## File Structure

New code lives in `Sources/QuoinRender/AppKit/TreeEditor/` (Swift 5, AppKit/TextKit) plus small additive APIs in `Sources/QuoinCore` (Swift 6, Linux-testable).

- **Create** `Sources/QuoinCore/DocumentSession+TreePersistence.swift` — the two additive session APIs: `noteInMemoryEdit()` (GAP 1) and `saveTreeSource(_:)` (GAP 2 write side). Kept in one file so the narrow persistence bridge is reviewable as a unit.
- **Create** `Sources/QuoinCore/EditableDocument/DefinitionScanner.swift` — pure trivia definition-pattern detector (GAP 4): does a trivia string contain a link-reference or footnote definition?
- **Create** `Sources/QuoinRender/AppKit/TreeEditor/TreeTextController.swift` — owns the `EditableDocument`, the single `NSTextView`, the projection + per-element length bookkeeping, the structural patch. The heart of Phase 2.
- **Create** `Sources/QuoinRender/AppKit/TreeEditor/TreeProjection.swift` — pure-ish mapping between the tree and the projected attributed string + element length table (structural offset ⇄ storage offset).
- **Create** `Sources/QuoinRender/AppKit/TreeEditor/TreeUndoStack.swift` — snapshot stack + coalescing predicate + `NSUndoManager` registration.
- **Create** `Sources/QuoinRender/AppKit/TreeEditor/TreeEditorView.swift` — the SwiftUI/NSViewRepresentable wrapper mounted behind the `QuoinTreeEditor` flag (mirrors `MarkdownReaderView`'s mounting seam).
- **Modify** the flag site (wherever `useRecycler`/`QuoinEditorRecycler` is read — `App/macOS/Sources/ReaderScreen.swift:50`) to add `QuoinTreeEditor` selection.
- **Test** `Tests/QuoinCoreTests/TreePersistenceTests.swift`, `Tests/QuoinCoreTests/DefinitionScannerTests.swift` (Linux-testable), and `Tests/QuoinRenderTests/TreeEditor/*` (AppKit offscreen, `EditorTestHarness`/`OffscreenTestWindow` pattern).

---

## Task 1: SPIKE — tree drives the stock storage (GO/NO-GO GATE)

**This task is a spike. Its deliverable is a proven-or-disproven hypothesis plus the invariant tests, not polished production code.** If its gate fails, STOP and report — do not proceed to Task 4+. The design's viability rests here.

**Hypothesis:** A `TreeTextController` can own an `EditableDocument`, project it into one `NSTextView`'s stock `NSTextContentStorage`, and apply a single-block **structural re-projection patch** (`storage.replaceCharacters(in: blockRange, with: reprojected)`) while preserving the caret-line settle and decoration-run invariants — and an empty tree block projects to a real caret line.

**Files:**
- Create: `Sources/QuoinRender/AppKit/TreeEditor/TreeTextController.swift` (spike scope: projection + length bookkeeping + one patch entry point)
- Create: `Sources/QuoinRender/AppKit/TreeEditor/TreeProjection.swift`
- Test: `Tests/QuoinRenderTests/TreeEditor/TreeProjectionSpikeTests.swift`

**Interfaces:**
- Consumes: `EditableDocument` (`Sources/QuoinCore/EditableDocument/EditableDocument.swift` — `segments: [Segment]`, `Segment.block(EditableBlock)`/`.trivia(String)`, `EditableBlock{id,kind,text}`), `AttributedRenderer` (rendered projection of a block), `MarkdownSourceStyler` (source styling of a block).
- Produces (the interfaces later tasks rely on — keep these signatures stable):
  - `final class TreeTextController` with:
    - `init(document: EditableDocument, textView: NSTextView)`
    - `func projectAll()` — full projection into the storage; rebuilds the element length table.
    - `func storageRange(ofBlock id: NodeID) -> NSRange` — from the length table.
    - `func storageOffset(of pos: EditPosition) -> Int` — `Σ preceding element UTF-16 lengths + pos.offsetUTF16`.
    - `func editPosition(atStorageOffset o: Int) -> EditPosition?` — inverse.
    - `func reproject(block id: NodeID, active: Bool)` — the structural patch: re-render just that block's range (rendered if `active==false`, source-styled if `active==true`) and update the length table.
  - `struct TreeProjection` holding the per-element length table `[(id: NodeID, length: Int)]` and the concatenated `NSAttributedString`.

**Success criteria (the GATE — all must pass):**

- [ ] **Step 1: Write the projection-equivalence test.** In `TreeProjectionSpikeTests.swift`, build an `EditableDocument` from the kitchen-sink fixture used by existing projection tests (find it via `AttributedRenderer` tests; reuse the same source string). Assert the controller's `projectAll()` storage `.string` equals the monolith's `AttributedRenderer` full-document rendered `.string` for the same source (content equality; the tree path must render identical text).

```swift
func testTreeProjectionMatchesMonolithRenderedString() {
    let source = Fixtures.kitchenSink            // reuse the existing fixture source
    let doc = EditableDocument.build(parsing: source)
    let tv = OffscreenTestWindow.makeTextView()  // stock NSTextContentStorage
    let controller = TreeTextController(document: doc, textView: tv)
    controller.projectAll()
    let monolith = AttributedRenderer().render(MarkdownConverter.parse(source)) // existing API
    XCTAssertEqual(tv.textContentStorage!.textStorage!.string, monolith.string)
}
```

- [ ] **Step 2: Run it; confirm it fails** (controller not implemented). Expected: build/assert failure.
- [ ] **Step 3: Implement `projectAll()` + the length table** (rendered projection per block; trivia projected inertly). Minimal — enough to pass Step 1.
- [ ] **Step 4: Run Step 1; confirm pass.**
- [ ] **Step 5: Write the empty-block caret-line test.** Build a doc whose middle block is empty (`EditableDocument.build(parsing: "# H\n\n\nx")` yields an empty paragraph, or construct via `splitBlock`), project it, and assert the empty block occupies a layout line: `storageRange(ofBlock:)` is a valid caret location and the layout produces a fragment for it (measure via `NSTextLayoutManager.enumerateTextLayoutFragments` that a fragment exists at that element's offset with non-zero height).
- [ ] **Step 6: Run; implement until pass** (this is the empty-element gamble the design flags — if AppKit collapses the empty line and NO reasonable projection makes it a caret line, that is a NO-GO; record it and STOP).
- [ ] **Step 7: Write the structural-patch invariant test.** Project the doc, record (a) the caret-line screen Y for a caret in block K (via the monolith's `caretLineScreenY` equivalent on this text view) and (b) the decoration run list discovered by `enumerateAttribute(QuoinAttribute.blockDecoration…)` over the storage. Call `reproject(block: J, active: false)` for a DIFFERENT block J whose re-render changes its length. Assert: the caret-line screen Y for block K is unchanged (settle invariant) and the decoration run list is still discoverable and correct for unaffected blocks.

```swift
func testStructuralPatchPreservesSettleAndDecorations() {
    // project; capture caretLineScreenY(forBlock: K) and decorationRuns()
    // reproject(block: J != K, active: false) with a length-changing restyle
    // assert caretLineScreenY(forBlock: K) unchanged; decorationRuns() intact
}
```

- [ ] **Step 8: Run; implement `reproject` until pass.** This proves the storage-facing machinery (settle + decoration discovery over `textContentStorage.textStorage`) survives a mid-document structural patch.
- [ ] **Step 9: GATE DECISION.** All three (projection-equivalence, empty-block caret line, structural-patch invariants) green ⇒ **GO**, record in the ledger and proceed. Any red that cannot be made green without abandoning the stock-storage approach ⇒ **NO-GO**: record the exact failure and STOP for a design revisit (the fallback is the custom-backend approach or a different projection granularity — a design decision, not an implementer ruling).
- [ ] **Step 10: Commit** (`spike: tree→stock-storage projection + structural patch — GATE <GO|NO-GO>`).

---

## Task 2: `DocumentSession` tree-persistence APIs (GAP 1 + GAP 2 write side)

**Files:**
- Create: `Sources/QuoinCore/DocumentSession+TreePersistence.swift`
- Test: `Tests/QuoinCoreTests/TreePersistenceTests.swift`

**Interfaces:**
- Consumes: `DocumentSession` (actor) internals — `scheduleAutosave()` (private, `DocumentSession.swift:810`), `writeToDisk(_:to:)` (private, `:924`), `selfWriteHash` (`:74`), `QuoinDocument.sourceHash` (`Model.swift:288`).
- Produces: `func noteInMemoryEdit()` and `func saveTreeSource(_ source: String) throws` on `DocumentSession`.

Rationale (verified against real code): `isDirty` is set only inside `scheduleAutosave()`, reachable only from `applyEdit`/`undo`/`redo` — all bypassed by the tree path. Without a dirty signal, an external file change silently discards unsaved tree edits. And `saveNow()` writes `document.source` (not an arbitrary tree-serialized string) — there is no public API to write a tree string while stamping `selfWriteHash`, though `writeToDisk` (used by `toggleTask`, `:998`) is the proven primitive.

- [ ] **Step 1: Write the dirty-signal test.**

```swift
func testNoteInMemoryEditMarksDirtyWithoutRevisionBump() async throws {
    let session = DocumentSession(source: "hello\n")
    let rev0 = await session.contentRevision
    await session.noteInMemoryEdit()
    XCTAssertTrue(await session.isDirty)
    XCTAssertEqual(await session.contentRevision, rev0)   // no bump ⇒ staleEditBase unaffected
}
```

- [ ] **Step 2: Run; confirm fail** (method missing).
- [ ] **Step 3: Implement `noteInMemoryEdit()`** — calls `scheduleAutosave()`; touches nothing else.

```swift
extension DocumentSession {
    /// The tree path owns edits and never calls applyEdit; this keeps the session dirty
    /// so external-change/conflict handling and autosave still fire. No revision bump
    /// (staleEditBase is never consulted on the tree path) and no undo-stack mutation.
    public func noteInMemoryEdit() { scheduleAutosave() }
}
```

- [ ] **Step 4: Run; confirm pass.**
- [ ] **Step 5: Write the self-stamped save test.**

```swift
func testSaveTreeSourceWritesAndStampsSelfWriteHash() async throws {
    let url = TempFile.make(contents: "old\n")
    let session = try DocumentSession.open(fileURL: url)
    try await session.saveTreeSource("new tree bytes\n")
    XCTAssertEqual(try String(contentsOf: url), "new tree bytes\n")   // arbitrary source written
    // a subsequent reloadFromDisk of the same bytes is recognized as a self-write (no clobber):
    // assert the session does NOT flag an external change for bytes whose hash == the just-written hash
}
```

- [ ] **Step 6: Run; confirm fail.**
- [ ] **Step 7: Implement `saveTreeSource(_:)`** — write the arbitrary source via the `writeToDisk` primitive so `selfWriteHash` is stamped (mirror `toggleTask`'s pattern at `:998-1020`); clear dirty on success. Do NOT route through `adoptExternal`/`apply(source:)` (which publishes an un-stamped adopt). Follow the exact `writeToDisk` signature and error handling in `DocumentSession.swift:924-944` and `saveNow()` at `:868-897`.
- [ ] **Step 8: Run; confirm pass.** Verify no Swift 6 concurrency warnings (QuoinCore is strict-concurrency).
- [ ] **Step 9: Commit** (`feat(core): DocumentSession.noteInMemoryEdit + saveTreeSource for the tree persistence bridge`).

---

## Task 3: Trivia definition-pattern scanner (GAP 4)

**Files:**
- Create: `Sources/QuoinCore/EditableDocument/DefinitionScanner.swift`
- Test: `Tests/QuoinCoreTests/DefinitionScannerTests.swift`

**Interfaces:**
- Produces: `enum DefinitionScanner { static func containsDefinition(_ trivia: String) -> Bool }` — true if a trivia string contains a link-reference definition (`^\s*\[label\]:`) or a footnote definition (`^\s*\[^label\]:`) on any physical line.

Rationale (verified): link-ref and footnote definitions live in `.trivia` segments (never `.block`), but `Segment.trivia` is a flat undifferentiated `String`. Whole-document reproject (Task 9) must fire only when a *definition* trivia changed, not on incidental blank-line trivia — so the controller needs this content scan.

- [ ] **Step 1: Write the test matrix.**

```swift
func testDetectsLinkReferenceDefinition() {
    XCTAssertTrue(DefinitionScanner.containsDefinition("[ref]: https://example.com\n"))
    XCTAssertTrue(DefinitionScanner.containsDefinition("  [ref]: /path \"title\"\n"))
}
func testDetectsFootnoteDefinition() {
    XCTAssertTrue(DefinitionScanner.containsDefinition("[^note]: the text\n"))
}
func testIgnoresBlankAndPlainTrivia() {
    XCTAssertFalse(DefinitionScanner.containsDefinition("\n\n"))
    XCTAssertFalse(DefinitionScanner.containsDefinition("   \n"))
    XCTAssertFalse(DefinitionScanner.containsDefinition("not [a link] just text\n"))
}
func testCRLFLinesNormalized() {   // CLAUDE.md \r\n pitfall
    XCTAssertTrue(DefinitionScanner.containsDefinition("[ref]: x\r\n"))
}
```

- [ ] **Step 2: Run; confirm fail.**
- [ ] **Step 3: Implement `containsDefinition`** — normalize `\r\n`→`\n` first (CLAUDE.md pitfall), split into physical lines, return true if any line matches `^\s*\[\^?[^\]]+\]:\s` (footnote is the `\^` variant; both covered by the optional `\^`). Keep it a pure function, no cmark dependency.
- [ ] **Step 4: Run; confirm pass.**
- [ ] **Step 5: Commit** (`feat(core): trivia definition-pattern scanner for whole-doc reproject gating`).

---

## Task 4: Activation + source reveal via `EditMapping`

Depends on Task 1 GO. **This is the path review confirmed plannable on proven, tested code.**

**Files:**
- Modify: `Sources/QuoinRender/AppKit/TreeEditor/TreeTextController.swift` (add activation)
- Test: `Tests/QuoinRenderTests/TreeEditor/TreeActivationTests.swift`

**Interfaces:**
- Consumes: `EditMapping.sourceOffset(forRenderedOffset:renderedText:sourceText:)` (`SourceEdit.swift:121`); the length table + `reproject` from Task 1.
- Produces on `TreeTextController`:
  - `var activeBlock: NodeID?`
  - `func activate(blockAt storageOffset: Int)` — resolve the block, map the rendered click offset within that block to a source offset via `EditMapping`, `reproject(block:, active: true)`, set selection to `storageOffset(of: EditPosition(block, mappedSourceOffset))`.
  - `func deactivate()` — `reproject(activeBlock, active: false)`; (Task 9 adds re-kind).

**Invariant to enforce (Global Constraint):** the `renderedText` passed to `EditMapping` MUST be the exact storage substring displayed for that block (the projection's rendered run `.string` for that block), and `sourceText` is `block.text`. Never re-render a second copy.

- [ ] **Step 1: Write the heading-click coordinate test** — the field bug. Build a doc `"### How to do things\n"`; project (rendered shows `How to do things`); simulate a click landing between the rendered `n` and `g` of `things`; activate; assert the caret's `EditPosition.offsetUTF16` indexes the correct position in the SOURCE `"### How to do things"` (i.e. accounting for the hidden `### ` prefix — reuse `CaretMappingTests.testHeadingPrefixIsSkipped` expectations).

```swift
func testHeadingClickLandsAtCorrectSourceOffset() {
    let doc = EditableDocument.build(parsing: "### How to do things\n")
    // project; compute rendered offset of the caret between 'n' and 'g' in "things"
    // activate at that rendered offset
    // expected source offset = renderedOffset + 4 (the "### " prefix), per EditMapping
    XCTAssertEqual(controller.caret?.offsetUTF16, expectedSourceOffset)
}
```

- [ ] **Step 2: Run; confirm fail.**
- [ ] **Step 3: Implement `activate`/`deactivate`** using `EditMapping.sourceOffset` and Task-1 primitives.
- [ ] **Step 4: Run; confirm pass.** Add bullet-list and bold-span activation cases mirroring `CaretMappingTests` (`testBulletedAnchorListClickLandsInTheClickedItem`) to prove per-block mapping across kinds.
- [ ] **Step 5: Commit** (`feat(tree): block activation + source reveal via EditMapping (heading coordinate bug fixed)`).

---

## Task 5: Typing into the active source block (structural patch)

Depends on Task 4.

**Files:**
- Modify: `TreeTextController.swift` (input interception)
- Test: `Tests/QuoinRenderTests/TreeEditor/TreeTypingTests.swift`

**Interfaces:**
- Consumes: Phase-1 `EditTransforms.insertText(_:at:)` / `deleteRange(inBlock:_:)`; the active-block `reproject`.
- Produces: input path that, on native insert/delete inside the active block, applies the tree transform to `block.text`, then `reproject(activeBlock, active: true)` (patching only that block's storage range), then re-places the structural caret. Calls `session.noteInMemoryEdit()` on each committed change (Task 8 wires the session reference; here, a closure hook `onCommittedEdit`).

- [ ] **Step 1: Write the byte-correctness test** — type `"x"` into a paragraph mid-word; assert `document.serialized()` equals the expected source and that OTHER blocks' storage ranges are unchanged (only the active block's range shifted by the delta).
- [ ] **Step 2: Run; confirm fail.**
- [ ] **Step 3: Implement** the input interception (via the text view delegate / `insertText`/`deleteBackward` seam; the AppKit specifics are discovered here — the test is the contract). Disable the four smart substitutions on this text view (autocorrect/smart-quotes/dashes/copy-paste), matching `BlockEditorCell`.
- [ ] **Step 4: Run; confirm pass.**
- [ ] **Step 5: Add a caret-stability test** — after typing, the caret line's screen Y is unchanged (viewport invariant); extend from Task 1 Step 7's harness.
- [ ] **Step 6: Commit** (`feat(tree): typing = structural block patch, byte-correct, caret-stable`).

---

## Task 6: Tree-owned undo (snapshot stack + coalescing + `NSUndoManager`)

Depends on Task 5.

**Files:**
- Create: `Sources/QuoinRender/AppKit/TreeEditor/TreeUndoStack.swift`
- Modify: `TreeTextController.swift` (record units; wire `NSUndoManager`)
- Test: `Tests/QuoinRenderTests/TreeEditor/TreeUndoTests.swift`

**Interfaces:**
- Consumes: `EditableDocument` snapshots (value type), `EditPosition` caret; the coalescing RULES from `DocumentSession.TypingRun` (`DocumentSession.swift:556-608`) — ported as rules, NOT code (byte-offset contiguity → `EditPosition` adjacency; extend-inverse-edit → replace-top-vs-push-snapshot).
- Produces: `TreeUndoStack { func record(_ doc: EditableDocument, caret: EditPosition, boundary: Bool); func undo() -> (EditableDocument, EditPosition)?; func redo() -> ... }`, and `TreeTextController` registers each unit with the window's `NSUndoManager` (`registerUndo` + `setActionName`).

Note: `allowsUndo` is already `false` on the monolith text view (`MarkdownReaderView.swift:359`); set it `false` on the tree text view too, so NSTextView's built-in undo does not collide.

- [ ] **Step 1: Write the coalescing-granularity test** — type `"hello world"` as single chars; assert ONE undo reverts `"world"` back through the space boundary to `"hello "` (word granularity, not whole-sentence and not per-char), matching `TypingRun`'s whitespace-break rule.
- [ ] **Step 2: Write the caret-restore test** — undo restores the `EditPosition` caret structurally (the thing the session's `undo()` could never supply).
- [ ] **Step 3: Run; confirm fail.**
- [ ] **Step 4: Implement `TreeUndoStack`** — bounded depth (start 200 units; make it a constant `maxUndoUnits`); replace-top vs push-new keyed on the ported coalescing predicate over `EditPosition` adjacency + whitespace/structural-op break. **Measure snapshot cost** on a large-doc fixture (the O(N-segment) spine copy the design flags); if it exceeds a stated budget, record it and note the inverse-delta fallback as follow-up (do not build the fallback unless the budget fails).
- [ ] **Step 5: Wire `NSUndoManager`** registration + action names ("Typing", "Split Paragraph", "Delete", "Join Paragraph").
- [ ] **Step 6: Run; confirm pass;** add a redo test and an Edit-menu-title assertion.
- [ ] **Step 7: Commit** (`feat(tree): tree-owned snapshot undo with ported coalescing + NSUndoManager wiring`).

---

## Task 7: Return = split / Backspace = join, list continuation, IME-gated

Depends on Task 6.

**Files:**
- Modify: `TreeTextController.swift`
- Test: `Tests/QuoinRenderTests/TreeEditor/TreeStructuralKeysTests.swift`

**Interfaces:**
- Consumes: Phase-1 `splitBlock(at:)` / `joinWithPrevious`; `ListContinuation` (port from `Sources/QuoinEditorKit/ListContinuation.swift` — pure logic, no view coupling; move or re-home it so QuoinRender can use it without depending on QuoinEditorKit); `currentHasMarkedText()` for the IME gate.
- Produces: `onInsertNewline` → split (or list-continuation prefix) → structural patch (old block range → two projected runs) → caret to new block offset 0, as ONE undo unit. `onDeleteBackward` at offset 0 → join. Both are NO-OPs while `hasMarkedText()` (fall through to IME).

- [ ] **Step 1: Write the field-bug regression tests** through the real keystroke path (offscreen harness):
  - `"# How to do things"` + Return: the heading survives byte-identical; a new empty block follows; caret in it. (The exact bug Clint hit.)
  - One Return then one Backspace returns to the original bytes (split∘join = identity through the view).
  - Mid-paragraph Return splits at the caret; both halves byte-correct.
  - Empty-block row: Return at end-of-block yields an empty caret line (Task 1 Step 5 property through the keystroke path).
- [ ] **Step 2: Run; confirm fail.**
- [ ] **Step 3: Implement** the two handlers + list continuation + the IME gate. Re-home `ListContinuation` into QuoinCore or QuoinRender (it is pure logic; pick QuoinCore so it stays Linux-testable, and update QuoinEditorKit to consume it there — a small refactor, keep the island tests green).
- [ ] **Step 4: Run; confirm pass.**
- [ ] **Step 5: Add a CJK composition test** — a marked-text composition spanning a Return keystroke does not split mid-composition (the gate holds); commit only on composition end.
- [ ] **Step 6: Commit** (`feat(tree): Return=split / Backspace=join, list continuation, IME-gated; field bugs fixed through the keystroke path`).

---

## Task 8: The persistence bridge — load / save / external-change (GAP 1/2/3 wired)

Depends on Task 7. Wires the Task-2 session APIs into the controller and closes the external-change path.

**Files:**
- Modify: `TreeTextController.swift`, `Sources/QuoinRender/AppKit/TreeEditor/TreeEditorView.swift`
- Test: `Tests/QuoinRenderTests/TreeEditor/TreePersistenceBridgeTests.swift`

**Interfaces:**
- Consumes: `DocumentSession.open`/`noteInMemoryEdit()`/`saveTreeSource(_:)`; the session's publish stream; `QuoinDocument.sourceHash`; `EditableDocument.build(parsing:)`, `blockIndex(of:)`/`block(_:)` (`EditPosition.swift:15-22`).
- Produces: load builds the tree from the session source; every committed transform calls `noteInMemoryEdit()`; save serializes and calls `saveTreeSource`; a subscriber that ignores a publish whose `sourceHash` equals the just-saved hash (self-echo, GAP 2) and rebuilds only on a genuinely different hash (GAP 3) with a structural-fallback caret.

- [ ] **Step 1: Write the no-silent-loss test (GAP 1)** — make an in-memory tree edit (no save), simulate an external file change; assert the session is dirty and the merge/conflict path fires (banner state set), NOT the clean-adopt branch that discards edits.
- [ ] **Step 2: Write the self-echo test (GAP 2)** — save via `saveTreeSource`; feed the resulting publish back; assert the controller does NOT rebuild the tree (caret/active block preserved) because the hash matches.
- [ ] **Step 3: Write the external-rebuild caret test (GAP 3)** — a genuine external change (different hash) that edits the FOCUSED block; assert the tree rebuilds and the caret is restored by structural fallback (same block-INDEX counting block segments only — not raw segment index — clamped offset) and the banner shows. Add a case where an UNtouched block is focused (content-hash correlation succeeds exactly).
- [ ] **Step 4: Run; confirm fail.**
- [ ] **Step 5: Implement** the bridge. Round-trip byte-lossless assertion (load → edits → `saveTreeSource` → reload equals expected serialization). Composition-gate the external rebuild (defer while `hasMarkedText()`).
- [ ] **Step 6: Run; confirm pass.**
- [ ] **Step 7: Commit** (`feat(tree): persistence bridge — dirty signal, self-echo discrimination, external rebuild with structural caret fallback`).

---

## Task 9: Rendering cadence — single-block re-kind default, whole-doc reproject only on definition edits

Depends on Task 8. Closes GAP 4 / the parse-cost risk.

**Files:**
- Modify: `TreeTextController.swift` (deactivation re-kind; definition-triggered whole-doc reproject; document-level reference map)
- Test: `Tests/QuoinRenderTests/TreeEditor/TreeRenderCadenceTests.swift`

**Interfaces:**
- Consumes: `DefinitionScanner.containsDefinition` (Task 3); `MarkdownConverter.parse` (whole-doc) and a single-block parse for re-kind.

- [ ] **Step 1: Write the cadence tests:**
  - Block-to-block navigation (activate A, deactivate A, activate B) triggers NO whole-document parse — assert via a parse-count spy that only single-block re-kind parses ran.
  - Editing a reference definition (in trivia) DOES trigger a whole-document reproject and the referencing block's rendering updates (reference/footnote fixture).
  - `> ` typed at a paragraph start reclassifies to a quote on deactivation (single-block re-kind).
- [ ] **Step 2: Run; confirm fail.**
- [ ] **Step 3: Implement** — default deactivation re-projects + re-kinds only the deactivated block via a single-block parse; a document-level reference map is maintained; whole-doc reproject fires only when a changed trivia segment `DefinitionScanner.containsDefinition` flips, or footnote ordinals change. **Measure** the whole-doc reproject against the parse budget (`PerformanceTests` style) and assert block-navigation stays off it.
- [ ] **Step 4: Run; confirm pass.**
- [ ] **Step 5: Commit** (`feat(tree): render cadence — single-block re-kind default, whole-doc reproject only on definition edits`).

---

## Task 10: Viewport invariant + regression suite through the GUI path; flag mount

Depends on Task 9.

**Files:**
- Create: `Sources/QuoinRender/AppKit/TreeEditor/TreeEditorView.swift` (mount behind `QuoinTreeEditor`)
- Modify: the flag site (`App/macOS/Sources/ReaderScreen.swift:50` area) to select the tree path when `QuoinTreeEditor` is set.
- Test: extend `RevealFidelityTests` / `CaretLineAnchorTests` / `ProjectorEquivalenceTests` for the tree path.

- [ ] **Step 1: Write the viewport-invariant tests for the tree path** — the caret line does not move on activation, split, join, typing, for each block kind (mirror the existing RevealFidelityTests script; extend it, do not fork it).
- [ ] **Step 2: Write cross-block native selection tests** — a selection spanning two blocks reads correctly (the capability v2 could not offer). A multi-block DELETE is deferred (Open Question) — assert it is either handled by split/join composition or explicitly blocked, whichever Task-7 scope chose; document the decision in the ledger.
- [ ] **Step 3: Run; confirm fail; implement `TreeEditorView` + flag mount.**
- [ ] **Step 4: Run full `swift test`; confirm the tree suite green AND the monolith suites still green** (the tree path is additive; the default path must be untouched).
- [ ] **Step 5: Commit** (`feat(tree): TreeEditorView behind QuoinTreeEditor flag; viewport invariant + regression suite green`).

---

## Task 11: Cutover — tree becomes the SOLE editor; delete the old paths

Depends on Task 10 (parity proven: the tree path passes the full regression suite). **No installed base — this task clears the clutter now, it does not defer to a later phase.**

**Parity gate (do this FIRST):** confirm Task 10 left the tree path green on the full regression suite (viewport invariant, reveal fidelity, projector equivalence, the field-bug scenarios). If any parity gap remains, STOP and report — do not delete the oracle before the replacement matches it.

**The deletion boundary — delete the string-as-truth EDIT + old VIEW layers; KEEP the shared projection engine the tree reuses.**
- **Delete:** the monolith reader edit path — `MarkdownReaderView`, `ReaderCoordinator` (its reconcile/reveal-patch machinery), `QuoinTextView` if the tree view replaces it, `ReaderModel`'s byte-edit plumbing; the interim guard (`ReaderCoordinator.caretStrandedAboveBlankLine` + the `gapDeletion`/`handleGapDeletion` scaffolding); the island recycler VIEW layer in `QuoinEditorKit` (`BlockRecyclerView`, `BlockRecyclerReaderView`, `IslandController`, `BlockRenderCell`, `BlockEditorCell`, `IslandTextView`, and the byte-range row model `IslandUnit`/`BlockListModel`) and its now-orphaned tests; the `QuoinTreeEditor` flag branch and the old `useRecycler`/`QuoinEditorRecycler` selection — the tree view mounts unconditionally.
- **Keep (the tree reuses these):** `AttributedRenderer`, `MarkdownSourceStyler`, `EditMapping` (QuoinCore), the decoration drawing the tree view adopted, the re-homed `ListContinuation`, and all of `QuoinCore`'s model/session/serializer.
- The precise cut is whatever Tasks 4–10 did **not** end up importing into the tree path — determine it against the real dependency graph at this point (grep for references before deleting each type), not from this list alone; this list is the intent.

- [ ] **Step 1: Parity gate** — verify the full suite is green through the tree path (per Task 10). Record the evidence.
- [ ] **Step 2: Make the tree view the unconditional editor** — remove the flag branch; mount `TreeEditorView` directly. Run the suite.
- [ ] **Step 3: Delete the monolith edit/view path and the interim guard** — remove the files/types above; fix every now-broken reference and delete tests that only exercised the deleted paths. `swift build` + `swift test` green.
- [ ] **Step 4: Delete the island recycler view layer** (`QuoinEditorKit` view types + byte-range row model + their tests), keeping only the re-homed pure logic. `swift build` + `swift test` green.
- [ ] **Step 5: Update docs** — `docs/reference/architecture.md` (the tree editor is now THE editor; the string-reconcile path, island recycler, and interim guard are gone), `README.md` if warranted, and the spec statuses (Phase 2 = delivered AND cutover-complete; there is no separate Phase 3).
- [ ] **Step 6: Commit** (`refactor: delete the string-as-truth monolith, island recycler view layer, interim guard, and flag — tree editor is the sole path`).

---

## Task 12: Narrow `DocumentSession` to persistence — delete the now-dead edit machinery

Depends on Task 11 (nothing but the tree path remains).

With the monolith gone, `DocumentSession`'s keystroke-path plumbing has no remaining consumer. Delete it rather than leave it as clutter (a misleading second edit model the next reader would trust).

**Files:**
- Modify: `Sources/QuoinCore/DocumentSession.swift`, `Sources/QuoinCore/EditorCore.swift`, and any caller.
- Test: prune `Tests/QuoinCoreTests` cases that only covered the deleted machinery; keep the persistence + tree-bridge coverage.

- [ ] **Step 1: Prove no consumer** — grep the whole repo (excluding deleted files) for `applyEdit`, `undo()`/`redo()` on the session, `staleEditBase`, `TypingRun`, `recordUndo`, `contentRevision`. Anything still referenced by the tree path stays; list what's genuinely dead.
- [ ] **Step 2: Delete the dead edit machinery** — the `SourceEdit` undo/redo stacks, `TypingRun` coalescing, `applyEdit`, `staleEditBase`, and `contentRevision` if unused — leaving `open`/`saveNow`/`saveTreeSource`/`noteInMemoryEdit`/`apply(source:)`/external-change detection. Keep behavior that prevents real data loss (external-change/conflict handling) — that is correctness, not clutter.
- [ ] **Step 3:** `swift build` + `swift test` green; the session is now a persistence authority only. Verify Swift 6 strict-concurrency clean.
- [ ] **Step 4: Commit** (`refactor(core): narrow DocumentSession to persistence — delete the dead SourceEdit/undo/staleEditBase edit path`).

---

## Non-goals (Phase 2)

- Multi-block *editing* transforms beyond split/join composition (a rich cross-block cut/paste model), editable footnote/reference-definition nodes, inline canonical serialization of edited runs — later work (the tree makes them possible, not now).
- Collaboration/CRDT — out of scope.
- (There is deliberately no "keep the old path" non-goal: the old paths are DELETED in Tasks 11–12. No installed base ⇒ no coexistence.)

## Risks

- **R1 (gate) — stock-storage structural patch viability.** Retired by Task 1 (spike + go/no-go). If NO-GO, the plan pauses for a design revisit (custom-backend approach or different projection granularity).
- **R-cost — undo snapshot memory.** O(N-segment) spine copy per unit; bounded depth + measured in Task 6; inverse-delta fallback named if the budget fails.
- **R-parse — whole-doc reparse cost.** Kept off the hot path by Task 9 (definition-triggered only); measured against the parse budget.
- **R-focused-rebuild — external change to the focused block.** Best-effort structural caret fallback + visible merge banner (Task 8); rare path, explicit contract.
- **Two editor paths during development** (behind the flag, Tasks 1–10) — a temporary scaffold, not a shipped state; the flag is the parity harness. Tasks 11–12 delete the old path once parity is proven, so no long-lived dual-path risk.
- **Deletion tasks (11–12) removing something the tree still needs** — mitigated by the parity gate (Task 11 Step 1) and by determining the cut against the real dependency graph (grep-before-delete), plus the full suite green after each deletion step.
