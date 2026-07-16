# Editor modes — implementation plan (4 phases)

Status: **phases 0–3 SHIPPED** (2026-07-14, fb4cdbe..e38ba5d; as-built
deviations recorded inline in Phases 2 and 3). Phase 4 (documentation
retool) in progress. Companion to `editor-modes.md` (the model + diagnosis)
— this is the *how*. Incorporates the adversarial design review of
2026-07-14: every phase below reflects its amendments (settle in
`viewWillDraw`, view-owned caret contract, viewport-scoped geometry,
patches-only hot path, Stage-4-as-AX re-scope) and its two new confirmed
bugs (separator-clamp drift, stale-caret rerender), which landed in Phase 0.

Ground rules for every phase:

- **Behavior-preserving unless the phase says otherwise.** The guard is the
  existing suites — `RevealFidelityTests`, `CaretLineAnchorTests`,
  `FlipTransitionFidelityTests`, `RendererConformanceTests` (digest must not
  change) — plus the new tests each phase adds. `swift test` green before
  every commit; commit + push per completed step (repo workflow).
- **Escape hatches stay.** Every patch path keeps its bail-to-full-render
  fallback. A phase may never convert "falls back, correct" into "single
  path, wrong."
- **No new dependencies.** Everything here is stdlib + existing targets.

---

## Phase 0 — Settled draws + targeted correctness fixes  (S, 2–3 commits)

Goal: finish what Stage 0 started (every draw is a settled draw, zero stale
frames) and fix the two review-confirmed bugs, which are user-visible and
adjacent to the overlap symptom.

### 0.1 Move the settle into `viewWillDraw`

Current state (shipped): `invalidateDecorations` / `redrawDecorations` /
`noteStorageEdit` each dispatch `settleDecorations()` async — which shortens
the box-lags-text window to **one frame** but doesn't remove it, and
`setFrameSize` (resize reflow) has no settle at all.

Change (`Sources/QuoinRender/AppKit/QuoinTextView.swift`):

- Override `viewWillDraw()`: call
  `textLayoutManager?.textViewportLayoutController.layoutViewport()` before
  `super`. Layout is legal in `viewWillDraw`; after it, the draw pass reads
  settled fragment geometry by construction.
- Remove the async `settleDecorations()` dispatches from all three
  invalidation paths (keep the synchronous `needsDisplay` + run maintenance;
  delete `settleDecorations()` itself).
