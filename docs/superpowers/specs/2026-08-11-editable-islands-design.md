---
title: Editable-Islands editor architecture (replacing the read-only projection)
created: 2026-08-11
status: DESIGN — approved to spec; per-phase implementation plans follow
supersedes: the read-only "projection editor" model (shouldChangeTextIn → false)
related:
  - docs/reference/architecture.md (§ editing model — to be rewritten per phase)
  - docs/reference/invariants.md (viewport/caret invariants — several retired)
  - CARET-1 series (2026-08-10) — the last symptomatic fixes before this rearchitecture
---

# Editable-Islands editor architecture

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
   whitespace into a neighboring block's editable slice (`editableSlice`,
   `caretMapping`, `compressInteriorBlankLines`, `clampTrailingNewlinePhantom`,
   `occupiableSeparator`). After a re-parse the caret snaps to the nearest node
   that *does* exist — which is why pressing Return at the end of a heading that
   has body text below it lands the caret on the wrong line and typing appends to
   the heading (`Welcomedddddd`), and why "⌘A then Delete" does nothing
   (multi-block delete was never expressible).

2. **The real edit+caret path is untested.** It lives in an `@MainActor`
   view-model (`ReaderModel`) plus the `NSTextView` delegate plus an async
   "echo" round-trip — and there is no test that drives that real path. Fixes
   written against the *pure helper functions* pass while the app stays broken
   (shipped green-but-broken repeatedly).

**The fix is architectural, not another patch.** In the editable-islands model,
inactive content is not *text the caret must avoid* but *attachments the caret
cannot enter*. There is no nameless region between nodes; the caret only ever
lives inside one real, editable block. The synthetic-blank-line machinery, the
absorbed slices, and the four-space caret re-derivation are **deleted, not
fixed**.

## 2. Goals / non-goals

**Goals**
- Native OS-owned typing, caret, selection, and IME inside the block being
  edited. Editing correctness comes from the platform, not hand-rolled mapping.
- Preserve the three hard product constraints: **byte-lossless** round-trip
  (untouched regions serialize identically), **WYSIWYG** rendering of non-active
  content, **zero JavaScript** at runtime.
- Reuse the existing block-WYSIWYG renderer and the entire QuoinCore engine
  unchanged.
- A **headless end-to-end test harness** that drives the real editor — the
  standing gate that makes green-but-broken impossible.
- Migrate as an **incremental strangler**: every phase leaves the app
  buildable/usable (behind a feature flag until proven).

**Non-goals (v1)**
- Structured in-place editing of complex blocks. v1 is **prose-first**: headings,
  paragraphs, lists, and block-quotes get full native island editing; code
  blocks, tables, math, and diagrams are edited as their **raw
  Markdown/source text** in the island (multi-line, no in-cell widgets). Fancy
  structured editing (WYSIWYG table cells, grid Tab navigation beyond simple
  field hops, language-aware code behavior) is deferred.
- Collaborative editing, multi-caret. Out of scope.

## 3. Architecture — storage model

**One `NSTextView` backed by the default `NSTextContentStorage` /
`NSTextLayoutManager`**, whose content stream mixes exactly two element kinds:

- **Inactive block → a single-character `NSTextAttachment`** (`U+FFFC`) that
  draws the block's existing WYSIWYG rendering via a custom
  `NSTextLayoutFragment` subclass. It is atomic and non-editable; its bytes are
  never materialized as text, so **byte-losslessness is free** — an untouched
  block is literally never decoded/re-encoded.
  ```
  final class BlockAttachment: NSTextAttachment { let blockID: BlockID; let revision: UInt64 }
  ```
  Prefer a custom `NSTextLayoutFragment` (consistent selection rects/baselines)
  over an `NSTextAttachmentViewProvider`. The fragment calls the KEEP renderer
  (`AttributedRenderer.render(block:…)`) and the existing decoration drawing.

- **The one active block → its real Markdown source as editable text**, styled
  with an optional lightweight source syntax highlight. This region is what the
  OS edits natively.

