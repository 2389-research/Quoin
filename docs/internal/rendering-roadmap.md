# Rendering & interaction roadmap

> **Status: COMPLETE (2026-07-14).** Every item on this roadmap has shipped —
> including the north-star incremental render (fragment cache + storage
> patches + splice, guarded by ProjectorEquivalenceTests) and all coverage
> items. Kept as a historical record; new rendering work is tracked in
> docs/design/ (editor-modes, suggestions).

Driven by dogfooding against the two stress fixtures in `~/Documents/ClintNotes`
(`markdown_renderer_stress_test.md`, `markdown_renderer_extreme_stress_test.md`)
and Clint's direct feedback. Ordered by "does the app feel broken" first, then
polish, then coverage. Each item lists the symptom, the suspected cause, the
approach, and rough size (S/M/L).

## North star: speed, and never surprising the reader

Every change below is measured against these, not just correctness:

- **Time to first text.** Opening a document shows text fast; layout is
  viewport-lazy (TextKit 2 already does this), so the only O(n) cost is building
  the attributed string — keep that cheap and, for very large docs, chunked.
- **Cheap reflows.** A keystroke re-projects and re-lays-out only the block(s)
  that changed, never the whole document. Target: keystroke→paint within one
  frame (~16 ms) for typical docs.
- **Minimal repaint.** Decoration redraws invalidate only the dirty rect, not the
  whole view.
- **No viewport jumps.** Unchanged content keeps its exact layout and scroll
  offset across edits and reveals; the caret stays where the user put it.
- **No confusion.** Rendered↔source transitions are local and predictable; a
  click never teleports the caret or reflows unrelated content.

### The one architectural change that unlocks all of them: incremental render

At the time of writing, `ReaderModel.rerender()` rebuilt the entire
`NSAttributedString` and `updateNSView` called `setAttributedString` — a full
re-layout on every keystroke. SINCE SHIPPED: per-block fragment cache,
bounded storage patches for keystrokes and flips (built in the renderer —
`activeBlockEditUpdate` / `activationFlipUpdate`), and splice application;
patch-vs-full equivalence is enforced in CI by ProjectorEquivalenceTests.

**Plan (foundational, do first):**
1. `AttributedRenderer` caches a per-block rendered fragment keyed by `BlockID`
   (+ a small key for separator context). `BlockID` is content-hash-stable, so an
   unchanged block reuses its fragment for free.
2. On a new snapshot, `BlockDiff.between(old,new)` (already exists) says which
   blocks are inserted/removed/unchanged. Rebuild only changed fragments.
3. Splice into the live `NSTextStorage` with `replaceCharacters(in:with:)` inside
   one `beginEditing/endEditing` transaction, covering only the changed character
   range. TextKit 2 re-lays-out just that region → unchanged fragments keep their
   layout and the scroll offset is preserved with no re-anchor. `scrollAnchor`
   (already exists) is the fallback when a change is above the viewport.
4. Decorations: recompute only for the spliced range; `invalidateDecorations`
   scopes `setNeedsDisplay` to the affected rect.

This single change makes edits O(changed blocks), removes the whole-doc
re-layout, and eliminates the caret/scroll jump — serving reflow speed, repaint
cost, and no-jump at once. Everything in Phase 1–3 is then built on top without
reintroducing full re-renders.

### Measurement & budgets (CI harness alongside 1.1)

- Instrument parse / render / splice separately; log on the real fixtures.
- Assert budgets: 1 MB parse < 1 s; single-edit re-render+splice < 16 ms;
  TTFT for a 70 k-char doc < 150 ms. Snapshot both stress fixtures so diagram
  and layout regressions can't creep back.

## Done (recent)

- Long-doc scrolling (NSTextView maxSize).
- Block decorations: code canvas + copy, callout boxes, table rules, diagram
  frames, front-matter chip.
- Flowchart edges: fan-out attachment on the node outline, back-edges routed
  around the band.
- Five distinct callout types (Note/Tip/Important/Warning/Caution).
- Real gaps between adjacent cards; blockquote rule moved into the gutter.
- Double-click to edit embeds; smart-pair wrap-selection; word-under-caret
  formatting.
- **1.2** Incremental render + splice (fragment cache, viewport-stable edits);
  caret lands where clicked instead of jumping to block end.
- **1.3** Nested cards (code/table/diagram/callout) inside a blockquote keep
  their own decoration — the quote styling flows around them.
