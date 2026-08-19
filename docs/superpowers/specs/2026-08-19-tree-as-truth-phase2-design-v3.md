---
title: Tree-as-truth Phase 2 — the live editor (Design v3, Option B: tree owns undo + its own view)
status: SUPERSEDED by v4. Two adversarial reviews found the architecture SOUND but
  (1) v3 never chose how the tree backs the text view — the custom-provider reading loses
  textContentStorage.textStorage and darkens the decoration/settle/dirty machinery;
  (2) three persistence-bridge gaps (dirty flag, own-save echo, deactivation reparse
  cost), two silent-data-loss class. v4 keeps the stock NSTextContentStorage and has the
  tree drive it by strictly-structural projection, and closes all three gaps.
  Activation-via-EditMapping was upheld as plannable-now with existing tests.
created: 2026-08-19
supersedes: 2026-08-19-tree-as-truth-phase2-design-v2.md (v2, rejected — byte-native substrate was the flaw)
parent: 2026-08-19-tree-as-truth-editing-design.md (master spec — this is its original Phase 2, restored)
builds on: Phase 1 (Sources/QuoinCore/EditableDocument/, delivered)
decision: Clint chose Option B (2026-08-19) — "tree owns undo + its own view," the truest reading of
  "full tree-as-truth, re-home honestly."
grounded-by: a code survey (2026-08-19) pinning the four starting-point facts cited throughout.
---

# Phase 2 v3 — the live editor, tree owns undo and its own view layer

## Why v3 exists

v1 was a happy-path account. v2 tried to keep the tree's benefits while reusing the
**byte-native substrate** (the Phase-3 island recycler + `DocumentSession`'s
character-level undo). Two adversarial reviews rejected v2 with one convergent root
cause: the tree's promised properties — stable structural identity, no byte offsets
on the edit path — are **destroyed at every bridge crossing** into that substrate.
The undo coalescer only merges single-character byte edits; `build(parsing:)` mints
fresh NodeIDs on every republish; `undo()`/`redo()` carry no caret to restore from;
the recycler's row model is byte-range end to end.

v3 removes the substrate that caused this. **The tree owns editing AND undo AND its
view layer. `DocumentSession` narrows to pure persistence, and its bridge is crossed
only on save and external change — never per keystroke.** This is the master spec's
original Phase 2 ("`NSTextContentManager` over the tree"), restored after v1/v2's
recycler detour.

## Grounding facts (verified in code, 2026-08-19)

These four facts are load-bearing; the design cites them instead of assuming.

1. **The tree-backed content manager is greenfield.** No custom
   `NSTextContentManager`/`NSTextContentStorage`/`NSTextElementProvider` exists;
   every TextKit-2 stack uses the stock classes
   (`MarkdownReaderView.swift:347`, `BlockRenderCell.swift:56`). **But Option B's
   shape is the *monolith's* shape** — one `NSTextView`, decoration drawing in
   `QuoinTextView.drawBackground`, active-block-source reveal via
   `MarkdownSourceStyler` — *not* the recycler's N-text-view shape. So v3 **evolves
   the monolith's storage/edit model to tree-as-truth**, keeping its working view
   shell; it does not invent a new view paradigm.
2. **The persistence bridge is narrow.** `DocumentSession.open(fileURL:)` /
   `init(source:)` / `saveNow()` / `apply(source:)` (wholesale external adopt) are
   the surface v3 keeps. `applyEdit(_:baseRevision:…)`, `undo()`/`redo()`, the
   `undoStack`/`redoStack`, `TypingRun` coalescing, and `staleEditBase` are
   keystroke-path plumbing the tree path **bypasses**. Confirmed:
   `undo()`/`redo()` return `QuoinDocument?` with **no caret**
   (`DocumentSession.swift:775,796`) — so undo caret restoration cannot come from
   the session; it must be tree-owned. `adoptExternal` clears the undo stacks and
   bumps `contentRevision` because "byte-offset edits computed against the OLD
   source splice stale bytes at stale offsets" (`DocumentSession.swift:340`) — in
   v3 the tree owns edits, so nothing feeds `applyEdit` per keystroke and that whole
   hazard is absent by construction.
