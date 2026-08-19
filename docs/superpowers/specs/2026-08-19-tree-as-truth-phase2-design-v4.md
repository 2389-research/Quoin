---
title: Tree-as-truth Phase 2 — the live editor (Design v4, Option B + stock-storage structural projection)
status: DESIGN v4 (candidate to plan against; sub-phase 1 is a spike gate)
created: 2026-08-19
supersedes: 2026-08-19-tree-as-truth-phase2-design-v3.md (v3, sound but storage approach unpicked + 3 bridge gaps)
parent: 2026-08-19-tree-as-truth-editing-design.md (master spec — this is its Phase 2)
builds on: Phase 1 (Sources/QuoinCore/EditableDocument/, delivered)
decisions:
  - Option B (Clint, 2026-08-19): tree owns editing + undo + its view layer.
  - Storage approach (ruling, 2026-08-19): keep the stock NSTextContentStorage; the tree
    drives it by STRICTLY-STRUCTURAL projection (not byte-diff reconcile). Grounded in two v3 reviews.
grounded-by: two code surveys + two adversarial reviews (2026-08-19); every load-bearing
  claim carries file:line evidence.
---

# Phase 2 v4 — the live editor

## The lineage, in one paragraph

v1 assumed away undo/IME/external-change. v2 tried to keep the tree's benefits over the
**byte-native substrate** (island recycler + `DocumentSession`'s char-level undo) and was
rejected: the benefits died at every bridge crossing. v3 (Option B) put editing, undo, and
the view under the tree and was found **architecturally sound**, but left two things
unresolved that this doc fixes: it never chose *how* the tree backs the text view, and it
under-specified the persistence bridge's dirty/echo/cost semantics. v4 makes both concrete.

## The two rulings v4 locks

### Ruling 1 — Option B (Clint): the tree owns editing, undo, and its view layer.
`DocumentSession` narrows to persistence. No document byte offset and no byte-`SourceEdit`
reconcile ever appears on the interaction path — that is the bug class's grave.

### Ruling 2 — the storage approach: keep stock `NSTextContentStorage`; drive it by structural projection.
The v3 reviews surfaced a choice v3 dodged — two ways the tree could back the one text view:
- **The custom-backend approach** (a from-scratch `NSTextContentManager`/
  `NSTextElementProvider`): `textView.textContentStorage` becomes **nil**, so every guard
  that reads `textContentStorage?.textStorage` silently no-ops — decoration discovery
  (`QuoinTextView.swift:575`), the incremental `noteStorageEdit` (`:518`), the caret-line
  settle/anchor (`:434,:461-462,:486-488`), and the dirty/conflict path all go dark. It also
  stakes the whole approach on the unproven "does a zero-length `NSTextElement` lay out as a
  caret line" gamble.
- **The stock-storage approach** keeps the stock `NSTextContentStorage` and its real backing
  `NSTextStorage`, so **all of that machinery survives**, and an empty block is just an empty
  line in a flat storage — which the monolith lays out today. Its only new obligation is a
  tree→storage sync layer. **v4 takes this one.**

The reviews warned the stock-storage approach "reintroduces the reconcile problem v2 died
on." **It does not, and the distinction is the core of v4:**

> v2/monolith reconcile = mutate storage → **diff** back to the markdown string → splice at
> **document byte offsets** → reparse. That is where carets strand and merges corrupt.
>
> v4 structural projection = the tree is truth; after a tree transform the controller knows
> **exactly which block(s) changed and their exact storage character range**, and re-projects
> **only that range** into the storage. The caret is the structural `EditPosition(NodeID,
> offsetUTF16-in-block.text)`, mapped to a storage offset by the tree's own length
> bookkeeping: `storageOffset = (Σ projected UTF-16 length of preceding elements) +
> offsetUTF16`. **No diff. No document byte offset. No markdown-string round-trip.** The
> markdown string is produced only by `serialized()` on save.

So the storage is a **write-only downstream cache** the tree patches precisely — the same
role the `AttributedRenderer` output already plays, except edits patch it structurally
instead of a byte-reconcile patching it. This keeps the entire working view shell
(decorations, reveal styling, settle/anchor, AX) and dissolves the empty-element gamble.

## What v4 keeps unchanged from v3 (upheld by review)

- **Activation hit-map via `EditMapping.sourceOffset` — plannable now, on proven code.**
  Per-block use is already the production pattern (`ReaderCoordinator.swift:833-836,
  :1729-1732`); the function takes only `renderedText`/`sourceText`, no document context
  (`SourceEdit.swift:121-125`); and per-block correctness is already regression-tested
  (`CaretMappingTests`: `testHeadingPrefixIsSkipped`, `testBulletedAnchorListClickLandsInThe
  ClickedItem`). Click a rendered block → map click → flip that block to source → place the
  structural caret. **Invariant to enforce (two-recognizer trap, CLAUDE.md): the storage
  substring displayed for a block MUST be byte-identical to the `renderedText` passed to
  `EditMapping`** — both come from the one whole-document projection, never a second parse.
- **Tree-owned undo fixes v2's NodeID churn** — snapshots capture the *original* NodeIDs
  (`NodeID.fresh()` is a monotonic process-global counter, `NodeID.swift:15-21`), so undo
  restores original identities. Conceded sound by review.
- The active-block-source + inactive-block-rendered mix **in one storage is not new** — the
  monolith already reveals the active block as source in the same storage
  (`ReaderCoordinator.restyleActiveBlock`, `:858-885`), and the settle machinery keyed on
  `selectedRange().location` (`QuoinTextView.swift:486`) already absorbs that reflow.

## The architecture

### Storage model — one `NSTextView`, stock `NSTextContentStorage`, tree-projected content

- The controller owns the `EditableDocument` tree (the truth) and a single `NSTextView`
  with the **stock** `NSTextContentStorage`. On load and on every transform it maintains a
  **projection**: the storage's attributed string is the concatenation, in tree order, of
  each segment's projected attributed run.
- **Per-element length bookkeeping.** The controller keeps, per block segment, the UTF-16
  length of its projected run in the storage. This is the map between structural positions
  and storage offsets — deterministic, no alignment heuristic.
- **Inactive block → rendered projection** (from the whole-document parse, so reference-
  style links/footnotes resolve — see Rendering). **Active block → literal source** styled
  by `MarkdownSourceStyler`, 1:1 with `block.text`, so the caret offset in the storage minus
  the block's start offset *is* `EditPosition.offsetUTF16`.

### Editing — tree transforms, then a precise storage patch

- Typing/delete in the active block: `insertText`/`deleteRange` on `block.text` (Phase 1),
  then re-project **only the active block's storage range** (`storage.replaceCharacters(in:
  activeRange, with: restyledSource)`) and update its length bookkeeping. No other element
  moves in the model; the storage shift is exactly the delta.
- **Return = `splitBlock(at:)`**: the active block becomes two block segments (+ the trivia
  the transform already emits, `EditTransforms.swift:41-60`); the storage patch replaces the
  old block's range with the two projected runs; the caret goes to the new block at offset
  0. An end-of-block split yields a **real empty block** → an empty line in the storage → a
  normal caret line (no virtual line, no custom empty element).
- **Backspace-at-0 = `joinWithPrevious`**: the inverse patch; caret at the join. Split/join
  are inverses (Phase 1 proof).
- **List/quote continuation** on Return reuses `ListContinuation` (ported from
  QuoinEditorKit — pure logic, no view coupling).

### Caret — structural, mapped to storage by length bookkeeping

`EditPosition(NodeID, offsetUTF16)` ⇄ storage offset via the per-element lengths. The
`NSTextView` selection is set from that; a click/selection read maps back the same way
(within the active source block it is a straight subtraction; a click on an *inactive*
block goes through the activation hit-map first). No document byte offset exists on this
path.

### Undo — tree snapshot stack, coalescing rules ported (not code)

- A bounded stack of `EditableDocument` snapshots, each carrying its `EditPosition` caret.
  Value structs share String buffers (COW); **cost caveat (R-cost):** each transform's
  `withBlock` reassigns `segments[i]`, copying the array *spine* on divergence — O(N
  segments) per retained snapshot. Bound the depth (e.g. 200 units) and, if a large-doc
  budget is exceeded, switch retained entries to inverse-transform deltas. Measured in
  sub-phase 4, not assumed.
- **Coalescing is re-expressed, not ported verbatim.** The *rules* from
  `DocumentSession.TypingRun` port (a contiguous run of non-whitespace single-char inserts
  is one unit; whitespace, a caret jump, or a structural op breaks it,
  `DocumentSession.swift:556-608`), but the *mechanism* changes: the byte-offset contiguity
  test (`edit.range.offset == run.nextOffset`, `:577`) becomes `EditPosition` adjacency, and
  "extend the top inverse edit in place" becomes **replace-top-snapshot vs. push-new**. New
  logic, proven by tests, guided by the old rules.
- **Edit-menu wiring is native**: register each unit with the window's `NSUndoManager`
  (`registerUndo` + `setActionName`); `allowsUndo` is already `false`
  (`MarkdownReaderView.swift:359`), so there is no collision with NSTextView's own undo.

### The persistence bridge — narrow, and the three gaps closed

`DocumentSession` stays the on-disk authority. Bridge crossed on **edit-commit
(dirty/autosave), save, and external change** — never per keystroke's storage patch.

- **Load**: `EditableDocument.build(parsing: session.document.source)`.
- **GAP 1 fixed — keep the session dirty.** `isDirty` is today set only inside
  `scheduleAutosave()`, reachable only from `applyEdit`/`undo`/`redo`
  (`DocumentSession.swift:812,547,791,804`) — all bypassed by the tree path, which would
  leave `isDirty == false` and let an external change silently discard unsaved edits via the
  clean branch of `reloadFromDisk` (`:392,:404-405`). **Add a session API
  `noteInMemoryEdit()`** that sets `isDirty` and schedules autosave **without** touching the
  undo stack or revision — the tree controller calls it on every committed transform. Now
  the conflict/merge-banner path (`:388-403`) sees the document as dirty and behaves
  correctly.
- **Save / autosave**: the tree serializes (`serialized()`, Phase-1 byte-lossless); the
  controller writes via a save that **stamps `selfWriteHash`** (see GAP 2). `apply(source:)`
  alone is wrong for our own save because it publishes an adopt without the self-write stamp
  (`:470-473,:341-347`) — so the save path is `writeToDisk`-shaped (which does stamp
  `selfWriteHash`, `:936-937`), not a bare `apply(source:)`.
- **GAP 2 fixed — distinguish our own save's publish from a real external change.** The tree
  controller subscribes to session publishes to learn of external changes; but
  `adoptExternal` publishes without setting `selfWriteHash`, so an own-save publish is
  indistinguishable from a genuine adopt and would trigger a needless rebuild → lost caret
  (`:341-347` vs `:936-937`). **The tree path treats a publish whose source hash equals the
  hash it just serialized-and-saved as a self-echo and ignores it** (mirror the existing
  `selfWriteHash` discipline). Only a publish with a *different* hash is a real external
  change.
- **External change → rebuild**: on a genuine external publish, `build(parsing: newSource)`
  and restore the caret. **GAP 3 (R5) — the focused-block edge:** content-hash correlation
  of surviving blocks re-places the caret for untouched blocks, but if the external change
  edited the *focused* block, that block has no content match by construction. **Fallback:
  restore by structural position** — same block index if the count is stable, else nearest
  surviving anchor, clamped offset — and surface the merge banner rather than silently
  moving the caret. Composition-gated (below). Rare path (external edit to the exact block
  being typed in); best-effort restore + visible banner is the contract.

### Rendering — whole-document parse, but off the keystroke path (GAP 4 / cost)

- Inactive blocks render from a **whole-document parse** so cross-block references resolve
  (the v1 CRITICAL). But `build(parsing:)`/`MarkdownConverter.parse` is whole-document and
  measured at ~1.9 s local / 3.2–3.6 s CI for 1 MB against a 3 s budget
  (`PerformanceTests.swift:42-59`), and the tree path **cannot** reuse the incremental
  `parseAfterEdit` fast path (it needs a `SourceEdit`, `DocumentSession.swift:540`). So v4
  does **not** whole-doc-reparse on every deactivation:
  - **Default deactivation** (prose edit within a paragraph): re-project just the
    deactivated block and **re-kind it by a single-block parse** of its own text — cheap,
    O(block). Other blocks are unaffected because a prose edit cannot change their rendering.
  - **Whole-document reproject** happens **only when an edit could affect other blocks'
    rendering** — i.e. it touched a reference/link/footnote **definition** (trivia) or
    changed footnote ordinals. This is detectable from the transform (did a definition
    segment change?); it is rare. The controller maintains a document-level reference map and
    reparses whole-doc only on that trigger, with the measured budget as the gate.
  - This keeps typing and block-to-block navigation off the whole-doc parse; only definition
    edits pay for it. Sub-phase 7 measures and enforces the budget.
- **Live kind reclassification** (typing `> ` → quote) resolves via the deactivated block's
  single-block re-kind — explicit.

### IME — native, bidirectional gate

One `NSTextView` ⇒ native composition. Rule: while `hasMarkedText()` is true, **no
structural transform and no external-adopt rebuild** (the inbound gate the review demanded);
Return/Backspace fall through to the IME; a genuine external publish that arrives
mid-composition defers until the `hasMarkedText()`-false edge on `textDidChange`, at which
point the active source block syncs to the committed text.

### Selection — cross-block is now native

One `NSTextView` gives native cross-block selection + copy (v2's non-goal lifted). A
multi-block *edit* (delete/paste spanning boundaries) is a tree transform composing
`splitBlock`/`joinWithPrevious` across the selection — an explicit Phase-2 task (Open
Question), not assumed free.

### Decorations — survive, because the storage survives

Because the stock-storage approach keeps `textContentStorage.textStorage`, decoration run discovery
(`enumerateAttribute(QuoinAttribute.blockDecoration…)`, `QuoinTextView.swift:575`),
`noteStorageEdit` (`:518`), the settle/anchor loop (`:381-398,:434,:486`), and
`measureVisibleRuns` (which already goes through the abstract `contentManager`, `:623-698`)
all continue to work. The block ranges they need come from the controller's per-element
length bookkeeping. This is a **re-source of the range provider**, not a rewrite of the
decoration pipeline — the pipeline's storage substrate is intact.

## Sub-phase outline (each adversarially re-reviewed before planning)

1. **SPIKE + gate — tree-projected stock storage.** Build the controller that owns a tree,
   projects it into one `NSTextView`'s stock `NSTextContentStorage`, and maintains
   per-element length bookkeeping; render a document **identically to the monolith** (same
   pixels; reference-link + footnote fixture). Prove: an empty block projects to a caret
   line; a single-block re-projection patch preserves the settle/decoration invariants.
   **Go/no-go**: if the settle/anchor/decoration invariants cannot hold under structural
   patches, revisit before committing later sub-phases.
2. **Activation + source reveal** — the proven `EditMapping` path; enforce the
   displayed==renderedText invariant. Test: heading-click coordinate fixture lands correctly.
3. **Typing into the active source block** — Phase-1 `insertText`/`deleteRange` → precise
   patch. Test: byte-correct serialization; other elements untouched; autocorrect off; CJK.
4. **Tree-owned undo** — snapshot stack, re-expressed coalescing, `NSUndoManager`. Test:
   word-granularity; caret restored structurally; redo; Edit-menu titles; snapshot cost
   within budget.
5. **Return = split / Backspace = join**, list/quote continuation, IME-gated. Test: the
   field-bug scenarios through the real keystroke path; empty-block row.
6. **Persistence bridge** — `noteInMemoryEdit()` dirty hook (GAP 1); self-echo hash
   discriminator (GAP 2); external-change rebuild with structural-fallback caret (GAP 3),
   composition-gated. Test: round-trip byte-lossless; unsaved edits survive an external
   change (dirty→merge banner, no silent loss); own-save does not trigger a rebuild.
7. **Whole-doc projection cadence** — default single-block re-kind; whole-doc reproject only
   on definition-affecting edits; reference/footnote fixture; **measure against the parse
   budget**. Test: block-to-block navigation does not whole-doc-reparse.
8. **Viewport invariant + full regression suite** through the GUI path.
9. **Cutover prep** (flag off; interim-guard removal is Phase 3).

## Open questions for a light final review (the deltas from v3)

1. **Structural-patch invariants under the settle loop.** Does re-projecting only the active
   block's storage range (mid-document `replaceCharacters`) keep `viewWillDraw`'s settle
   (`QuoinTextView.swift:381-398`) and `noteStorageEdit`'s incremental run-list correct, or
   is there a re-entrancy/ordering hazard? (Sub-phase 1 is the gate.)
2. **`noteInMemoryEdit()` and revision semantics.** Setting `isDirty` without bumping
   `contentRevision` — does anything else in the session assume dirty ⇒ a revision change?
   (Confirm `contentRevision` is only consumed by `staleEditBase`, which the tree path never
   invokes.)
3. **Definition-edit detection.** Is "did this transform touch a reference/footnote
   definition segment" cleanly detectable in the tree (definitions are `.trivia`), so the
   whole-doc reproject trigger is precise and not conservative-always?
4. **Multi-block edit transform** — split/join composition vs. a new primitive; Phase-2 or
   deferred?
5. **Snapshot vs. inverse-delta undo** — is the O(N-segment) spine copy per snapshot within
   budget for realistic notes, or is the inverse-delta variant needed from the start?
