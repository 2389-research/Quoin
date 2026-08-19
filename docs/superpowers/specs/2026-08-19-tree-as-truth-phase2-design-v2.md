---
title: Tree-as-truth Phase 2 — the live editor (Design v2, correctness-machinery re-homed)
status: RE-REVIEWED — NOT sound to plan against. Both adversarial reviews of v2
  reject it. Root cause: v2 layers the tree over the BYTE-NATIVE substrate
  (existing recycler + DocumentSession undo); the two sync-bridges are non-inverse
  at the identity and granularity layers, and the recycler seam re-exposes bytes.
  Superseded by the Option-B fork (tree owns its undo + its own TextKit-2 view);
  see "Re-review verdict (2026-08-19)" below.
created: 2026-08-19
supersedes: 2026-08-19-tree-as-truth-phase2-design.md (v1, found flawed)
parent: 2026-08-19-tree-as-truth-editing-design.md
builds on: Phase 1 (Sources/QuoinCore/EditableDocument/, delivered)
---

# Phase 2 v2 — the live editor, with the correctness machinery re-homed

v1 was a happy-path account that mistook `IslandController`'s *reconcile* burden
for its *entire* burden. Two adversarial reviews found it deletes undo, IME
composition, external-change reconciliation, and stale-base protection — none of
which the tree obsoletes. v2's job is to say exactly where each of those lives in
a tree-as-truth world, and to fix the rendering, caret-mapping, and coupling
errors. Nothing below is planned until this doc is re-reviewed.

## The load-bearing decision: tree drives interaction, DocumentSession stays the persistence + undo + concurrency authority

The crux the reviews named is "tree-as-truth vs. undo-lives-in-the-byte-session."
v2 resolves it by **separating the interaction truth from the persistence truth**
and keeping them in lock-step:

- **The tree (`EditableDocument`) is the live INTERACTION model.** Every keystroke,
  split, join, and caret motion is a structural tree operation. The rendered
  view and the caret are projections of the tree. This is where the bug class
  dies — there are no document byte offsets on the interaction path, so caret
  stranding and merge-offset corruption are structurally impossible.
- **`DocumentSession` stays the PERSISTENCE + UNDO + CONCURRENCY authority,
  unchanged.** It keeps owning: the on-disk bytes, the undo/redo stack with its
  coalescing and Edit-menu titles, stale-base rejection, the external-change
  merge banner, and the serialized edit FIFO.
- **They sync by two well-defined bridges, and only these two:**
  1. **Tree → session (a committed edit):** a completed tree transform computes
     the **minimal `SourceEdit`** between `serialized()` before and after (a
     bounded diff — a transform touches ≤2 blocks, so the diff is a single
     contiguous splice), and applies it through the *existing*
     `DocumentSession.applyEdit(base:…)`. Undo, coalescing, stale-base, the FIFO,
     and autosave all keep working **unchanged**, because they operate on the
     byte string the tree stays in sync with. The byte edit is an *output format
     for persistence*, not the editing model — the computation that produced it
     was fully structural.
  2. **Session → tree (a republish):** whenever `DocumentSession` publishes a new
     document — **undo, redo, or an adopted external change** — the controller
     **rebuilds the tree** with `EditableDocument.build(parsing: newSource)` and
     restores the caret structurally by mapping the session's caret byte to an
     `EditPosition` through the fresh tree. This is the inbound path v1 omitted
     entirely.

This is what makes v2 *tree-as-truth for interaction* while *re-homing zero
correctness machinery* — undo/IME-timing/external-change/stale-base are not
re-implemented, they are kept and bridged. It is strictly more than v1's
"surgical" idea (the tree drives the whole live view + caret + all edits, not
just Return/Backspace) and strictly less risky than re-implementing the undo
stack.

### Why not a tree-owned undo stack?
Re-implementing undo as a tree-transform inverse stack means re-deriving
coalescing ("undo a word, not a keystroke"), the Edit-menu enable/title wiring,
and grouping — all of which `DocumentSession` already does correctly. The
minimal-diff bridge reuses them for free. A tree-snapshot undo stack is the
fallback only if the minimal-diff proves too coarse; it is not the default.