3. **`EditMapping` is reusable for activation.**
   `EditMapping.sourceOffset(forRenderedOffset:renderedText:sourceText:)` lives in
   **QuoinCore** (`SourceEdit.swift:121`), is a pure two-pointer alignment
   (rendered projection → source slice, both UTF-16), is already Linux-testable, and
   is exactly what the activation click needs. It is NOT in the deleted monolith
   view; the "vaporware" finding was true only for the recycler (which forwards raw
   clicks and never calls it).
4. **The island recycler is superseded, not reused.** `QuoinEditorKit`
   (`BlockRecyclerView`/`BlockRenderCell`/`BlockEditorCell`/`IslandController`,
   ~5,900 lines) is N separate `NSTextView`s on an `NSTableView`, byte-range-driven —
   the opposite of one `NSTextView` + a custom content manager. Its **pure-logic**
   modules port to v3 (`ListContinuation` = Return-in-list/quote; `UTF8IndexMap`/
   `IslandCaretMapping` = UTF-8/16 offset math; `DecorationDraw` geometry); its
   **view layer does not**. This is a real cost of Option B and is stated, not hidden.

## Architecture

### One `NSTextView`, a tree-backed content manager, active-block-source reveal

- A custom `NSTextContentManager` (an `NSTextElementProvider`) vends **one
  `NSTextElement` per tree block segment**, in tree order. Trivia segments
  (front-matter, footnote/link-reference definitions, blank runs) are not elements
  the caret can enter — they are preserved bytes rendered inertly, matching today's
  behavior.
- **Inactive block → rendered projection.** Its element's attributed content is the
  `AttributedRenderer` projection of that block (heading big, bold actually bold),
  produced from the whole-document parse (see "Rendering" for why whole-document).
- **Active block (caret inside) → literal source.** Its element's content is the
  block's `text` styled by `MarkdownSourceStyler` — character-for-character 1:1 with
  `block.text`. This is exactly the monolith's reveal behavior, now scoped to one
  tree block.
- **The caret within the active block is a native `NSTextView` offset into the
  source element, and that offset *is* `EditPosition.offsetUTF16` into `block.text`,
  1:1.** There is no per-keystroke rendered↔source mapping and no document byte
  offset anywhere on the edit path. This is where the bug class dies.

### Why this kills the bug class (and what it honestly does not)

- **Document-byte desync is gone by construction**: the caret is
  `(NodeID, offsetUTF16-in-block.text)`, never a document byte offset, so cross-block
  stranding and merge-offset corruption cannot occur.
- **Within-block rendered↔source desync is confined to a single event: activation.**
  Clicking a *rendered* (inactive) block gives a native character index in that
  block's rendered text; v3 maps it to a source offset with the reused
  `EditMapping.sourceOffset(renderedText: <block's rendered .string>, sourceText:
  block.text)`, then flips the block to source and places the caret there. After
  activation everything is source-native. The original field bug ("cursor lands
  between the n and g") is a hit-map correctness bug on this one path — proven dead by
  a heading fixture, not structurally impossible (no design makes rendered↔source
  identity go away for markdown WYSIWYG).

### Editing: native input intercepted into tree transforms

- Typing/deletes inside the active block: intercept via the text view's input path
  (`shouldChangeText`/`insertText`/`deleteBackward`) and apply the Phase-1 tree
  transforms `insertText(_:at:)` / `deleteRange(inBlock:_:)` to `block.text`, then
  update **only that block's element** (the source element re-styles; no other
  element changes, no document splice, no reconcile).
- **Return = `splitBlock(at:)`** the Phase-1 transform: the active block splits into
  two block segments; the content manager gains one element; the caret moves to the
  new block's element at offset 0. An end-of-block split makes a **real empty block
  segment** — a genuine empty `NSTextElement` the caret sits in (see Risk R1 on
  empty-element layout). No virtual line.
- **Backspace-at-offset-0 = `joinWithPrevious`** the Phase-1 transform: two elements
  become one; caret at the join. Split and join are inverses (Phase-1 proof).
- **List/quote continuation** on Return inside a list item reuses `ListContinuation`
  (ported from QuoinEditorKit) to decide bullet/ordered/task/quote prefix carrying.

### Undo: tree-owned snapshot stack with ported coalescing

The sync-bridge reviewer's recommendation ("own a tree-snapshot undo stack — likely
the real answer, not the fallback") is adopted.

