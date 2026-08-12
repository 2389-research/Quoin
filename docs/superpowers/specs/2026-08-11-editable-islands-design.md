---
title: Editable-Islands editor architecture (per-block views; replacing the read-only projection)
created: 2026-08-11
status: DESIGN — approved to spec (PAL-debated); per-phase implementation plans follow a Phase-0.5 perf gate
supersedes: the read-only "projection editor" model (shouldChangeTextIn → false)
related:
  - docs/reference/architecture.md (§ editing model — rewritten per phase)
  - docs/reference/invariants.md (viewport/caret invariants — several retired)
  - CARET-1 series (2026-08-10) — the last symptomatic fixes before this rearchitecture
history:
  - Original draft used a single NSTextView with inactive blocks as 1-char
    NSTextAttachments. A PAL red-team flagged that model as the highest risk
    (custom-fragment layout thrash, memory, strobey selection, tall-block scroll
    jumps). After debate we FLIPPED the substrate to per-block views; the
    edit-orchestration layer is substrate-agnostic and unchanged. The attachment
    model is retained only as a documented fallback if per-block views miss the
    Phase-0.5 perf gate.
---

# Editable-Islands editor architecture (per-block views)

## 1. Why (the root cause we are removing)

Quoin's editor is a **read-only projection**: the `NSTextView` never edits its own
storage (`textView(_:shouldChangeTextIn:)` returns `false`); every keystroke is
intercepted, translated to a byte edit against the Markdown source, applied
through a session, re-parsed, re-projected to a fresh attributed string, and the
caret is **re-derived from scratch** across four coordinate spaces (document
bytes ↔ per-block editable slice ↔ rendered offset ↔ screen point).

Two structural consequences have made basic editing chronically fragile:

1. **Markdown has no empty-paragraph node.** A blank line where the caret must
   sit has no legal home in the AST, so the code *synthesizes* one by absorbing
   whitespace into a neighboring block's editable slice. After a re-parse the
   caret snaps to the nearest node that *does* exist — which is why pressing
   Return at the end of a heading that has body text below it lands the caret on
   the wrong line and typing appends to the heading (`Welcomedddddd`), and why
   "⌘A then Delete" does nothing (multi-block delete was never expressible).

2. **The real edit+caret path is untested.** It lives in an `@MainActor`
   view-model (`ReaderModel`) plus the `NSTextView` delegate plus an async
   "echo" round-trip — and no test drives that real path. Fixes written against
   the *pure helper functions* pass while the app stays broken (shipped
   green-but-broken repeatedly).

**The fix is architectural.** The active block becomes real editable text the OS
owns; every other block is a non-editable rendered view the caret cannot enter.
There is no nameless region between nodes; the caret only ever lives inside one
real, editable block. The synthetic-blank-line machinery, the absorbed slices,
and the four-space caret re-derivation are **deleted, not fixed**.

The deeper lesson from the design debate: the hard part was never the text-view
mechanism — it is the **edit-orchestration layer** (stable anchors, reconciliation
to Markdown, split/merge grammar, undo). That layer is independent of how pixels
are drawn, which turns the drawing substrate into a *measurable* engineering
choice rather than a bet-the-architecture guess (hence the Phase-0.5 gate).

## 2. Goals / non-goals

**Goals**
- Native OS-owned typing, caret, selection, and IME inside the block being edited.
- Preserve the three hard constraints: **byte-lossless** round-trip, **WYSIWYG**
  rendering of non-active content, **zero JavaScript**.
- Reuse the existing block-WYSIWYG renderer and the entire QuoinCore engine.
- A **headless end-to-end test harness** driving the real editor — the standing
  gate that makes green-but-broken impossible.
- Migrate as an **incremental strangler**; every phase is buildable/usable
  (flag-gated until proven), behind a **Phase-0.5 perf gate**.