## Rendering: document-wide reference resolution (fixes the CRITICAL)

v1's per-block isolated `parse(block.text).blocks.first` is wrong: reference-style
links/images/footnotes resolve against a document-wide reference map whose
definitions are *trivia*, and `.blocks.first` truncates multi-block text. v2:

- **Rendering reads from `DocumentSession`'s authoritative whole-document parse**
  (`QuoinDocument`), which resolves references correctly and computes footnote
  ordinals — exactly as the app renders today. Each recycler read row renders
  its `QuoinDocument` block. Because the tree and the session are kept in
  lock-step by the two bridges, the session's `QuoinDocument` is always the parse
  of the tree's current `serialized()` — so "render from the session document"
  and "render the tree" are the same content, and reference resolution is correct
  for free.
- **The tree drives EDITING; the session's document drives RENDERING; the bridges
  keep them identical.** Kind is therefore always correct (the whole-doc parse
  re-kinds; the Phase-1 heading-split-tail watch-item resolves for free — the
  tail parses as a paragraph in whole-doc context).
- **One-top-level-block invariant on `block.text`:** a transform never leaves a
  multi-block string in one block. A newline entering `block.text` by any path
  other than `splitBlock` (soft break `⌥Return`, paste, dictation "new line")
  must be normalized to a real split, so `.blocks.first`-style truncation cannot
  occur. Enforced where text enters the tree (the sync point below).
- **Live kind reclassification is intentional and specified:** typing `> ` at a
  paragraph's start reclassifies it to a quote on the next whole-doc parse (the
  session republishes, the tree rebuilds). This is the desired WYSIWYG-markdown
  behavior; it is now explicit, not an implicit side effect.

## IME / marked text: the composition gate (fixes the CRITICAL)

The controller tracks composition from the active text view's marked-text state
and enforces:

- **While `hasMarkedText()` is true: NO structural transform (`splitBlock`/
  `joinWithPrevious`), NO tree sync, NO row re-vend, NO tree→session bridge.**
  Return/Backspace fall through to the native text view (the IME owns them).
- **The commit point is composition-end** (marked text becomes committed text):
  only then does `block.text = textView.string` sync run and the tree→session
  bridge fire. This re-homes `IslandController`'s `blockedIME` guard as an
  explicit controller state, and it is what makes the "row re-vend" safe (see
  below) — a re-vend can never land mid-composition.

## Caret ↔ text view: whole-block sync (fixes the incoherence)

Committed to **whole-block sync**: the active block's `BlockEditorCell` owns its
`NSTextView` string; on `textDidChange` (and not during marked text), the
controller does `block.text = textView.string` and recomputes the structural
caret from the selection. The tree's `insertText`/`deleteRange` are used for
*programmatic* edits and for computing the minimal diff, not to intercept native
typing. Autocorrect/smart-quotes/dictation are safe because `BlockEditorCell`
already disables the four substitutions (dependency stated explicitly); dictation
"new line" is caught by the one-top-level-block normalization above.

## Activation: the rendered→source caret map (fixes the re-introduced coordinate bug)

The tree removes *document*-byte desync, not *within-block* rendered↔source
desync: a click on the rendered H1 glyph run must map to a `block.text` (source)
offset. v2 **re-homes the existing render→source hit-mapping** (the logic the
old island swap uses) into the activation path of the tree controller: on
render→edit promotion, map the click point through the block's
rendered-fragment↔source correspondence to the source offset, then set the
`EditPosition`. This is the one place v1 inherited no solution and where the
original field bug would otherwise return.

## Recycler coupling: the honest scope (fixes the understatement)

`BlockRecyclerView` (1,747 lines) is welded to the concrete `IslandController` at
~10 sites and is byte-range-driven throughout; a synchronous "re-vend the editing
row" destroys the live `NSTextView` — structural ops MOVE the cell (`promoteRow`),
never re-vend it. v2 accepts this reality:

- **Introduce a row-source + editing-controller PROTOCOL seam** in
  `BlockRecyclerView` so it can be driven by either `IslandController` (old path)
  or the new `TreeEditorController` (tree path), selected by the
  `QuoinEditorRecycler` flag. This is a real refactor of the recycler's row model
  (`numberOfRows`/`viewFor`/`rowHeight`/`blockAndPoint`) and its
  preserve/park/reanchor core — NOT a wiring change. It is the largest single
  piece of Phase 2 and gets its own sub-phase.
- **Structural ops keep the editing cell by MOVING it** (the `promoteRow` /
  `reconcileRowCountKeepingEditing` mechanism), never by re-vending it. The tree
  controller drives split/join through that same synchronous-commit path, with
  the IME gate in front. "Row-local refresh" from v1 is replaced by "move the
  editing cell, re-vend only the *non-editing* rows that changed."
- `BlockRowMetrics.rowHeight` depends on the *next* block's kind; the tree
  row-source must supply neighbor context. Named, not hand-waved.

## Multi-block selection / cut / paste: explicit scope boundary

The recycler has no cross-block selection primitive today (one `NSTextView` per
row). v2 scope: **single-block selection only; multi-block selection, cut, and
paste-spanning-blocks are a named non-goal for Phase 2**, deferred to a later
phase with its own cross-block transform. Paste of multi-line markdown into one
block is handled by the one-top-level-block normalization (it splits into real
blocks), not by a multi-block selection model.

## Revised sub-phase outline (each re-reviewed before planning)

1. **Recycler protocol seam** — refactor `BlockRecyclerView` so its row-source and
   editing-controller are protocol-typed; the old `IslandController` path adopts
   the protocol with zero behavior change (proven by the existing island tests
   staying green). No tree yet. This de-risks the coupling first.
2. **`TreeEditorController` read path** — drive read rows from the tree, rendering
   via the session's whole-doc `QuoinDocument`. Flag-on renders identically to the
   old path, including a reference-link + footnote fixture.
3. **The tree↔session bridges** — tree edit → minimal `SourceEdit` →
   `DocumentSession.applyEdit`; session republish → `build(parsing:)` + structural
   caret restore. Test: undo/redo/external-change round-trip through the tree path.
4. **Activation + whole-block-sync typing** — render→source hit map; `textDidChange`
   → `block.text` sync → bridge; IME gate. Test: typing, autocorrect-off, CJK
   composition does not corrupt.
5. **Return = splitBlock / Backspace = joinWithPrevious** — through the
   move-the-cell promotion path, IME-gated. Test: the field-bug scenarios (heading
   survives; one-Enter-one-Backspace) through the real keystroke path.
6. **Viewport invariant + full regression suite** through the GUI path.
7. **Cutover prep** (flag still off) — the interim guard removal is Phase 3.

## Re-review verdict (2026-08-19) — v2 is NOT plannable; the byte-native substrate is the flaw

Two adversarial reviews (sync-bridge crux; recycler seam + integration), each
grounded in the real code, both reject v2. They converge on one root cause:
**v2 keeps the tree's benefits only until the first bridge crossing, because the
substrate beneath it (the byte-native recycler + DocumentSession's char-level
undo) is still string-as-truth.** Every seam re-imports the bytes the tree exists
to delete.

**Sync-bridge review — the two bridges are non-inverse:**
- **Undo coalescing FAILS.** `recordUndo` (DocumentSession.swift:556-608) only
  coalesces *single-character* edits (`replacement.count == 1`, whitespace breaks
  the run). A debounce-batch bridge emits multi-char SourceEdits that bypass the
  coalescer entirely → undo granularity regresses to a whole batch, whitespace-
  break dead. A per-keystroke bridge feeds it count==1 edits but reintroduces a
  whole-doc `parseAfterEdit` on *every keystroke* — the exact cost the tree meant
  to delete. No middle setting gets both. "Coalescing for free" is false.
