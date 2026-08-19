---
title: Tree-as-truth editing — a first-principles re-architecture
status: DESIGN (Phase 0 validated; for review)
created: 2026-08-19
supersedes: the markdown-string-as-live-editing-truth model (kept for save/load)
related:
  - docs/design/wysiwyg-architecture-comparison.md   (the decision + two-model debate)
  - docs/design/single-file-first.md                 (the earlier framing of the crux)
  - docs/design/editable-islands-design.md           (Phase 3 islands — a partial step)
  - Tests/QuoinCoreTests/Phase0ByteLosslessTests.swift (the Phase 0 proof)
---

# Tree-as-truth editing — a first-principles re-architecture

## Why

Quoin's editing bugs are not independent defects; they are one category of bug
that the architecture *manufactures*. The markdown **string** is the live
editing truth, and markdown cannot represent the states an editor needs
mid-edit: an empty paragraph, a caret between blocks, a half-formed block. So
the code invents surrogates — a "virtual line," an extended editable slice,
byte-range reconciliation across every block boundary — and each surrogate is a
seam where the caret and the bytes disagree.

The field bugs are all this one root:

- **Return does nothing** — a lone `\n` is a soft break; the projection is
  byte-identical, the caret cannot advance.
- **Backspace eats a heading character** — a render→reveal coordinate shift
  strands the caret inside content while a blank line hangs below; a native
  delete removes real content (`things` → `thins`).
- **One Enter needs two Backspaces** — Return inserts `\n\n` for the first
  blank line, Backspace removes one at a time.
- **The virtual line renders 2× too low; caret is a tiny dot** — the block is
  drawn at a clamped height because markdown has no empty-paragraph node.

Each has been patched individually (the interim guard took three iterations —
snap → redirect → symmetry — each fixing one facet and exposing the next). That
is the "indefinite tail of boundary bugs" a two-model debate
(`wysiwyg-architecture-comparison.md`) predicted for a string-as-truth block
editor. No shipping open-source WYSIWYG-markdown editor makes the string the
live truth *and* does block-level rendered editing; they all use a structured
tree (ProseMirror, Lexical, Slate, and MarkText's Muya — the closest peer).

## The decision

**A structured block/inline node tree becomes the live editing truth. Markdown
becomes serialization — parsed on load, emitted on save.**

In this model the entire bug class disappears *by construction*:

- An **empty paragraph is a real node**. The caret lives in it natively. No
  virtual line, no clamped height, no tiny-dot caret.
- **Return = split** the current node at the caret. **Backspace-at-start =
  join** with the previous node. Exact structural operations on addressable
  positions — they *cannot* strand a caret or delete across a boundary, because
  there are no byte offsets to miscompute and no render-vs-reveal coordinate
  spaces.
- Return and Backspace are **symmetric by construction** — split and join are
  inverses.

This is not a detour from the Phase 3 editable-islands work: an island *is*
already a local editable model over one block. It has been missing a real
document model underneath. This gives it one.

## What Phase 0 proved (already done, GREEN)

The one legitimate risk — could a tree → markdown serializer reproduce a file
*byte-for-byte* — was answered before committing, per the debate's
recommendation. `Phase0ByteLosslessTests` decomposes 33 documents (10 rich
fixtures + 22 pathological edge cases: CRLF, mixed endings, front matter,
nested/loose lists, tables, fenced/indented code, blockquotes, HTML blocks,
unicode, setext, tabs, thematic breaks) into an ordered span tree and re-emits
it. Result:

- **`parse → decompose → serialize` is byte-identical for all 33.** Block
  ranges are a clean, ordered, non-overlapping, in-bounds tiling basis.
- The **only** non-whitespace content outside the block tree is **footnote
  definitions** (gathered into `document.footnotes`). A bounded, known set the
  node tree must own.

So byte-losslessness for untouched regions holds by construction (retained
spans re-emit verbatim); the migration is de-risked.

## Architecture

### The model — `EditableDocument` (a mutable CST)

A tree of nodes, each retaining the exact source bytes it was parsed from, so an
untouched node re-emits verbatim and only edited subtrees re-serialize.

```
Node
  id: NodeID                    // stable across edits (not content-hashed)
  kind: BlockKind | InlineKind
  children: [Node]
  sourceSpan: Range<Int>?       // the file bytes this node was parsed from; nil for a node born in-editor
  pristine: Bool                // false once this node (or a descendant) is edited
  // leaf text nodes additionally carry their live string content
```

Invariants:

- The tree's in-order leaf spans **tile** the source with no gaps or overlaps
  (Phase 0 property, now enforced on every parse).
- **Footnote definitions are first-class block nodes** (closing the Phase 0
  gap), not a side table.
- A node with `pristine == true` and all descendants pristine serializes to
  `source[sourceSpan]` verbatim.

### Serialization — span-retaining

```
emit(node):
  if node.pristine && allDescendantsPristine(node):
      append source[node.sourceSpan!]                 // verbatim — byte-lossless
  else:
      for child in node.children: emit(child)         // recurse; only dirty subtrees regenerate
      // a dirty leaf prints its live content in the block's own marker style,
      // reusing pristine delimiter spans where they survive
```

Property (fuzzed): for any sequence of edits, every byte OUTSIDE the edited
nodes' spans is byte-identical to the original. Edited nodes emit canonical
markdown in the style inherited from their surviving delimiter spans.

### Editing operations — pure tree transforms

`insertText`, `deleteRange`, `splitNode(at:)` (Return), `joinWithPrevious`
(Backspace-at-start), `wrap`/`unwrap` (list/quote). Each:

- mutates the tree, marking touched nodes dirty,
- returns the new caret as `(NodeID, offsetInNode)` — a **structural** position
  that cannot desync from bytes,
- is a single undo unit.

Empty paragraph = a paragraph node with an empty text leaf. Return at a block
end inserts an empty paragraph node after it and puts the caret in it — nothing
is written to bytes until content arrives *only because serialization skips an
empty paragraph*, but the caret has a real node the whole time. No virtual line.

### The view bridge — TextKit 2 over the tree

`NSTextContentManager` backed by the node tree; one `NSTextElement` per block
node; inline nodes become attributed runs. An empty paragraph node is a
zero-length element that still lays out as a line — the caret sits there with
no clamp. Return/Backspace call the tree transforms synchronously, then
invalidate the affected elements. **No async echo, no reconcile debounce, no
byte-range splice.** This also closes `single-file-first.md`'s open question
("how much projection stays on the common typing path"): none — the tree is the
truth and edits are synchronous.

Reuses the Phase 3 recycler (`BlockRecyclerReaderView`) as the per-block view
layer; the tree becomes its model.

## Phases

**Phase 0 — foundation (DONE, GREEN).** Span tree + byte-lossless round-trip
fuzz. Committed.

**Phase 1 — the model + editing core (platform-free, Linux-testable). DELIVERED
2026-08-19** (plan `docs/superpowers/plans/2026-08-19-tree-as-truth-phase1.md`,
7 tasks, final whole-branch review clean). `EditableDocument` (segment model:
trivia + blocks with source spans + pristine); the span-retaining serializer
(byte-lossless over a 24-doc corpus fuzz); the pure edit transforms
(insert/delete/splitBlock=Return/joinWithPrevious=Backspace); structural caret
`EditPosition`. Fuzz proves: parse→serialize byte-identical; edit→untouched
regions byte-identical; split∘join = identity; the exact heading-corruption
scenario byte-preserved. Entirely testable without a UI; full suite green.

Deferred into later phases (from the Phase 1 final review):
- **Footnote AND link-reference definitions become inert `.trivia`** — the
  parser drops them from `doc.blocks`, so Phase 1 keeps them byte-lossless but
  not editable-as-nodes. Promoting them to first-class block nodes is the
  spec's "close the Phase 0 gap"; it is the most likely place **Phase 2** gets
  surprised (split/join/caret can't target trivia). Address in the Phase 2 plan.
- **`deleteRange` and the `build` slice have no defensive bounds guard** — latent
  (cmark yields well-formed distinct-offset ranges). Add a `guard isValid`
  mirror on `deleteRange`, and a bounds assert in `build`'s `slice`, when Phase 2
  first drives them with UI-derived ranges.
- **A split tail inherits the original block's `kind`** (heading-split → a
  heading-kinded empty block). Zero serialization impact in Phase 1 (serialize
  reads only `text`); Phase 2's rendering must re-derive kind (an empty block
  after a heading should render as a paragraph).