**`ProjectionIndex`** (MainActor) is the single mapping authority:
```
enum SpanKind { case attachment(BlockID); case editable(BlockID) }
struct ProjectionSpan { let kind: SpanKind; var storageRange: NSRange; var byteRange: Range<Int> }
// display-ordered [ProjectionSpan]; EXACTLY ONE .editable at any time.
```
Every inactive block occupies exactly **1 UTF-16 unit** in storage; the active
block occupies N units equal to its decoded text length. This makes
storage-index ↔ byte-offset mapping deterministic.

## 4. Active-island swap choreography

Triggered when the user clicks a block or arrows/selects across the active
block's edge. Swap is one atomic transaction:

1. **Capture** old active id, target id, `scrollView.documentVisibleRect.origin`,
   and desired entry affinity (arrow direction, or click x/y).
2. **Refuse to swap while `textView.hasMarkedText`** (IME composition) — queue
   the intent, process on `unmarkText`.
3. **Finalize the old island**: if it has uncommitted edits, compute one byte
   patch (old block byteRange → edited bytes), `await DocumentSession.apply` →
   new bytes + AST revision + refreshed block catalog.
4. **Rebuild only the neighborhood spans** from the new AST (not the whole doc);
   bump revision.
5. **`performEditingTransaction`** on the content storage: replace the old
   editable range with a fresh `BlockAttachment`, replace the target block's
   attachment char with the editable source substring; update `ProjectionIndex`
   in lockstep.
6. **Place the caret**: click → map to local offset via a line/column hit-test
   the renderer exposes (safe default until then: start/end by click-x half,
   and line N by `boundsHeight/lineHeight`); arrow entry → offset 0 (entering
   from left) or end (entering from right); carry `goalColumn` for vertical
   motion.
7. **Restore scroll**: `scrollRangeToVisible` for the caret; otherwise leave
   TextKit's scroll.

## 5. Edit → Markdown reconciliation

- **Intra-island typing stays local to the `NSTextView`** (fast, native IME).
  The model splice is **debounced (~150–250 ms idle)**, and forced immediately
  on: (a) island swap, (b) structural boundary actions (split/merge/list rules),
  (c) app-level reads (save, export, search).
- **Splice** = take the island's edited `String`, build **one byte patch**
  replacing the block's known `byteRange`, `DocumentSession.apply`, update the
  active span's `byteRange`. Byte-losslessness holds because only the active
  block's range (and explicit boundaries on structural ops) is ever patched.
- **Split (Return at a structural point)** — driven by the KEEP `ReturnSemantics`
  rule table, but as a *native newline that reconciles to the grammar*, not a
  synthesized absorbed slice:
  - Heading end / paragraph split: insert the real `\n\n`, flush + reparse,
    activate the resulting new/second block, caret at its start.
  - List item: non-empty item → new item with the same marker/indent
    (native insertion of `\n` + marker); empty item → outdent/exit (delete
    marker → paragraph). These flush immediately (neighbor attachments change).
- **Merge (Backspace at block start / Delete at block end)** — intercept when
  selection length 0 and the caret sits at the island edge adjacent to an
  attachment; apply the boundary byte patch per the block-type rule; reparse;
  activate the merged block with the caret at the join.
- **Cross-block selection delete (⌘A + Delete)** — convert the anchored selection
  to a minimal set of contiguous byte ranges, delete in one patch, reparse, set
  the caret to a boundary anchor at the deletion start.

## 6. Selection anchors (stable across re-parse)

```
struct BlockID: Hashable      // stable across reparses via a diff-stability pass
struct BoundaryID: Hashable { let left: BlockID?; let right: BlockID?; enum Kind { case interBlock, blockStart, blockEnd } ; let kind: Kind }
struct ByteAnchor { enum Kind { case byte(Int); case boundary(BoundaryID) }; enum Affinity { case before, after }
                    var kind: Kind; var affinity: Affinity; var goalColumn: Int?; var revision: UInt64 }
struct SelectionAnchorRange { var start: ByteAnchor; var end: ByteAnchor }
```
- **BlockID stability**: an O(n) pass matches new blocks to old by overlapping
  byte range + node type; fall back to a `(type + normalized-content)` hash for
  moved/renamed nodes.