- **Rebuild-on-republish shreds identity.** `build(parsing:)` mints all-new
  NodeIDs unconditionally (EditableDocument.swift:60 `.fresh()`), so every
  `EditPosition` and the focused-cell key dangle on undo/redo/external. The
  specified restore input doesn't exist — `undo()`/`redo()` return only a
  `QuoinDocument`, no caret byte (DocumentSession.swift:774-806; consumer restores
  with `atUTF8Offset: nil`, ReaderModel.swift:1580). And placing the caret after a
  rebuild *is* byte→structure mapping on the hot inbound path — the very thing the
  tree was supposed to make impossible. A ⌘Z while a cell is focused has no cell to
  "move."
- **Self-republish loop, unnamed.** The outbound `applyEdit` publishes through the
  same `publish()` path as undo/external; a naive "rebuild on republish" rebuilds
  the tree — fresh NodeIDs — on its *own* keystroke, destroying the caret every
  character. Needs a sourceHash self-echo discriminator v2 never states.

**Recycler-seam review — three of four resolutions lean on absent/wrong-shaped machinery:**
- **The render→source activation hit-map is VAPORWARE.** The island path has NO
  render→source mapping: on click it forwards the raw `NSEvent` and places the
  caret in *raw-source* space (IslandController.swift:459; IslandClickSeamTests
  bless exactly that), so the heading-coordinate field bug is latent and untested
  there. The real `EditMapping.sourceOffset` lives only in the monolith being
  deleted and is built for the single-textview reveal model (1:1 hidden
  delimiters), not the recycler's two-layout (read cell hides `#`, island shows
  it). It must be built FROM SCRATCH — v2 sells a from-scratch build as a re-home.
- **The protocol seam re-exposes bytes.** The recycler's row model *is*
  byte-range end to end (`record(at:)`, `byteRange.lowerBound == islandStartByte`).
  Any seam must answer block-id + start-byte + is-apply-in-flight +
  revalidate-against-document — every one a byte concept. Sub-phase 1 (extract the
  seam green) freezes the coupling in IslandController's *async-park* shape, which
  is wrong for a *synchronous* tree driver → likely thrown-away rework.
- **"Structural ops MOVE the cell" inverts the concurrency model.** Today a split
  comes back FROM the session async (`reconcileRowCountKeepingEditing` after
  republish); the park/replay guards exist *because* of that ordering. A
  tree-driven synchronous split is a new entry point that inverts it — buildable,
  but not "reuse."
- IME gate mostly holds, but composition-end is reconstructed from the
  `wasComposing` edge (not an AppKit event), and the *inbound* reseed path must
  ALSO gate on `hasMarkedText()` — v2 gated only outbound, and whole-tree rebuild
  makes this MORE exposed than today.

**The convergent conclusion:** the friction is not a set of fixable oversights —
it is the *reuse-the-byte-native-substrate* decision itself. The sync-bridge
reviewer's own recommendation ("own a tree-snapshot undo stack — likely the real
answer, not the fallback") and the seam reviewer's ("design for the tree's
synchronous needs, not IslandController's async byte-anchor") both point to the
same place: **let the tree own its undo and its view layer** — which is what the
master spec's original Phase 2 ("NSTextContentManager over the tree") always said,
before v1/v2 pivoted to reusing the recycler. That is the Option-B fork now under
decision. v2 is retained only as the record of why re-homing onto the byte-native
substrate does not work.

## Open questions for re-review (the crux points to attack again)

- Is "tree drives interaction, session stays persistence/undo via minimal diffs"
  genuinely sound, or does the diff-and-reparse round-trip per commit reintroduce
  the whole-doc-reparse cost the tree meant to delete? (Bounded: one splice per
  committed transform, not per keystroke — typing syncs block.text locally and
  bridges on a debounce/commit, not every character. Confirm this holds.)
- Does rendering-from-the-session-document while editing-from-the-tree create a
  window where the two disagree (mid-commit)? Define the commit ordering so the
  view never renders a tree state the session hasn't adopted.
- Is the recycler protocol seam (sub-phase 1) actually extractable without
  touching the island path's behavior, or is the byte-range row model too load-
  bearing to abstract cleanly?