**Non-goals / consciously accepted losses (v1)**
- **Prose-first scope.** Headings, paragraphs, lists, and block-quotes get full
  native island editing. Code blocks, tables, math, and diagrams are edited as
  their **raw Markdown/source text** in the island (multi-line, no in-cell
  widgets). Structured editing (WYSIWYG table cells, grid navigation, language-
  aware code) is deferred.
- **Block selection, not native cross-block text selection** (user-ratified). Like
  Notion/Craft/Obsidian: ⌘A selects all blocks, Shift-click/Shift-arrow extends
  by block, Delete removes them, copy assembles the covered bytes. Within a block,
  normal native text selection. A partial select-and-copy spanning two paragraphs
  is approximated (select-to-block-end) or deferred.
- **Document-level Find, not native `NSFind` across one container** — a find
  manager scans the bytes, maps matches to blocks, paints highlight overlays on
  inactive rows, and maps to a local range in the active island.
- Collaborative editing and multi-caret are out of scope.

## 3. Architecture — substrate (per-block views)

**One `NSScrollView` hosting a virtualized recycling list** — a view-based
`NSTableView` (variable row heights; lowest engineering risk) or `NSCollectionView`
(more flexible future layouts). Each block is one row:

- **Inactive block → `BlockRenderCell`**: a layer-backed `NSView` that draws the
  block via the KEEP renderer (`AttributedRenderer.render(block:…)` + existing
  decoration drawing) and existing block accessibility. It hosts overlay layers
  for selection band, find matches, and the current match. It is not editable;
  its bytes are never materialized as text, so **byte-losslessness is free**.
- **Active block → `BlockEditorCell`**: hosts exactly one `QuoinTextView`
  (`NSTextView`, default TextKit-2 content storage/layout manager) whose text IS
  the block's raw Markdown source. Typing, caret, selection, IME are native.
  Smart-substitutions default off (they fight Markdown; user-settable).

**Exactly one `BlockEditorCell` exists at a time.** Virtualization/laziness come
free from the recycler; memory scales with visible rows + a small cache, not with
document size.

**Cell sizing contract (must-have to avoid layout jitter):** a `BlockRenderCell`
returns a **deterministic row height synchronously** from renderer metrics cached
by `(blockID, revision, width, themeID)`. Heights must not change after first
layout except on revision/theme/width change. The renderer emits a transient draw
list for inactive blocks — it **must not retain per-block `NSAttributedString`s**;
heavy blocks (tall diagrams/tables) are pre-rasterized into an LRU image cache.
(This requires a small renderer metrics API: line count + intrinsic height given
width/theme — added in Phase 0/1.)