- Termination argument (why this can't loop): `layoutViewport()` on settled
  content is a no-op; if it *changes* geometry it invalidates display, the
  next draw settles again, geometry is now fixed → terminates in ≤2 passes,
  and both happen before pixels hit the screen.
- Instrument with `QuoinPerformanceTrace.measure("draw.settleViewport")` so a
  perf regression on large docs is measurable, not anecdotal.

### 0.2 Guard the caret-line invariant across the settle (>200k docs)

Risk identified in review: above 200k chars `updateNSView` skips eager
layout, so the settle can resolve estimated heights *after* `pinCaretLine`
ran — moving the pinned line with no re-pin. That would be a Stage-0-induced
violation of the viewport invariant.

- Add a >200k fixture case to `CaretLineAnchorTests`: build a long document
  (programmatically generated paragraphs + code blocks), activate a block
  deep in it, assert the caret line's screen Y is identical before and after
  a forced `viewWillDraw` settle pass.
- If the test fails: re-assert the pin after the settle — `viewWillDraw`
  compares the caret line's Y before/after `layoutViewport()` and, when the
  pin generation is current, scrolls by the delta. (Test-first; only add the
  re-pin if the test proves it's needed.)

### 0.3 Fix separator-clamp drift (review finding: phantom paragraph)

Mechanism: the per-keystroke patch replaces the fragment *excluding* its
separator and guards with `separatorSignature`, which compares the
separator's **characters** — but the clamped-vs-normal *style* depends on
whether the revealed slice ends with a newline, which typing changes. Result:
type a trailing newline into a revealed block → phantom empty paragraph until
the next flip; delete one → the inverse.

- `App/macOS/Sources/ReaderModel.swift`: fold the clamp state into the
  signature — `makeActiveBlockRenderPatch` computes
  `revealNeedsClampedSeparator` for **both** old and new slices; if they
  differ, return nil (falls back to the full render, which restyles the
  separator correctly). Minimal, safe, and Phase 3 later removes the
  duplication entirely.
- Test (`Tests/QuoinCoreTests` reveal fidelity): activate a code block, apply
  an edit appending a trailing newline via the model's edit path, assert the
  projected attributed string equals the full-render projection byte-for-byte
  (this is a mini-version of Phase 3's equivalence property).

### 0.4 Fix stale-caret rerender (review finding: span reveal snaps back)

Mechanism: plain caret moves update only the coordinator's `lastStyledCaret`;
the model's `caretInActiveBlock` is written only on activation and edit-echo.
A model-initiated rerender while a block is open (async image decode →
`scheduleAsyncContentRerender`) styles the reveal with the **activation-time
caret** → the revealed span jumps back.

- `ReaderModel`: add `func noteActiveCaretMoved(_ offset: Int)` — writes
  `caretInActiveBlock` **without** bumping `caretGeneration` (so no caret
  restore fires in the view; it's a bookkeeping write, `@ObservationIgnored`
  semantics preserved via a plain property write that doesn't trigger a
  rerender).
- `ReaderCoordinator.textViewDidChangeSelection`: when the selection is
  inside the active editable range, call `noteActiveCaretMoved` with the
  block-relative offset it already computes for the restyle.
- Test: activate a block, move the caret (simulated selection change),
  trigger `rerender()` directly, assert the styled output reveals the span at
  the *moved* caret, not the activation caret.

**Exit criteria:** all fidelity suites green; new tests green; manually (when
eyes are available): no one-frame decoration lag while typing in a code
block, no phantom paragraph on trailing newline, no span snap-back during
image loads.

---

## Phase 1 — `BlockPresentation` owner  (M, 2–3 commits)

Goal: one pure function decides every block's presentation; all four
projection paths *read* it. No rendering-output change (conformance digest
byte-identical).

### 1.1 Purity precursor: evict the renderer's hidden mutable state

`AttributedRenderer` holds two reference-boxed mutables that make it
non-pure: `activePreviewBox` (last-good preview held across renders) and
`revealVerbatimBox`. `present()` cannot be the single source of truth while
these decide output out-of-band.

- Move **last-good preview retention** into `ReaderModel` (it's session
  state, not renderer state): the model owns `heldPreview: (blockID, image,
  lineage)` and passes it *into* the render as an input. The renderer's
  preview logic becomes: given source + held preview, emit
  `previewPanel` payload — no captured box.
- `revealVerbatimBox` becomes a plain derived value (it's a function of the
  active block's kind — it never needed to be a box once flavor is explicit).

### 1.2 The types and the function

New file `Sources/QuoinRender/BlockPresentation.swift` (platform-free):

```swift
public enum EditingFlavor: Equatable, Sendable {
    case prose                    // markdown-styled source, caret-scoped span reveal
    case verbatim                 // raw source, zero markdown styling
    case preview                  // verbatim + side-panel live artifact
}

public enum BlockPresentation: Equatable, Sendable {
    case rendered
    case editing(flavor: EditingFlavor)
}

public struct PresentationMap: Equatable, Sendable {
    public let activeBlockID: BlockID?
    public subscript(id: BlockID) -> BlockPresentation { ... }
}

/// THE single derivation. Pure. Callable from model and view.
public func presentation(
    for document: QuoinDocument,
    activeBlockID: BlockID?
) -> PresentationMap
```

Flavor table (encodes today's behavior exactly): `codeBlock`, `htmlBlock`,
`frontMatter`, indented code → `.verbatim`; `mermaid`, `mathBlock` →
`.preview`; everything else → `.prose`. Unit-tested as a table.

### 1.3 The caret contract (review amendment — this is the crux)

The **caret is view-owned.** `presentation()` deliberately takes no caret:
which *block* is editing and its *flavor* don't depend on the caret. The
caret governs only *intra-block* span reveal, and that stays a synchronous
view-side styler pass. Contract:

- **Model call site** (projection changes): `presentation(for:activeBlockID:)`
  decides what the renderer emits per block.
- **View call site** (caret moves): the restyle pass asks the *same*
  `PresentationMap` (carried on `RenderedDocument`) for the active block's
  flavor, and styles with the view's live caret. One function, two call
  sites, same value — the caret is a *parameter of the styler pass*, never of
  the mode.
- Phase 0.4's `noteActiveCaretMoved` keeps the model's copy fresh for
  model-initiated rerenders; Phase 3 makes the two styler invocations share
  one implementation.

### 1.4 Route the consumers (mechanical, no behavior change)

- `RenderedDocument` gains `presentationMap` (replacing ad-hoc
  `revealVerbatimCode` — derived: `map[active] == .editing(.verbatim)`).
- `AttributedRenderer.render` / `renderEditableSource` /
  `assembleRevealedFragment`: replace every `isEmbedEditingKind` /
  kind-switch reveal decision with a `switch map[block.id]`.
- `activationFlipUpdate` + `makeActiveBlockRenderPatch`: take the map,
  stop re-deriving "is this a verbatim reveal."
- `restyleActiveBlock`: read flavor from `rendered.presentationMap` (the
  hand-configured bool plumbing shrinks; it dies fully in Phase 3).

### 1.5 Spec rows the review found missing (documented now, enforced by
construction as phases land)

- **Undo/redo transition:** an undo that removes the active block ⇒
  deactivate to `.rendered` with **no flip animation**, caret at the undo's
  edit location (extends the existing `document.block(withID:) == nil`
  deactivation). An undo that re-breaks a healed fence ⇒ the swallowed
  blocks re-render; presentation follows the new AST. Test: undo across an
  Escape fence-heal.
- **External disk change mid-edit:** conflict path forces `.rendered` +
  banner (today's behavior, now stated).
- **One active block is an invariant, not an accident** (multi-caret is
  explicitly out of scope).

**Exit criteria:** `presentation()` unit tests green; conformance digest
unchanged; grep proves no remaining kind-based reveal decisions outside the
flavor table.

---

## Phase 2 — Viewport geometry snapshot + merged editing chrome  (M, 3 commits)

Goal: one measure pass per settled draw produces the geometry every chrome
consumer reads. Includes the re-scoped Stage 4 (accessibility) — the chrome
becomes a real AX element.

### 2.1 `BlockLayoutSnapshot` (viewport-scoped, double-buffered — review amendments)

New in `QuoinRender/AppKit`:

```swift
struct BlockLayoutSnapshot {
    let revision: Int              // projection revision it was measured against
    let viewportRange: NSRange     // what was actually measured (+slack)
    let containerWidth: CGFloat
    let rects: [BlockID: BlockGeometry]   // union + firstLineRect + lineFrames
}
```

- Built in **one measure pass** at draw time (post-settle geometry), stored
  on the view (`measuredRuns`). Every chrome consumer reads the snapshot.
- **Viewport-scoped by design** — a document-wide map would reinstate the
  lay-out-the-whole-file-per-draw regression the culling comment records.
  Off-viewport consumers get `nil` and are culled exactly as today.
- **As-built deviations** (recorded post-implementation): the snapshot keys
  by decoration RUN, not BlockID — runs are what drawing consumes, and a
  block can carry several (quote text runs vs nested cards). And the
  `flipCaptureWorthwhile` `boundingRect` estimate STAYS: the review's own
  finding 4 established its failure mode is cosmetic-only (a missing or
  superfluous animation, never overlap), and the new fragment it estimates
  is not yet in storage at capture time — TextKit cannot measure text that
  has no layout without a throwaway scratch pass, which would cost more
  than the estimate's worst case. The flip's real slide delta was already
  TextKit-measured on both sides.

### 2.2 Merge the editing chrome

- `drawBackground` draws every decoration from `snapshot.rects[blockID]` —
  the per-kind `draw()` methods take a `BlockGeometry`, not a self-enumerated
  union.
- New `EditingChrome` value: given the active block's `BlockGeometry`,
  derives **border rect, ✓ chip rect, chip text origin** in one place.
  `doneChipRect`, the tooltip rect, and `onEditingFrameGeometry` (preview
  panel anchor) all read from this one value — the chip can no longer
  disagree with its border.
- Draw the chip **after** glyphs (move from `drawBackground` to a
  `draw(_:)` override tail or a front layer) — fixes review Seam 5's "long
  code line paints over the chip."

### 2.3 Accessibility (Stage 4, re-scoped per review)

- Expose the chrome as an `NSAccessibilityElement` child of the text view:
  role `.button`, label "Done editing", frame = chip rect from
  `EditingChrome`, action → the existing done-chip path.
- Post `.announcement` on representation swaps (activate/deactivate) —
  extends the existing pattern used for preview pause.
- `NSTextAttachmentViewProvider` embeds are **dropped** (they'd resurrect the
  offset machinery Phase 3 deletes and break the 1:1 revealed-source
  invariant).

### 2.4 Tests

- New `DecorationGeometryTests`: lay out a fixture with an active code block
  in a headless text view; assert border rect, chip rect, and canvas rects
  all derive from the same `BlockGeometry` union (and that chip ∩ border
  edge geometry matches `EditingChrome`'s derivation).
- Extend `FlipTransitionFidelityTests`: endpoints must come from
  snapshot `previous`/`current`; assert no `boundingRect` path remains.
- AX test: when a block is editing, the text view exposes exactly one
  "Done editing" button element whose frame equals the chrome's chip rect.

**Exit criteria:** exactly one call site enumerates fragment frames for block
chrome (grep-enforced); flip endpoints single-engine; VoiceOver can activate
Done; RTL remains explicitly LTR-only (documented — geometry is now
single-site for a future RTL pass).

---

## Phase 3 — One projector  (L, 4–5 commits, sub-staged)

Goal: collapse the four projection paths into one block-diff projector whose
**hot-path output is storage patches** (never a materialized full string —
that's the actual perf property, per review), plus one shared styler pass.
Delete the dead machinery.

### 3.1 Centralize separator policy (first — it de-risks everything after)

- New `SeparatorPolicy` (QuoinRender, platform-free):
  `func separator(after block: Block, revealed: Bool, sliceEndsInNewline: Bool)
  -> (string: NSAttributedString, clamped: Bool)`.
- Replace the three independent computations (render loop, flip patch,
  per-keystroke patch) and delete `separatorSignature` — the guard becomes
  structural equality of the policy's output. Phase 0.3's clamp-drift fix is
  subsumed (and its bail can be relaxed to a separator patch).
- Test: property test over fixture corpus — for every adjacent block pair ×
  revealed/rendered, the three former call sites (now one) produce identical
  separators.

### 3.2 The projector

New `BlockProjector` (QuoinRender):

- **One fragment function**: `fragment(block, presentation, theme, held
  preview) -> NSAttributedString` — merges `render(block:)` and
  `renderEditableSource` behind the flavor switch. The fragment cache keys on
  (blockID, presentation) so rendered and editing fragments coexist.
- **One update function**:
  `project(from old: RenderedDocument, to inputs) -> ProjectionUpdate`
  where `ProjectionUpdate` is `.patches([RenderStoragePatch])` or
  `.full(NSAttributedString)`. Uses `BlockDiff.between(old,new)` to find
  changed blocks; emits one patch per changed fragment + separator (keystroke
  ⇒ 1 patch; flip ⇒ ≤2; anything violating an invariant ⇒ `.full`).
- `rerender`, `applyActivationFlipPatch`, and `makeActiveBlockRenderPatch`
  become thin callers of `project` — then get deleted as their logic is
  absorbed. Offsets shift through **one** `OffsetShift` utility (replaces the
  two hand-rolled blockRanges loops).

### 3.3 Fold in the caret-move restyle (kill path 4)

- The view's `restyleActiveBlock` calls the projector's **styler pass**
  directly: `projector.restyle(fragment:for:presentation:caret:)` — the same
  derivation `fragment()` uses, with the view's live caret. Synchronous,
  attribute-only, same-frame (review constraint: caret moves must NOT ride
  the async model→SwiftUI→splice pipeline — it collapses selections and
  queues behind the edit echo).
- The hand-built `MarkdownSourceStyler` configuration and the
  `revealVerbatimCode` plumbing die here.

### 3.4 Delete the dead machinery + correct the record

- `activeEditableRange` becomes `blockRanges[active]` (offset arithmetic was
  `+0` — review-confirmed); delete `RevealedFragment.editableRange`'s
  consumers and the three per-path computations.
- Delete the stale comments (ReaderModel "preview leads the fragment",
  RevealedFragment doc comment) and **fix CLAUDE.md's embed-editing
  paragraph** (it still teaches the pre-side-panel model — a durable
  misdirection for future sessions).

### 3.5 IME / marked text (review: currently undefined behavior)

- `applyProjection` gains a marked-text gate: while
  `textView.hasMarkedText()`, projections affecting the active fragment are
  **deferred** (latest-wins queue) and applied on `unmarkText`. Keystroke
  replay (`pendingInsertion`) is suppressed during composition.
- Manual verification protocol documented (dead-key ⌥e-e, pinyin) — IME is
  not unit-testable headlessly; the gate itself gets a unit test via a
  simulated `hasMarkedText` flag.

### 3.6 The equivalence property test (the big guard)

New `ProjectorEquivalenceTests`: for a corpus (all renderer fixtures) × a
scripted set of edits (typing, newline insertion/deletion at boundaries,
activation flips, undo), apply edits through the **patch path** and through a
**fresh full render**, and assert the resulting attributed strings are
**byte- and attribute-identical**. This single property subsumes T1/T2/T6:
any separator, offset, or base-length disagreement fails it. Add to CI.

### Phase 3 as built (recorded post-implementation)

3.1/3.3/3.4/3.5 landed as specified. 3.2 landed as **relocation + shared
derivations rather than a literal single-entry merge**: the per-keystroke
patch construction moved into the package
(`AttributedRenderer.activeBlockEditUpdate`, beside `activationFlipUpdate`),
so both patch producers live next to the render loop, share the ONE
separator policy, styler config, and preview retention, and are
headlessly provable. 3.6's corpus (39 flip + 30 keystroke equivalences
across all renderer fixtures, attachments compared by presence, held
preview threaded identically on both sides) then enforces the plan's real
goal — the paths CANNOT drift — as a permanent CI property rather than by
code unification. Collapsing the remaining three call sites into a single
`project()` entry is now an optional refactor with no correctness stake;
do it if/when the suggestions input mode (S3) wants one seam to hook.

**Exit criteria:** one projector + one styler pass (grep: no
`MarkdownSourceStyler(` outside the projector); patches-only hot path
(perf budgets in `PerformanceTests` unchanged or better); equivalence
property green in CI; CLAUDE.md corrected.

---

## Phase 4 — Documentation retool  (M, after Phase 3)

Goal (user directive): the docs read like the app ships — current, honest,
and pointing at the right sources of truth.

- **README + docs/ accuracy sweep** against actual shipped behavior after
  Phases 0–3 (editing model, modes, invariants; kill stale claims).
- **Screenshots**: regenerate via the CI screenshot pipeline + gallery
  fixtures so every image shows the current rendering; verify the
  `ci-screenshots` branch pipeline still reflects reality.
- **Support matrix**: one accurate table of what renders natively vs
  degrades, kept small.
- **MermaidKit + Vinculum prominence**: present both as the first-party
  engines they are, and DEFER to their repositories' documentation
  (COVERAGE.md / COMMANDS.md / gallery branches) for feature detail instead
  of duplicating matrices in Quoin's docs — Quoin documents the
  *integration*, the engines document *themselves*.
- **Cross-reference hygiene**: architecture.md + CLAUDE.md updated to the
  post-refactor machinery (subsumes Phase 3.4's CLAUDE.md embed-paragraph
  correction); editor-modes.md marked implemented.

## Sequencing, risk, and rollback

| Phase | Size | Risk | Rollback story |
|---|---|---|---|
| 0 | S | Low — mechanical + two contained bug fixes; the >200k pin test guards the one real risk | Revert single commits; each step independent |
| 1 | M | Low-medium — mechanical routing; purity eviction touches preview retention | Digest + fidelity suites gate every commit |
| 2 | M | Medium — drawing/measure rework; perf must be watched (should improve) | Snapshot sits beside old path for one commit (assert-equal), then old path removed |
| 3 | L | Highest — hot-path surgery; sub-staged (3.1 first, 3.6 before deleting old paths) | Old paths deleted only after equivalence test is green in CI against the projector |

Order is strict: 0 → 1 → 2 → 3. Each phase ships to `main` independently and
the app is usable after every commit. Phases 1–3 need no visual verification
(headless suites are the gate); Phase 0's decoration-lag fix and Phase 2's
chrome are worth an eyeball when a screen is available.