- **A stack of `EditableDocument` snapshots** (value type; segment array is
  copy-on-write, so a snapshot that shares pristine source spans is cheap). Each
  entry carries the `EditPosition` caret at the time — so undo restores the caret
  *structurally*, the thing the session could never supply.
- **Coalescing predicate ported from `DocumentSession.TypingRun`** (the proven
  rules: a contiguous run of non-whitespace single-character inserts is one undo
  unit; whitespace, a caret jump, or a structural op breaks the run). We port the
  *predicate*, not the byte machinery — it decides *when to push a new snapshot*,
  not how to splice bytes.
- **Edit-menu wiring for free**: register each undo/redo with the window's
  `NSUndoManager` via `registerUndo(withTarget:)` and `setActionName` (the tree
  transform names — "Typing", "Split Paragraph", "Delete"). Enable state and menu
  titles come from `NSUndoManager` natively. This replaces `DocumentSession`'s
  `UndoActionName` wiring on the tree path.
- Stack depth is bounded (a configurable cap, e.g. 200 entries) — stated as Risk R4.

### The persistence bridge (narrow — crossed on save + external only)

`DocumentSession` stays the on-disk authority; the tree is the in-memory truth.

- **Load**: `EditableDocument.build(parsing: session.document.source)` at open. (The
  session still parses to `QuoinDocument` for its own bookkeeping; the tree builds
  from the same source string.)
- **Save / autosave**: the tree serializes (`serialized()`, Phase-1 byte-lossless)
  and the source is handed to the session via `apply(source:)` then `saveNow()`.
  Because the tree owns undo, `apply(source:)`'s stack-clear + revision-bump is
  correct, not lossy. Crossed on a debounce/save boundary — **not per keystroke**.