- **List/quote marker continuation** (`wrap`/`unwrap`) and inline canonical
  serialization of edited runs remain later work; the `pristine` flag is the
  (currently decorative) hook for the latter.

**Phase 2 — the TextKit 2 bridge (macOS).** `NSTextContentManager` over the
tree, one element per block, empty node = real line; wire Return/Backspace/typing
to the Phase 1 transforms; caret mapping structural, not byte-offset. Behind the
existing `QuoinEditorRecycler` flag.

**Phase 3 — cutover.** Make the tree authoritative for a document window;
retire the string-reconciliation edit path, the virtual line, and the interim
guard; flip the flag on by default. Byte-lossless save via the span serializer.

## Non-goals

- The **on-disk format stays plain markdown**; the tree is in-memory only. Load
  parses to the tree; save serializes from it. Files are never migrated.
- **No new third-party dependency.** swift-markdown/cmark remains the parser;
  the tree and serializer are ours.
- Collaboration/CRDT is out of scope (the tree makes it *possible* later, not
  now).

## Testing strategy

- **Byte-lossless round-trip fuzz** (Phase 0, extended each phase): the corpus
  grows; `parse→serialize` stays byte-identical.
- **Edit-fidelity fuzz**: random edit sequences; assert untouched-region bytes
  are identical and Return/Backspace compose to identity.
- **Structural caret invariants**: a caret is always `(NodeID, offset)`; every
  transform returns a valid one; no byte-offset caret exists in the new path.
- **Viewport invariant** (Phase 2+): the existing `RevealFidelityTests` /
  `CaretLineAnchorTests` discipline applies to the tree-backed view.
- The old path's suites stay green until Phase 3 retires it.

## Risks and mitigations

- **Edited-node canonical serialization drift** (the residual byte-fidelity
  risk): mitigated by span-retention for delimiters + an edit-fidelity fuzz that
  fails on any untouched-region drift. The blast radius is one edited block.
- **TextKit 2 empty-element layout** quirks: prototype the empty-paragraph
  element early in Phase 2; fall back to a 1pt sentinel glyph only if AppKit
  collapses a truly empty element (measured, not assumed).
- **Scope**: phased behind a flag; the old path ships throughout; cutover is one
  reversible switch.