**`IslandUnit` — the editing scope, distinct from AST `BlockID`.** The active
island owns a contiguous `byteRange` and persists across *non-structural* type
morphing: typing `# `, `- `, or ```` ``` ```` reclassifies the AST node, but the
island identity and caret stay put. Only a **structural delimiter commit**
(paragraph split, list exit, fence close) re-homes the island to a new AST block.
This closes the "the thing I'm editing stopped being the same block" hazard.

**`BlockListModel`** is the mapping authority (replaces the projection index):
```
struct BlockRecord { let blockID: BlockID; var byteRange: Range<Int>; let type: BlockKind; var height: CGFloat; var revision: UInt64 }
// display-ordered [BlockRecord]; the active IslandUnit references one (or, mid-morph, a small span).
```

## 4. Active-island swap choreography

Focus change (click / arrow across a block edge / block-selection Enter) runs
through a **`SwapState` machine** — `Idle → PendingFlush(target) → Swapping →
Idle`, with a `BlockedIME(target)` gate — and only one swap is inflight;
multiple intents coalesce to the last target.

1. **Refuse to swap while `textView.hasMarkedText`** (IME); queue the intent, run
   it on `unmarkText`.
2. **Finalize the old island**: cancel debounce, flush uncommitted edits as one
   byte patch (`await DocumentSession.apply`), get new bytes + AST revision +
   refreshed catalog.
3. **Freeze viewport**: disable animated scrolling, hide the caret (avoid blink
   artifacts), record `documentVisibleRect.origin` and the target row's frame.
4. **Reconfigure rows** (no whole-document relayout): demote the old
   `BlockEditorCell` → `BlockRenderCell`; promote the target row →
   `BlockEditorCell` seeded with the block's current source. Update `BlockListModel`.
5. **Place the caret**: click → map the recorded hit point to a local line/column
   via the renderer's line metrics (safe default until exposed: nearest line by
   `boundsHeight/lineHeight`, then column by x — never a bare left/right-half
   guess for multi-line prose); arrow entry → offset 0 (from left) or end (from
   right), carrying `goalColumn`.
6. **Unfreeze** after `ensureLayout` on the target row; `scrollRangeToVisible` the
   caret; restart blink. Scroll-anchor drift target: `< 4pt` for ≤50pt height
   deltas, `< lineHeight` otherwise.

Optional latency optimization (if reparse is slow): optimistic swap — activate the
target immediately from its last-known source while the old island's flush is
inflight (old island read-only during flush), finalize on return.

## 5. Edit → Markdown reconciliation

- **Intra-island typing stays local** to the `NSTextView` (native, fast IME). The
  model splice is **debounced (~200 ms idle)** and forced immediately on: island
  swap, structural boundary actions, or app reads (save/export/search).
- **Splice** = the island's edited `String` → one byte patch replacing the
  `IslandUnit.byteRange` → `DocumentSession.apply` → update the record. Only the
  active island's range (and explicit boundaries on structural ops) is ever
  patched; untouched blocks are never decoded/re-encoded → byte-lossless.
- **Non-structural type morphing does NOT re-home the island** (see `IslandUnit`).
  `DocumentSession.apply` returns a block-mapping diff so `ByteAnchor` resolution
  prefers the `IslandUnit` mapping first, avoiding mid-typing swaps.
- **Split (Return at a structural point)** — driven by the KEEP `ReturnSemantics`
  table, as a native newline reconciled to the grammar: heading-end/paragraph →
  real `\n\n`, flush, activate the new block, caret at start; list item → new
  item with same marker/indent, or exit on an empty item.
- **Merge (Backspace at island start / Delete at island end)** adjacent to another
  block → boundary byte patch per block-type rule, reparse, activate the merged
  block at the join.
- **Cross-block delete (⌘A + Delete, block selection + Delete)** → assemble the
  covered contiguous byte ranges from anchors, delete in one patch, caret to a
  boundary anchor at the deletion start.

## 6. Selection anchors & block selection

```
struct BlockID: Hashable      // stable across reparse via an O(n) overlap+type diff, content-hash fallback
struct BoundaryID: Hashable { let left: BlockID?; let right: BlockID?; enum Kind { case interBlock, blockStart, blockEnd }; let kind: Kind }
struct ByteAnchor { enum Kind { case byte(Int); case boundary(BoundaryID) }; enum Affinity { case before, after }
                    var kind: Kind; var affinity: Affinity; var goalColumn: Int?; var revision: UInt64 }
