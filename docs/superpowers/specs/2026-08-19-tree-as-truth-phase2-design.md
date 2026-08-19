---
title: Tree-as-truth Phase 2 — the live editor (tree-native controller over the recycler)
status: NEEDS REVISION — two adversarial reviews found load-bearing flaws (see "Critical-review findings")
created: 2026-08-19
parent: docs/superpowers/specs/2026-08-19-tree-as-truth-editing-design.md
builds on: Phase 1 (Sources/QuoinCore/EditableDocument/, delivered 2026-08-19)
---

# Phase 2 — the live editor

## Critical-review findings (2026-08-19) — DO NOT plan against this doc until revised

Two adversarial design reviews (architecture + correctness), each grounded in the
real recycler/IslandController/DocumentSession code, found the design below is a
happy-path account that assumes away the hard obligations. The core error: it
mistook **IslandController's *reconcile* burden for its *entire* burden.** Most of
its ~2,100 lines are undo, IME, external-change reconciliation, and stale-base
protection — correctness the tree does NOT obsolete and that must be RE-HOMED,
not deleted.

**Must resolve in the DESIGN before any plan (each changes the shape of the
controller):**
1. **Undo/redo.** Undo lives entirely in `DocumentSession`'s SourceEdit stack
   (`recordUndo`, coalescing, Edit-menu titles). A controller that mutates the
   tree and autosaves `serialized()` records nothing → ⌘Z is dead. The parent
   spec claimed "each transform is a single undo unit" with no mechanism.
2. **Save / external-change / concurrency.** Feeding `serialized()` to autosave
   bypasses stale-base rejection (`staleEditBase`), the external-change merge
   banner (→ silent data loss), and the edit FIFO; and there is no path to
   rebuild the tree when `DocumentSession` republishes an external change.
3. **IME / marked text.** IslandController's `blockedIME` state machine is the
   only guard against split/join/re-vend mid-composition; the design deletes it
   → CJK/emoji corrupts on the first composed word, and re-vend resets the IME.

**Must be named as explicit tasks/policies in the design (resolvable in the plan
only once stated):**
4. **Single-block isolated parse is wrong for rendering.** Reference-style
   links/images/footnotes resolve against a document-wide reference map whose
   definitions are *trivia* (a different segment); `.blocks.first` also
   truncates any block whose text became multi-block (soft break, paste,
   dictation). Read rendering must come from a document-wide resolved parse or
   the tree's retained structure, not per-block re-parse. Also makes `kind`
   flip mid-edit — needs a stated reclassification policy + a one-top-level-block
   invariant on `block.text`.
5. **Rendered→source caret mapping on activation.** The tree removes *document*-
   byte desync but NOT *within-block* rendered↔source desync — a click on the
   rendered H1 must map to a `block.text` (source) offset. This is the exact
   coordinate bug the rearch exists to kill; it must be re-homed at activation.
6. **Caret↔text-view sync** must commit to whole-block-sync (`block.text =
   textView.string` on `textDidChange`), not the incoherent "replay via
   insertText/deleteRange."
7. **Multi-block selection / cut / paste** has no representation today (one
   NSTextView per row); the design must at least name it as a scope boundary.

**And the recycler coupling is deeper than "keep the cells" implied:**
`BlockRecyclerView` (1,747 lines) is welded to the concrete `IslandController`
at ~10 sites and is byte-range-driven throughout (`numberOfRows` →
`document.blocks.count`, the preserve/park/reanchor engine keyed on byte
offsets); a synchronous "re-vend the editing row" *destroys* the live
NSTextView — structural ops deliberately MOVE the cell (`promoteRow`), never
re-vend it. There is no protocol seam to slide a new controller into.

**Consequence:** the "tree obsoletes IslandController" premise that drove the
integration-approach choice is only true for the reconcile subset. The approach
must be reconsidered — see the reframed options carried to the next design pass.

---

# Phase 2 — the live editor (ORIGINAL DRAFT, superseded by the findings above)

## Goal