- **2.1** Class & ER diagrams: shared orthogonal fan-out router
  (`routeBoxEdges`), relationship markers (▷ ◆ ◇, crow's feet); parser strips
  Mermaid multiplicity labels.
- **2.2** State diagrams: first-class recursive `StateDiagram` with composite
  containers, choice diamonds, fork/join bars, per-scope `[*]` terminals;
  `layeredPlacement` gained DFS back-edge detection for cyclic machines.
- **3.2** Math environments: `\begin{matrix|pmatrix|…|cases|aligned|align|
  alignedat}` grid layout; `\[…\]` / `\(…\)` delimiters recognised.
- Graceful fallback: unsupported math blocks degrade to the same tidy source
  card as unsupported mermaid.

## Phase 1 — Interaction correctness (the app must feel reliable)

### 1.1 Outline / TOC navigation is unreliable  — M
- **Symptom:** clicking an outline row does nothing, or jumps to an unrelated
  section. Worse in docs with repeated heading text ("Repeated heading",
  "Batch N").
- **Suspected cause:** the heading's `BlockID` (`contentHash:occurrence`) used by
  the outline doesn't match the key in `rendered.blockRanges`; occurrence
  indexing likely diverges between outline build and block render. `[TOC]`
  in-doc links and heading anchors must resolve through the same path.
- **Approach:** make one canonical id→range resolver; unit-test it on a doc with
  duplicate headings; verify `scrollTarget`→`scrollRangeToVisible` lands on the
  exact heading. Extend to `quoin-anchor://` links and the `[TOC]` block.

### 1.2 Clicking the editor feels unpredictable  — M/L
- **Symptom:** clicking around the viewport reacts oddly as a block flips from
  rendered to editable; the caret jumps to the end of the block.
- **Cause:** single-click activates a block, which re-projects it as raw source
  and resets the caret to the block end (there is no rendered↔source caret map).
- **Near-term approach (M):** on activation, don't force the caret to block end;
  keep it near the click, and minimise the reflow surprise (only the caret's
  span reveals). Embeds already require double-click.
- **Stretch (L):** a real rendered↔source character map (attach source ranges to
  inline AST nodes) so a click in rendered text lands the caret precisely and
  ⌘B works on a rendered selection without entering edit mode. Hot-path change;
  guard the byte-lossless round-trip.

### 1.3 Nested block decorations don't draw  — M ✅ done
- **Symptom:** a fenced code block inside a blockquote (or list item) renders as
  bare monospace with no dark canvas.
- **Cause:** decoration geometry/round-trip inside a nested container; the box's
  full-width override and the parent's indent/italic passes interact badly.
- **Approach:** compute decoration frames relative to the nested content bounds;
  don't let the blockquote's font/indent enumeration clobber child cards.
- **Fixed:** `renderBlockQuote` collects the child cards' `blockDecoration`
  ranges, skips them in the quote's italic/recolor/indent/quote-rule passes,
  and pushes each card's geometry with `indentCard(…by: 16)` so it follows the
  container. Nested code/table/diagram/callout keep their own canvas.

## Phase 2 — Diagram rendering quality

### 2.1 Class diagram edges  — M
- **Symptom:** relationship lines cross and tangle; center-to-center straight
  segments; markers (inheritance ▷, composition ◆, aggregation ◇) need clean
  placement.
- **Approach:** port the flowchart routing (fan-out attachment on box borders,
  orthogonal routes, label-on-segment). Draw relationship markers at the target
  border. Avoid label/line overlap.

### 2.2 State diagram layout  — L
- **Symptom:** complex machines (composite states, choice, fork/join) are a mess
  of crossings and long edges.
- **Approach:** reuse the improved layered routing; render choice as a small
  diamond, fork/join as bars, composite states as nested rounded containers with
  their own sub-layout. Phase: edges first, then composite/fork/join.

## Phase 3 — Coverage (breadth)

### 3.1 More Mermaid types  — L (per type)
- **Have:** flowchart, sequence, pie; class/ER partial.
- **Add, by likely usage:** solid state, gantt, then gitGraph / mindmap /
  timeline as reach. Each = parser + layout + renderer.
- **Guardrail:** anything unsupported must degrade to a *tidy* labelled source
  block, never a broken half-render.

### 3.2 Math coverage (toward MathJax-class)  — L
- **Symptom:** extreme LaTeX (matrices, `\begin{aligned}`, `cases`, `\nabla`,
  greek like `\varepsilon`, stacked sub/superscripts, nested fractions) falls
  back to source.
- **Options:** (a) grow the native typesetter incrementally for the constructs
  the fixtures actually use; (b) adopt a vetted math engine — requires a written
  TRD justification per the one-dependency policy. Recommend (a) first, measured
  against the fixture, then decide.

## Cross-cutting

- **Conformance harness (S/M):** parse+render both stress fixtures in CI; snapshot
  HTML export and key layout metrics so these regressions can't creep back.
- **Graceful fallback style (S):** one consistent "unsupported, shown as source"
  treatment for math/mermaid/extensions so degradation looks intentional.

## Remaining

- **3.1** More native Mermaid types — DONE, including gitGraph (and, via
  MermaidKit 0.5.0+, seven further types: venn, swimlane, tree view, event
  modeling, ishikawa, wardley, cynefin). All 30 recognised types render
  natively.
- **3.2 stretch** — DONE in Vinculum (accents, `\hline`/array column rules,
  and far beyond; see Vinculum's COVERAGE.md).
- **Cross-cutting** ✅ CI conformance harness: the monolithic stress docs are
  split into focused modules under `Fixtures/renderer/`, and
  `RendererConformanceTests` parses each, snapshots structural metrics, and
  asserts every native diagram lays out non-degenerately. Regenerate the
  snapshot with `QUOIN_UPDATE_SNAPSHOTS=1 swift test`.

## Suggested order

1.1 → 1.2 (near-term) → 1.3 → 2.1 → 2.2 → 3.x, with the conformance harness added
alongside 1.1 so fixes stay fixed. **Status: 1.1, 1.2, 1.3, 2.1, 2.2, and 3.2
are done and verified live on the stress fixtures; 3.1 and the CI harness
shipped subsequently. Nothing remains — see the status banner at the top.**