- **External change**: when the session detects an on-disk change and publishes a new
  source, the tree **rebuilds** `build(parsing: newSource)` and restores the caret
  structurally. This is rare (external edit / conflict resolution), so the NodeID
  churn v2 suffered every keystroke happens here only, and only when the document
  genuinely changed underneath the user. Identity preservation across this rebuild
  (correlate surviving blocks by content so the focused element isn't lost) is a
  named task, not free — see Open Question 2.
- **What v3 does NOT use on the tree path**: `applyEdit`, `undo`/`redo`, the session
  undo stacks, `TypingRun`, `staleEditBase`. They remain for the old path until
  Phase 3 cutover.

### Rendering: whole-document parse for cross-block references

The rendered projection of *inactive* blocks must resolve reference-style
links/images/footnotes, whose definitions are trivia (a document-wide concern, the
v1 CRITICAL). v3:

- Renders inactive blocks from a **whole-document parse of the tree's current
  `serialized()`** (a `QuoinDocument`), exactly as the app renders today — reference
  maps and footnote ordinals resolve correctly. Because the tree owns editing and
  serialize is byte-lossless, this parse is always the parse of the tree's current
  bytes.
- The whole-document reparse is **not on the keystroke path**: while a block is
  active it shows *source* (no projection needed), so typing only re-styles the
  active source element. The projection reparse happens on **deactivation** (caret
  leaves the block) and on structural ops that change other blocks' rendering
  (e.g. adding a reference definition) — bounded, not per character. Measure; cache
  the projection keyed by block-text hash if needed (Risk R3).
- **Live kind reclassification** (typing `> ` makes a paragraph a quote) resolves on
  the next projection reparse at deactivation — explicit, not implicit.

### IME: native, with a structural-op gate

One `NSTextView` means composition is **native** — no per-cell IME juggling, no
re-vend mid-composition. The only rule:

- While `hasMarkedText()` is true, **no structural transform** (`splitBlock`/
  `joinWithPrevious`) and **no external-adopt rebuild** — Return/Backspace fall
  through to the IME, and an inbound external republish defers until composition ends
  (the bidirectional gate the seam reviewer demanded). Composition-end is the
  `hasMarkedText()`-false edge on `textDidChange`; the active source element syncs
  to the committed text then.

### Selection: cross-block is now native

One `NSTextView` gives **native selection across blocks** — so v2's "multi-block
selection is a non-goal" concession is lifted for *selection and copy*. Multi-block
*edits* (a delete or paste that spans block boundaries) still need a tree transform
that splits/joins across the selection; that transform is a named Phase-2 task
(Open Question 3), not assumed free.

### Decorations: ported from the monolith

Code canvases, callout boxes, quote rules, table rules, diagram frames, the
front-matter chip — drawn in `drawBackground(in:)` against TextKit-2 fragment frames,
ported from `QuoinTextView` + `DecorationDraw` geometry. Same single-text-view model
they already use today; the block ranges come from tree elements instead of
`QuoinAttribute.blockID` runs.

## Sub-phase outline (each adversarially re-reviewed before planning)

1. **The tree-backed content manager, read-only.** A custom `NSTextContentManager`
   vending one rendered `NSTextElement` per tree block; a single `NSTextView`
   displays a document identically to the monolith (same rendered pixels, a
   reference-link + footnote fixture). **Prototype the empty-block element here**
   (Risk R1) — this sub-phase is the buildability gate for the whole approach.
2. **Activation + source reveal.** Click a block → `EditMapping.sourceOffset` maps
   the click → flip that element to `MarkdownSourceStyler` source → place the
   structural caret. Deactivation reflows to projection. Test: the heading-click
   coordinate fixture (the field bug) lands correctly.
3. **Typing into the active source element.** Native input → Phase-1
   `insertText`/`deleteRange` on `block.text` → re-style only that element. Test:
   typing serializes byte-correctly; other elements untouched; autocorrect/smart
   substitutions off; CJK composition does not corrupt.
4. **Tree-owned undo.** Snapshot stack + ported coalescing predicate + `NSUndoManager`
   registration. Test: undo granularity (word, not sentence); ⌘Z restores caret
   structurally; redo; Edit-menu titles/enable.
5. **Return = split / Backspace = join**, list/quote continuation via
   `ListContinuation`, IME-gated. Test: the field-bug scenarios (heading survives;
   one-Enter-one-Backspace) through the real keystroke path; empty-block row.
6. **The persistence bridge.** Load builds the tree; save serializes via
   `apply(source:)`+`saveNow()`; external-change rebuild with identity-preserving
   caret restore, composition-gated. Test: round-trip byte-lossless; external-change
   adopt mid-session; save-after-edits.
7. **Whole-document projection + cross-block references + kind reclassification** on
   deactivation. Test: reference/footnote fixture re-resolves; `> ` reclassifies.
8. **Viewport invariant + full regression suite through the GUI path**
   (RevealFidelityTests / CaretLineAnchorTests discipline extended to the tree view).
9. **Cutover prep** (flag still off; interim-guard removal is Phase 3).

## Open questions for adversarial re-review (attack these)

1. **Custom `NSTextContentManager` buildability + empty-element layout.** Is a
   tree-backed `NSTextElementProvider` with a genuinely empty block element
   (zero-length, must still lay out as a caret line) actually workable in TextKit 2,
   or does AppKit collapse it (forcing a 1pt sentinel glyph)? Sub-phase 1 is the
   prototype gate; is it correctly placed *first*?
2. **Identity-preserving rebuild on external adopt.** `build(parsing:)` mints fresh
   NodeIDs; on an external change while a block is focused, how is the focused
   element kept alive / the caret re-placed? Correlate surviving blocks by content
   hash? Is that sound when the external change touched the focused block itself?
3. **Multi-block edit transforms.** Native selection spans blocks; a delete/paste
   across the selection needs a tree transform that splits the boundary blocks and
   joins the remainder. Is that transform in Phase-1's vocabulary
   (`splitBlock`+`joinWithPrevious` composition), or a new primitive? Is it in Phase-2
   scope or deferred?
4. **Undo snapshot cost.** Is a snapshot-per-undo-unit stack acceptably cheap given
   `EditableDocument`'s COW segment array, or does a large document + deep history
   blow memory (needing inverse-transform entries instead of full snapshots)?
5. **Whole-document reparse cadence.** Is "reparse the projection on deactivation"
   genuinely off the hot path, or do common interactions (arrow-keying between
   blocks) trigger it often enough to matter? Measure target.
6. **Decoration geometry over tree elements.** Does driving `drawBackground` from
   tree-element fragment frames (instead of `blockID` attribute runs) preserve the
   settled-draw viewport discipline, or is there a re-entrancy hazard the monolith
   avoids only because its storage is monolithic?