Make the Phase 1 `EditableDocument` tree the **live editing model** behind the
existing block recycler, so that in the running app Return splits a node,
Backspace joins nodes, typing mutates a node's text, and every edit is a
synchronous tree transform — no byte-range reconcile, no async echo, no virtual
line, no coordinate-space desync. Behind the existing `QuoinEditorRecycler`
feature flag; the old path ships untouched until Phase 3.

## The decision that shapes this (Clint, 2026-08-19)

Keep the recycler's hard-won per-block **cell + TextKit-2 layout machinery**
(`BlockRecyclerView`, `BlockRenderCell`, `BlockEditorCell`, `IslandTextView`);
**replace `IslandController`'s byte-reconcile brain** with a lean tree-native
controller. The tree makes most of `IslandController`'s ~2,100 lines
unnecessary — its job is reconciling byte-range edits back into the string, and
there are no byte ranges to reconcile when the tree is the truth. This sheds
complexity rather than modifying it.

## The seams (verified against the current code)

- **Row model.** `BlockRecyclerView` renders one row per block; `setDocument`
  seeds rows from a block list; `viewFor` dequeues a `BlockRenderCell` (read) or
  a `BlockEditorCell` (the single active editing row). Phase 2 drives the rows
  from the tree's `.block` segments instead of `QuoinDocument.blocks`.
- **Read rendering.** `BlockRenderCell.configure(block:renderer:width:)` uses
  `AttributedRenderer` to produce a rendered fragment. `AttributedRenderer`
  consumes a parsed `Block` (kind + inlines), so a tree block's flat `text` is
  given a **single-block parse** (`MarkdownConverter.parse(block.text).blocks.first`)
  to render it. This also **re-derives the block's kind** from its current text
  (closing the Phase 1 Task-5 watch-item: a split empty paragraph that inherited
  `heading` kind renders correctly as a paragraph once its text is `""`).
- **Edit seam.** `IslandTextView.doCommand(by:)` already routes
  `insertNewline:`→`onInsertNewline` and `deleteBackward:`→`onDeleteBackward`
  closures that return `true` when "a structural op handled it." The tree
  controller sets these to call the Phase 1 transforms. Ordinary typing/deletes
  fall through to the native text view, mirrored into the tree via the text
  view's delegate (`textDidChange` / `shouldChangeText`), through
  `insertText`/`deleteRange`.
- **Caret.** The structural `EditPosition(NodeID, offsetUTF16)` maps to the
  active `BlockEditorCell`'s `NSTextView` selection (offsetUTF16 within that
  block's text) and back. There is no document byte offset anywhere on the edit
  path — the desync class is structurally absent.

## Architecture — `TreeEditorController`

Owns an `EditableDocument`; drives the recycler; translates input to transforms.

```
TreeEditorController
  var doc: EditableDocument                 // the live truth
  var caret: EditPosition?                  // structural
  let recycler: BlockRecyclerView

  // input → transform → view
  onInsertNewline():   doc.splitBlock(at: caret) → caret = result → refreshRowsAround(caret)
  onDeleteBackward():  if caret at offset 0 → doc.joinWithPrevious(caret.block) → refresh
                       else → native delete, mirrored via textDidChange → insertText/deleteRange
  onType(s):           doc.insertText(s, at: caret) → caret advances
  onDeleteRange(r):    doc.deleteRange(inBlock:_, r) → caret at r.lowerBound

  // view
  blocksForRows():     doc.segments.compactMap { if case .block(let b) = $0 { b } }
  renderRow(block):    BlockRenderCell.configure(parse(block.text).firstBlock, …)
  activateRow(block):  BlockEditorCell.configure(slice: block.text, …); place caret
```

Key properties:

- **Synchronous.** A keystroke mutates the tree and re-vends the affected rows
  in the same run-loop turn. No `onReconcile`, no debounce, no in-flight state.
- **Row-local refresh.** A transform touches at most two blocks (split: one → two;
  join: two → one; typing: one). Only those rows re-vend; the recycler's diffing
  handles it.
- **The empty paragraph is a real row.** A split-at-end makes an empty `.block`;
  its `BlockEditorCell` is an empty editable line the caret sits in. No virtual
  line, no clamp.