struct SelectionAnchorRange { var start: ByteAnchor; var end: ByteAnchor }
```
- **Within the active island**: `ByteAnchor.byte` → local byte offset → UTF-16 via
  the island's `UTF8IndexMap` → `NSTextView` selection. Native.
- **Across blocks**: a **block-selection model** (a contiguous set of `BlockID`s)
  rendered by selection overlays on `BlockRenderCell`s. ⌘A selects all; Shift-arrow
  / Shift-click extends by block; Up/Down at an island edge re-homes into the
  neighbor (carrying `goalColumn`); Shift-Up/Down at an edge starts block
  selection. Copy/cut assemble the covered bytes; Delete/typing replace the
  selection via a structural patch.

## 7. Coordinate spaces after the change

Collapses to **two** for edits: **active-island local UTF-16 ↔ document byte
offset** (via the island `UTF8IndexMap` and the `IslandUnit` base). Residual:
inactive positions ↔ block boundaries; storage position ↔ screen rect (native
TextKit within the one active view). `ByteAnchor` carries robustness across
reparses/swaps.

## 8. The test harness (non-negotiable infrastructure)

A **new framework target `QuoinEditorKit`** holds the edit machinery
(`IslandController`/`EditOrchestrator` (MainActor), `BlockListModel`,
`IslandUnit`, the `DocumentSession` protocol seam) so tests import it. Tests run
in a **test host app** (CI-stable) that builds the *real* recycler +
`BlockEditorCell`/`BlockRenderCell` + orchestrator.

**Quiescence barrier**: `DocumentSession` increments a `UInt64` revision per
patch, mirrored on `orchestrator.currentRevision` and stamped on projected
content. After each edit call the test waits for `currentRevision == expected`,
then `ensureLayout`, then reads the caret rect.

**Drive edits** by sending `NSTextInputClient` messages to the active row's
`NSTextView` (`insertText`, `insertNewline`, `deleteBackward`, `moveRight/Left/
Up/Down`) and document-level selection ops through the orchestrator (anchors).
**Assert per scenario**: exact document bytes; AST shape around the edit; active
`IslandUnit`/`BlockID` before/after; `selectedRange` maps back to the expected
`ByteAnchor`; **insertion-rect height ≥ a baseline threshold** (the standing
2pt-dot gate); no residual marked text.

**Core scenarios (write first):** Return at end of interior heading (the prior
failure); Return at end of last block (control); Backspace merging a paragraph
into the prior heading; list-item split; list exit on empty item; type-morph a
paragraph into a heading mid-edit (island identity holds); ⌘A + Delete; IME
composition in the island (no flush/swap until composition ends).

## 9. Rip / Keep / Rebuild inventory

**REBUILD (the seams the model replaces):**
- `Sources/QuoinRender/AppKit/ReaderCoordinator.swift` (~3,462 LOC) — the
  keystroke-intercepting delegate + caret re-derivation + edit-echo ledger.
  Re-wire (not rebuild) the portable sub-parts: search highlighting, focus
  dimming, scroll anchoring, link/footnote plumbing, context-menu/annotation
  gestures, preview-panel choreography.
- `Sources/QuoinRender/AppKit/QuoinTextView.swift` (~990 LOC) — keep paste/image
  overrides, tracking areas, `menu(for:)`, decoration-drawing host; rip
  `CaretGapGeometry` + synthetic-caret drawing + viewport caret-pinning. In the
  new model `QuoinTextView` is a *normal* editable text view inside one row.
- `Sources/QuoinRender/AppKit/MarkdownReaderView.swift` (~908 LOC) — replaced by
  the recycler-hosting view; keep the format-command/annotation/search/
  scroll-target command surface.
- `App/macOS/Sources/ReaderModel.swift` — REBUILD the edit+caret path; KEEP the
  block-command/table/structure/front-matter/suggestion/annotation operations
  (they apply `SourceEdit`s, edit-model-agnostic).
- `ReaderScreen.swift` (~1,609 LOC) — REBUILD touch-points to audit.

**RIP (projection-only, deleted as replacements prove out):**
- In `AttributedRenderer.swift`: `editableSlice`, `caretMapping`,
  `compressInteriorBlankLines`, `clampTrailingNewlinePhantom`,
  `revealNeedsClampedSeparator`, `clampedSeparator`, `occupiableSeparator`,
  `renderEditableSource*`/`assembleRevealedFragment`/`RevealedFragment`,
  `revealStylerConfig`, `activeBlockEditUpdate`/`activationFlipUpdate`, the
  `separator(…revealedSlice:)` variant, and the `RenderedDocument` reveal fields.
- `MarkdownSourceStyler.swift` — the caret-scoped span reveal (active-block
  syntax highlighting may be re-adopted; the collapse-others behavior is RIP).
- `CaretHint` (the four-space tag) — gone.

**KEEP (reused unchanged):**
- `AttributedRenderer` block-WYSIWYG pipeline — every `render<Block>` + inline
  rendering + `blockSeparator`/`separatorLength`. **This becomes the
  `BlockRenderCell` drawing.**
- All of `QuoinCore`: parsing, AST, `EditorCore`/`DocumentSession` (`SourceEdit`
  in / `QuoinDocument` out — the reconcile seam), `EditMapping`, `EditIntent`
  (smart-pair logic; re-point its caller), `ReturnSemantics`, exporters,
  Mermaid/Vinculum reexports, structure/table/front-matter editing.
- App shell/support: `Theme`, `BlockDecoration/Presentation/Accessibility`,
  `TableLayout`, `StructureRotor`, `AsyncImageStore`, `ScrollAnchorMath`,
  preview-panel, `FlipTransitionController`, sidebar/library, QuickLook,
  Spotlight, Intents.

**Hardest couplings (sequencing risk):**
1. `editableSlice` is shared by full render + per-keystroke patch and locked
   byte-identical by `ProjectorEquivalenceTests`; remove as a unit in Phase 2/3.
2. The edit-echo generation-counter handshake spans three files and is load-
   bearing for not dropping fast input; it is **replaced** (native typing), not
   merely deleted.
3. `separator(…revealedSlice:)` branches reveal-vs-reading in one function.
4. `CaretHint`'s two spaces leak through `onActivateBlock` — the view API changes.
5. `ReturnSemantics` (KEEP) vs every consumer (REBUILD): same rule table, new
   mechanism (native newline reconciled at boundaries).

## 10. Phased migration (strangler; each phase buildable, flag-gated)

**Perf targets (bake-off + ongoing), floor = M1 Air AND 2019 Intel i7 (both run
macOS 14):**
- Continuous-scroll p95 frame time ≤ **12 ms** (Apple Silicon), ≤ **14 ms** (Intel).
- Swap latency (mouseUp → correct-height caret) p95 ≤ **45 ms**, hard cap 80 ms.
- Peak RSS ≤ **+200 MB** over a plain-text viewer of the same content.
- Selection-drag refresh p95 ≤ **16 ms**; find-next step p95 ≤ **35 ms**.
- Scroll-anchor drift on swap < 4pt (≤50pt height delta) / < lineHeight otherwise.

- **Phase 0 — Foundations & harness.** Create `QuoinEditorKit`; define `BlockID`
  (stable), `ByteAnchor`/`BoundaryID`, `IslandUnit`, `BlockListModel`, a
  `DocumentSession` revision counter, and the renderer metrics API (line count /
  intrinsic height). Build the headless test-host harness + quiescence barrier.
  No visible change. Risk: low.
- **Phase 0.5 — Perf-validation spike (HARD GATE, throwaway code).** Build a
  disposable "10k-block storm" corpus (70% short prose, 20% lists, 10% heavy
  400–1200pt blocks) on the **per-block-views recycler**; drive scroll, block-
  selection drag across 500 rows, find-jump, and repeated activate/deactivate
  swaps; measure against the targets above on M1 Air + Intel i7. **Pass → proceed.
  Fail → evaluate the attachment substrate (or a hybrid: prose rows + view-backed
  heavy blocks) before committing.** No phase plan is written until this gate
  passes.
- **Phase 1 — View recycler, read-only.** Replace the reader with the recycler of
  `BlockRenderCell`s, incl. selection/find overlays and per-block accessibility
  ("Edit" action). Delete inactive-content blank-line clamp hacks. Flag. Risk:
  medium (layout/AX).
- **Phase 2 — One editable island.** Introduce `BlockEditorCell` (`NSTextView`),
  `IslandController`, `SwapState`; debounced reconciliation; native typing/caret/
  IME; no structural ops yet. Harness assertions live (typing, swap, caret-height
  gate). Delete legacy caret re-derivation + echo handshake. Flag. Risk:
  medium-high (first real edits).
- **Phase 3 — Structural ops + block selection (closes the reported bugs).**
  Split/merge for headings/paragraphs/lists/quotes off `ReturnSemantics`;
  block-selection model; cross-block delete/copy; ⌘A = select-all-blocks. Delete
  `editableSlice`/blank-line synthesis. Ship as **default** when green. Risk: high
  — the riskiest phase.
- **Phase 4 — Complex blocks + polish.** Raw-text multi-line islands for
  code/quote/table (Tab field-hop in tables); undo/redo across swaps;
  document-level find/replace; accessibility polish; telemetry. Retire the
  projection test suites; delete remaining projection caret code.

Each phase gets its **own implementation plan** (written when reached).

## 11. The hard parts and how the design handles them

- **IME / marked text**: never flush, reparse, or swap while `hasMarkedText`;
  queue the intent, run on `unmarkText`. Composition stays inside the island.
- **Type morphing mid-edit** (`# `, `- `, fences): the `IslandUnit` holds identity;
  only structural-delimiter commits re-home. (See §3/§5.)