- **Mapping**: within the active island, `ByteAnchor.byte` → local byte offset →
  UTF-16 via a per-island `UTF8IndexMap` (cumulative offset arrays, regenerated
  on island text change) → storage `NSRange`. Inactive positions resolve to
  "before/after the attachment char" by affinity. Screen rects are standard
  TextKit for storage positions — no custom mapping.

## 7. Coordinate spaces after the change

Collapses to **two** for edits: **active-island local UTF-16 ↔ document byte
offset** (via the island `UTF8IndexMap` and the active span's base). Residual,
trivial mappings: byte offsets at inactive positions ↔ "before/after attachment
char"; storage position ↔ screen rect (native TextKit). `ByteAnchor` remains for
robustness across reparses/swaps.

## 8. The test harness (non-negotiable infrastructure)

A **new framework target `QuoinEditorKit`** holds the edit machinery
(`EditOrchestrator` (MainActor), `ProjectionIndex`, `BlockCatalog`, the
`DocumentSession` protocol seam) so tests can import it. Tests run in a **test
host app** (preferred over an offscreen window for CI stability) that
instantiates the *real* `NSTextView`/`NSScrollView`/delegate/orchestrator.

**Quiescence barrier**: `DocumentSession` increments a `UInt64` revision per
applied patch; the revision is stamped as an attribute on the projected storage
and mirrored on `orchestrator.currentRevision`. After each edit call the test
waits until `currentRevision == expected`, then `textLayoutManager.ensureLayout(
for: documentRange)`, then reads the caret rect.

**Drive edits through `NSTextInputClient`**: `insertText`, `insertNewline`,
`deleteBackward`, `moveRight/Left/Up/Down`, so the real delegate/structural paths
run. **Assert per scenario**: exact document bytes; AST shape around the edit
(node types/counts); active block id before/after; `selectedRange` maps back to
the expected `ByteAnchor`; **insertion-rect height ≥ a baseline threshold**
(the standing 2pt-dot regression gate); no residual marked text.

**Core scenarios (write first):** Return at end of interior heading (the prior
failure); Return at end of last block (control); Backspace merging a paragraph
into the prior heading; list-item split; list exit on empty item; ⌘A + Delete;
IME composition in the island (no flush/swap until composition ends).

## 9. Rip / Keep / Rebuild inventory

**REBUILD (the three seams the model replaces):**
- `Sources/QuoinRender/AppKit/ReaderCoordinator.swift` (~3,462 LOC) — the
  keystroke-intercepting delegate + caret re-derivation + edit-echo ledger.
  Portable sub-parts to re-wire (not rebuild): search highlighting, focus
  dimming, scroll anchoring, link/footnote plumbing, context-menu/annotation
  gestures, preview-panel choreography.
- `Sources/QuoinRender/AppKit/QuoinTextView.swift` (~990 LOC) — keep paste/image
  overrides, tracking areas, `menu(for:)`, decoration-drawing host; rip
  `CaretGapGeometry` + synthetic-caret drawing + viewport caret-pinning.
- `Sources/QuoinRender/AppKit/MarkdownReaderView.swift` (~908 LOC) — the
  `NSViewRepresentable` bridge + generation-counter caret-restore; keep the
  format-command/annotation/search/scroll-target command surface.
- `App/macOS/Sources/ReaderModel.swift` — REBUILD the edit+caret path
  (`activateBlock`+`CaretHint` switch, `restoreCaret`, `applyEdit`,
  activation-flip, rerender/echo); KEEP the block-command/table/structure/
  front-matter/suggestion/annotation operations (they apply `SourceEdit`s and are
  edit-model-agnostic).
- `ReaderScreen.swift` (~1,609 LOC) — wires `activateBlock`/caret/`onEditIntent`
  into SwiftUI; has REBUILD touch-points to audit.

**RIP (projection-only, deleted as replacements prove out):**
- In `AttributedRenderer.swift`: `editableSlice`, `caretMapping`,
  `compressInteriorBlankLines`, `clampTrailingNewlinePhantom`,
  `revealNeedsClampedSeparator`, `clampedSeparator`, `occupiableSeparator`,
  `renderEditableSource*`/`assembleRevealedFragment`/`RevealedFragment`,
  `revealStylerConfig`, `activeBlockEditUpdate`/`activationFlipUpdate`, and the
  `separator(…revealedSlice:)` variant. The `RenderedDocument` reveal fields
  (`activeBlockID/Kind/activeEditableRange/revealStyler`).
- `MarkdownSourceStyler.swift` (~557 LOC) — the caret-scoped span reveal (some
  active-block syntax highlighting may be re-adopted, but the collapse-others
  behavior is projection-specific).
- `CaretHint` (defined in MarkdownReaderView; produced/consumed across the three
  seams) — the four-space tag disappears.

**KEEP (reused unchanged):**
- `AttributedRenderer` block-WYSIWYG pipeline — every `render<Block>` + inline
  rendering + `blockSeparator`/`separatorLength`. **This becomes the
  attachment-fragment drawing.**
- All of `QuoinCore`: parsing, AST, `EditorCore`/`DocumentSession` (`SourceEdit`
  in / `QuoinDocument` out — the reconcile seam), `EditMapping` (UTF-8↔UTF-16
  conversion), `EditIntent` (smart-pair/typeover logic; re-point its caller),
  `ReturnSemantics` (rule table), exporters, Mermaid/Vinculum reexports,
  structure/table/front-matter editing.
- App shell/support: `Theme`, `BlockDecoration/Presentation/Accessibility`,
  `TableLayout`, `StructureRotor`, `AsyncImageStore`, `ScrollAnchorMath`,
  preview-panel, `FlipTransitionController`, sidebar/library, QuickLook,
  Spotlight, Intents.

**Hardest couplings (sequencing risk):**
1. `editableSlice` is shared by the full render AND the per-keystroke patch AND
   locked byte-identical by `ProjectorEquivalenceTests` — it can't be removed
   from one path without breaking the equivalence across all three. Untangle in
   Phase 2/3 as a unit.
2. The edit-echo generation-counter handshake spans three files and is
   load-bearing for *not dropping fast input today* — it must be **replaced**
   (native typing), not merely deleted, before it's removed.
3. `separator(…revealedSlice:)` branches reveal-vs-reading in one function
   touching every block boundary.
4. `CaretHint`'s `.rendered` vs `.source` spaces leak through the public
   `onActivateBlock` signature — the `NSViewRepresentable` API changes.
5. `ReturnSemantics` (KEEP) vs every consumer (REBUILD): same rule table, new
   mechanism (native newline reconciled at boundaries, not a synthesized slice).

## 10. Phased migration (strangler; each phase buildable, flag-gated)

- **Phase 0 — Foundations & harness.** Create `QuoinEditorKit`; define `BlockID`
  (stable), `ByteAnchor`/`BoundaryID`, `ProjectionIndex`, a `DocumentSession`
  revision counter; build the headless test-host harness + quiescence barrier.
  No visible change. Risk: low.
- **Phase 1 — Inactive blocks as attachments** (still fully read-only). Blocks
  render as `BlockAttachment` + custom `NSTextLayoutFragment` using the KEEP
  renderer; fix layout/hit-testing/scroll/accessibility (AXStaticText per block
  with an "Edit" action). Delete inactive-content blank-line clamp hacks. Flag.
  Risk: medium (layout correctness).
- **Phase 2 — One editable island.** Promote one attachment to editable source;
  swap choreography (no structural ops yet); debounced reconciliation; native
  typing/caret/IME. Harness assertions live: intra-block typing, swap in/out,
  caret stability, insertion-rect-height gate. Delete legacy caret re-derivation
  + echo handshake. Flag. Risk: medium-high (first real edits).
- **Phase 3 — Structural ops (closes the reported bugs).** Split/merge for
  headings, paragraphs, lists, block-quotes off `ReturnSemantics`; cross-block
  delete via `ByteAnchor` ranges. Delete `editableSlice`/blank-line synthesis.
  Full structural harness suite. Ship as **default** when green. Risk: high
  (behavioral breadth) — the riskiest phase.
- **Phase 4 — Complex blocks + polish.** Raw-text multi-line islands for
  code/quote/table (Tab between table fields); undo/redo across swaps;
  find-and-replace across attachments; accessibility polish. Retire the
  projection test suites; delete remaining projection caret code.

Each phase gets its **own implementation plan** (written when we reach it), so
plans stay bite-sized and we learn between phases.

## 11. The hard parts and how the design handles them

- **IME / marked text**: never flush, reparse, or swap while `hasMarkedText`;
  queue the intent, run it on `unmarkText`. Composition lives entirely inside the
  island range.
- **Lists / tables / code (multi-line islands)**: v1 edits them as raw source
  text; list Return/Backspace follow Markdown list rules with immediate flush;
  code blocks are literal multi-line islands (local edits until a fence line);
  tables are raw pipe text with simple Tab field-hopping.
- **Undo/redo across swaps**: allow the `NSTextView`'s local undo for intra-island
  typing; on flush, record the byte patch as one coalesced document-level
  `NSUndoManager` group (bracket the island rebuild with `allowsUndo=false` to
  avoid double application); structural ops are single grouped actions whose undo
  reapplies the inverse patch and swaps back. Tested.
- **Find-and-replace across islands**: search the bytes model; matches in the
  active island map to a local range; matches in attachments select the
  attachment char (with an "edit here" affordance) and apply as a byte patch.
- **VoiceOver / accessibility**: attachments expose `AXStaticText` with a concise
  serialization ("Heading level 2: Welcome", "List, 3 items", "Code block
  (Swift), 10 lines") and an "Edit" action that triggers the swap; the active
  island is a standard `AXTextArea`.

## 12. Testing strategy

- **New (the gate):** the `QuoinEditorKit` headless harness (§8) — every phase
  from 2 on is gated by it.
- **KEEP as safety net through the rearchitecture:** block-WYSIWYG render
  fidelity suites (`AttributedRendererSnapshotTests`, `RendererConformanceTests`,
  `BlockPresentationTests`, `TableLayoutTests`, diagram/math, accessibility
  tagging) and all QuoinCore parsing/session/exporter/structure suites — these
  don't change and prove the KEEP layer stays intact.
- **RETIRE with their mechanism (Phase 3/4):** the projection-specific suites
  (`CaretMappingTests`, `ExcessWhitespaceSliceTests`, `GapDeletionTests`,
  `ProjectorEquivalenceTests`, `KeystrokeReplayTests`, `EditEchoSerializationTests`,
  `ActivationFlipPatchTests`, `RevealFidelityTests`, `CaretGapGeometryTests`,
  `EditPathReturnTests`, etc.). The rule-level intent survives in
  `ReturnSemanticsTests`/`EditIntentTests` (KEEP).

## 13. Open questions / safest defaults

- **Click-to-caret precision inside an attachment**: safe default is start/end by
  click-x half until the renderer exposes line metrics; add a small renderer
  service (line count + approx line heights) to place the caret at the clicked
  line.
- **BlockID stability layer**: if not already present, implement the O(n)
  overlap+type match with a content-hash fallback (Phase 0).
- **Reconciliation debounce window**: default 200 ms; revisit if it feels laggy
  or races structural ops (structural ops always flush synchronously regardless).
- **Compound islands** (a table row spanning logic, quote continuations): v1
  keeps island == exactly one block; revisit in Phase 4 only if needed.

## 14. Definition of done (v1 / Phase 3 default-on)

Prose editing (headings, paragraphs, lists, block-quotes) works natively: Return
splits correctly in interior and last-block positions; Backspace merges across
boundaries; ⌘A + Delete clears the document; the caret is always a real bar of
correct height; typing never lands in the wrong block; byte-lossless round-trip
holds for untouched regions; IME composes correctly; and the headless harness
covers every one of these as a standing regression gate. Complex blocks are
editable as raw source. The projection machinery listed under RIP is deleted.