## Save/load

Load: `EditableDocument.build(parsing: fileText)`. Save: `doc.serialized()` (the
Phase 1 byte-lossless serializer) → disk. The `DocumentSession` autosave path is
fed `serialized()` instead of the reconciled string. Byte-lossless for untouched
regions by Phase 1's proof.

## The footnote / link-reference-definition seam (Phase 1 watch-item)

Footnote and link-reference definitions are **trivia** in the tree (the parser
drops them from `blocks`). In read mode they render as part of the document's
footnote section (unchanged — the app already gathers them). In EDIT mode they
are not a row and the caret cannot enter them. Phase 2 scope: leave them
read-only trivia (byte-preserved, matching today's behavior where footnote defs
are also special). Promoting them to editable block nodes is a bounded
follow-up, tracked, not blocking the core Return/Backspace/typing experience.

## Testing strategy

Phase 2 is macOS/AppKit; it uses the recycler's existing harness pattern
(`EditorTestHarness` + `OffscreenTestWindow`, already used by the island tests):

- **Transform-through-the-view tests**: drive `harness.pressReturn()` /
  `pressBackspace()` / `type()` on a real offscreen recycler wired to a
  `TreeEditorController`, and assert (a) the tree serializes to the expected
  bytes and (b) the caret lands in the expected block at the expected offset.
- **The regression scenarios as GUI-path tests**: the heading-corruption
  sequence, one-Enter-one-Backspace, mid-paragraph split — driven through the
  real keystroke path, asserting byte-lossless results. These are the same
  properties Phase 1 proved on the model, now proven through the view.
- **Viewport invariant**: the caret line's screen position stays put across a
  transform (the recycler's existing `performPreservingViewport` bracket
  applies; extend its geometry tests for the tree path).
- **Round-trip through the real DocumentSession**: load → edits → save is
  byte-lossless for untouched regions.

## Phases within Phase 2 (plan outline)

1. **`TreeEditorController` skeleton + row model** — own an `EditableDocument`,
   vend read rows from its blocks, render each via a single-block parse. No
   editing yet. Test: a document renders identically to the old path (same rows).
2. **Activate a block for editing** — click/focus a row → `BlockEditorCell`
   seeded with the block's text; caret ↔ `EditPosition`. Test: activation places
   the caret; deactivation is clean.
3. **Typing** — mirror native inserts/deletes into the tree via the text view
   delegate; the row re-vends from the mutated block. Test: typing serializes
   byte-correctly; other rows unchanged.
4. **Return = splitBlock** — `onInsertNewline` → tree split; the new block is a
   real row; caret in it. Test: mid + end-of-block; the empty-paragraph row.
5. **Backspace = joinWithPrevious** — `onDeleteBackward` at offset 0 → tree join;
   caret at the join. Test: the heading scenario byte-preserved; one-Enter-one-
   Backspace; first-block no-op.
6. **Save/load through DocumentSession** — load builds the tree, save serializes
   it; autosave path swapped behind the flag. Test: round-trip byte-lossless.
7. **Viewport invariant + the regression suite through the GUI path** — the
   caret-line-stays-put geometry tests and the exact field-bug scenarios driven
   through the real recycler.

## Non-goals (Phase 2)

- `IslandController` is not deleted yet — the old recycler path stays until
  Phase 3 flips the flag and retires it. Phase 2 adds the tree path alongside.
- List/quote marker continuation, editable footnote nodes, inline canonical
  serialization — later.
- The flag defaults OFF; Phase 3 is the cutover + interim-guard removal.

## Risks

- **Per-block re-parse cost** for rendering (single-block parse per changed
  block). Bounded (one block per keystroke); measure, cache the rendered
  fragment keyed by the block's text hash if needed.
- **Recycler integration surface**: the row-vending / focus / re-vend machinery
  is intricate. Mitigation: Phase 2 Task 1 is a read-only skeleton that proves
  the row model before any editing; each later task is one narrow behavior
  through the existing harness.
- **Two live editor paths** behind the flag during Phase 2 — acceptable and
  reversible; the flag is the safety switch.