- **Undo/redo (concrete):** the **document-level `NSUndoManager` is the single
  source of truth** for committed edits (byte patches). Intra-island unflushed
  typing uses the `NSTextView`'s local undo; on flush, open a document undo group,
  apply the patch, register the inverse, reconcile the island text within the
  swap transaction with `textView.allowsUndo=false` bracketing, close the group —
  **accepting that intra-island undo granularity collapses to document granularity
  on flush**. Structural ops are a single group (patch + swap + `ByteAnchor`
  selection); undo reapplies the inverse, re-homes the island, restores selection.
  A pressed Undo with unflushed edits short-circuits to local typing undo. Tested:
  typing-undo before/after flush, undo a split, undo across a swap.
- **Copy/paste across blocks**: block selection → pasteboard `public.utf8-plain-
  text` (covered bytes) + optional RTF/custom UTI. Paste in an island = native
  (Markdown-escape policy); block-level paste = byte insertion at a boundary +
  reparse + activate.
- **Find/replace**: document-level manager over the bytes; active-island matches
  map to local ranges; inactive matches paint overlays with an "edit here"
  affordance and apply as byte patches.
- **Spell-check / Services**: live only inside the active island in v1 (matches
  block-editor norms); per-block async spell overlays later.
- **VoiceOver / accessibility**: the recycler is an `NSAccessibilityGroup`; each
  `BlockRenderCell` is `AXStaticText` with a concise serialization ("Heading level
  2: Welcome", "List, 3 items", "Code block (Swift), 10 lines") and an "Edit"
  action; the active row exposes `AXTextArea`; a rotor jumps by headings/lists.

## 12. Testing strategy

- **New (the gate):** the `QuoinEditorKit` headless harness (§8) — every phase
  from 2 on is gated by it; Phase 0.5's perf spike gates the substrate.
- **KEEP as safety net:** block-WYSIWYG render fidelity suites
  (`AttributedRendererSnapshotTests`, `RendererConformanceTests`,
  `BlockPresentationTests`, `TableLayoutTests`, diagram/math, accessibility
  tagging) and all QuoinCore parsing/session/exporter/structure suites — these
  don't change and prove the KEEP layer stays intact.
- **RETIRE with their mechanism (Phase 3/4):** the projection-specific suites
  (`CaretMappingTests`, `ExcessWhitespaceSliceTests`, `GapDeletionTests`,
  `ProjectorEquivalenceTests`, `KeystrokeReplayTests`, `EditEchoSerializationTests`,
  `ActivationFlipPatchTests`, `RevealFidelityTests`, `CaretGapGeometryTests`,
  `EditPathReturnTests`, …). The rule-level intent survives in
  `ReturnSemanticsTests`/`EditIntentTests` (KEEP).

## 13. Open questions / safest defaults

- **Renderer line metrics** for click-to-caret precision: add the metrics API in
  Phase 0/1; until then, nearest-line-by-height + column-by-x.
- **Recycler choice**: default view-based `NSTableView` (variable row heights,
  lowest risk); `NSCollectionView` if future layouts need it. Avoid SwiftUI
  `LazyVStack` for the editor core (less measurement/perf control).
- **Reconciliation debounce**: default 200 ms (structural ops always flush now).
- **Compound islands** (table row logic, quote continuations): v1 keeps
  island == exactly one block; revisit in Phase 4 only if needed.

## 13b. Phase 0 landed — carry-forward for Phase 1/2

Phase 0 (foundations + harness) is complete on `main`
(`docs/superpowers/plans/2026-08-11-phase0-editor-foundations.md`): `QuoinEditorKit`
target, `UTF8IndexMap`, `ByteAnchor`/`BoundaryID`, `IslandUnit`+`BlockListModel`,
`AttributedRenderer.measuredHeight`/`lineTops`, and the headless `EditorTestHarness`
(real `NSTextView` via `NSTextInputClient` + quiescence + insertion-bar gate).
Three decisions must be honored when their phase arrives:

1. **Cell height ≠ text height (Phase 1).** `measuredHeight` is text-layout height
   only. `BlockRenderCell` MUST add decoration chrome/insets drawn outside text
   bounds (code canvas, callout, diagram frame) on top of it, and MUST re-measure
   async-decoding blocks (diagram/math/image) when `hasPendingContent` flips —
   otherwise deterministic row height is wrong for those kinds.
2. **`move()` and the applied-revision barrier (Phase 2).** The harness bumps
   `appliedRevision` on navigation too; a pure nav changes no bytes and won't tick
   the orchestrator's real applied-revision. Decide nav-ticks-or-not BEFORE wiring
   the harness barrier to the orchestrator, or the two diverge.
3. **Anchor resolution at boundaries (Phase 2/3).** `BlockListModel.record(at:)`
   uses half-open ranges, so inter-block separator offsets and exact block-end
   offsets resolve to nil/next block — that gap is exactly what `BoundaryID`
   resolution must fill. And the harness gate only bites when `caretRect` is read
   against the CORRECT active-cell char range (mind the rendered-vs-source offset
   spaces per CLAUDE.md's caret-hint warnings).

`revision` is `Int` throughout (matching the existing `DocumentSession.contentRevision`),
not the `UInt64` this doc's prose sketched — no conversion seam.

## 13c. Phase 1 landed — carry-forward before flipping `QuoinEditorRecycler` default-on

Phase 1 (read-only per-block view recycler) is complete on `main`, behind the
default-OFF `QuoinEditorRecycler` flag; the projection reader is unchanged
(plan `docs/superpowers/plans/2026-08-11-phase1-block-recycler.md`). `QuoinEditorKit`
now has `BlockRenderCell` (text + decoration parity, cell-local), `DecorationDraw`
(ported chrome; `verticalBleed=5`/`leftGutter=14`), `BlockRowMetrics.rowHeight`
(text + bleed + measured separator; outer edges omit bleed → sum-parity ~0pt),
async re-query (`onContentSettled`→`noteHeightOfRows`, wired to the real
`AsyncImageStore`), `BlockRecyclerView` (view-based `NSTableView`, bounded
recycling, `contentInsets=5pt`), per-cell AX + table rotors, and
`BlockRecyclerReaderView` behind the `ReaderScreen` flag branch.

**Must-fix BEFORE flipping the flag default-on (Phase 2/3):**
1. **Separator-memo stale cache.** `BlockRowMetrics.separatorContribution` memoizes
   on `(separator string, width)` in a process-global static that is never
   invalidated — a `textScale` change leaves stale seam heights. Add theme/textScale
   to the key OR clear the cache when the renderer is recreated. (Bounded, flag-on
   only; parked at the Phase-1 final review.)
2. **wordWrap** is threaded but only toggles the horizontal scroller; per-cell
   no-wrap layout is not implemented (a cell lays out at a fixed column).
3. **Visual parity eyeball** (the user, zoomed, on `Quoin UX Test.md`): code
   canvases, callout boxes + nested cards, quote gutter bars, per-row table rules,
   heading spacing, inter-block gaps vs the projection reader; repeat outline-click
   re-scrolls; large-doc scrolling stays smooth.

The recycler now shares the model's actual configured renderer (baseURL,
onContentReady, imageResolution, loadsRemoteImages; textScale/codeTheme via theme),
so relative images and reader config already match the projection reader.

## 13d. Phase 2 landed — carry-forward before flipping `QuoinEditorRecycler` default-on

Phase 2 (ONE editable island) is complete on `main`, behind the default-OFF flag;
the projection reader is unchanged (plan
`docs/superpowers/plans/2026-08-11-phase2-editable-island.md`). Clicking a block
in the recycler promotes it to a real editable `NSTextView` island
(`BlockEditorCell`, source-safe substitutions off); `IslandController` + a
`SwapState` machine handle click→swap→caret with IME refusal; edits debounce and
reconcile back through the KEEP `ReaderModel.reconcileIsland` →
`applyAbsolute(caretUTF8:nil)` path as one byte-exact `SourceEdit`; the split
classifier is safe-by-construction (never edits across a split — Return is a soft
newline, split→deactivate); the Phase-0 `EditorTestHarness.init(adopting:)` now
drives the real island end-to-end as the standing gate. **The final review caught
a data-loss bug (an island torn down by its own reconcile's projection refresh,
then empty-flushed) — FIXED**: the refresh preserves the active island and
`flushActiveIsland` never empty-splices a missing cell.

**Must-fix BEFORE flipping the flag default-on:**
1. **Island-preservation async race (parked).** Keeping the island alive across its
   own reconcile depends on `applyReconciled` re-anchoring BEFORE SwiftUI's
   revision-driven `updateNSView` refresh runs. If the refresh wins the race,
   `_editingBlockID` is stale and the island silently drops to read-only mid-edit
   (NOT data loss — the empty-splice bail backstops it; common case preserves).
   Make it order-independent: defer the revision-bump refresh until
   `applyReconciled` completes, OR re-anchor by position, OR tag the reconcile
   revision so `apply` skips the redundant refresh.
2. **Blur / deactivate + IME-retry not wired to responder events.** Clicking
   outside any block / window blur does not flush+deactivate the island (edits
   still reconcile on the 200 ms idle debounce, so no loss — the island just stays
   visually editable until the next click). An IME-refused activation is dropped
   (re-click needed). Wire both to real responder events.
3. **Editing-cell wrap width on mid-edit window resize** (cosmetic reflow lag).
4. **Structural ops are Phase 3** — Return does NOT yet create a new block (soft
   newline; split→deactivate); Backspace-merge and block-selection ⌘A-delete are
   Phase 3, which also flips the flag default-on and deletes the projection RIP
   machinery.

## 14. Definition of done (v1 / Phase 3 default-on)

Prose editing (headings, paragraphs, lists, block-quotes) works natively: Return
splits correctly in interior and last-block positions; Backspace merges across
boundaries; ⌘A + Delete clears the document; the caret is always a real bar of
correct height; typing never lands in the wrong block; a paragraph morphs to a
heading/list mid-edit without losing the caret; byte-lossless round-trip holds for
untouched regions; IME composes correctly; and the headless harness covers every
one of these as a standing regression gate. Complex blocks are editable as raw
source. The projection machinery listed under RIP is deleted.
