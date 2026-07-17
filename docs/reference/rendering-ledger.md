# Rendering & reading-UX ledger

Open gripes about how text *reads* on screen — line metrics, wrapping, and
navigation affordances — that aren't yet issues. Each entry names the symptom,
the suspect code, a hypothesis, a fix direction, and how to prove it. Promote to
a GitHub issue when picked up; delete when shipped.

Format mirrors [`code-hygiene-ledger.md`](code-hygiene-ledger.md): **severity**
(H/M/L) · pointer · what and why.

---

> **Status:** R2 and R3 shipped; R1 narrowed, INTERMITTENT, not currently
> reproducible (last checked on 1.0.2, 2026-07-16). See its note — the renderer
> is proven height-neutral, so this is a state/timing-dependent live-view
> symptom; capture it (screenshot + observations) if it recurs rather than
> editing the reveal path blind.

## R1 — H · Revealing a wrapped paragraph explodes its line height — NARROWED, OPEN

**Symptom.** Reading is fine; the moment the caret enters a *soft-wrapped* body
paragraph (it activates and reveals its source), the inter-line spacing balloons
— each visual line gains a large gap. A short (single visual line) paragraph
looks unchanged, so it only bites on real prose. Reported from the "How Quoin
Gets Built" note; visible as the caret moves from a heading down into the first
paragraph.

**Where.** `MarkdownSourceStyler.baseAttributes()` —
`Sources/QuoinRender/MarkdownSourceStyler.swift:86` sets
`style.lineHeightMultiple = 1.5`. The *rendered* body paragraph uses
`lineHeightMultiple = 1` (`AttributedRenderer`, the body paragraph styles
around lines 990/1033/1089). So the revealed source is 1.5× the rendered line
height — the reveal is NOT transplanting the block's rendered per-line metric,
it's imposing its own.

**Why it matters.** This is a direct violation of the viewport invariant
(docs/reference/invariants.md): edit mode must keep the block's vertical
skeleton — a reveal is a per-line style transplant, height-neutral by
construction. A 1.5 vs 1.0 line-height mismatch moves every line below the caret
on screen the instant you focus.

**Fix direction.** The reveal styler should adopt the SAME line metric the
renderer used for that block (body → 1.0), not a hardcoded 1.5 — ideally read it
from the theme/rendered paragraph style rather than duplicating a literal (two
literals for one metric is the "recognizers diverge" class again).

**Verify.** `RevealFidelityTests` pass today, so they don't cover a body
paragraph that WRAPS to ≥3 visual lines. Add a failing test first: render a long
paragraph in a fixed-width container, reveal it, assert total laid-out height is
unchanged within epsilon.

**Update (investigated).** Added exactly that test —
`testWrappedParagraphRevealIsHeightNeutral` (measures at width 320) — and it
**PASSES**. So the RENDERER is height-neutral even for a wrapped paragraph: the
`renderEditableSource` → `transplantParagraphStyles` path overrides the styler's
1.5 with the rendered block's per-line metric on every renderer call (all
callers pass `document`). The explosion is therefore in the LIVE AppKit apply
path, not the styling. Prime suspect: `ReaderCoordinator.restyleActiveBlock`
(`Sources/QuoinRender/AppKit/ReaderCoordinator.swift:~838`) SUBSTITUTES storage's
existing `.paragraphStyle` for the fragment's transplanted one on every caret
move (a workaround predating the transplant, with a documented "height collapse"
regression if removed naively) — but storage *should* already hold the correct
transplanted style after activation, so this doesn't fully explain it. **Next
step: live instrument** — log the active paragraph's resolved
`lineHeightMultiple` from storage on activation + first caret move, reproduce in
the running app, and trace which write leaves the exploded value. Do NOT change
the delicate reveal/caret code blind; the renderer test guards against a
styling-layer regression while this is chased.

---

## R2 — M · Real word-wrap / no-wrap setting — ✅ SHIPPED

**Symptom / request.** There's no user control over wrapping. We want an
explicit **Wrap / No Wrap** setting that applies as consistently as possible to
BOTH the rendered projection and the revealed source — long lines either wrap to
the column or scroll horizontally, the user's choice.

**Where.** `MarkdownReaderView.swift:321` — `container.widthTracksTextView =
true` is what forces wrapping today. No-wrap means `widthTracksTextView = false`
+ an unlimited-width container + horizontal scroll enabled on the scroll view
(mind the existing "scrollable NSTextView needs unlimited maxSize" pitfall).

**Design notes.**
- Persist as `@AppStorage("QuoinWordWrap")`; expose in the View menu and/or
  Settings ▸ Advanced.
- The reader uses a fixed content column (max ~680pt). No-wrap should let a long
  line exceed the column and scroll horizontally without breaking the centered
  column for wrapped content — decide whether no-wrap drops the column cap.
- "As best we can": code canvases already manage their own width; the setting
  primarily governs prose and revealed source. Tables/diagrams are out of scope.
- Keep it consistent across the rendered and revealed states so toggling doesn't
  reflow-jump the caret (respect the viewport invariant on the toggle itself).

**Shipped.** `@AppStorage("QuoinWordWrap")` (default wrap); **View ▸ Wrap Lines**
toggle. `MarkdownReaderView.applyWrapMode` flips `widthTracksTextView` + an
unlimited-width container + a horizontal scroller, applied in make + update so
the toggle is live. One text container serves both rendered and revealed source,
so it applies to both. Code canvases keep their own width.

---

## R3 — H · Outline stops highlighting the section you're reading — ✅ SHIPPED

**Symptom.** The current-section highlight in the outline only lights up a
heading as it *approaches* the top of the viewport, then reverts to the PREVIOUS
(ancestor) heading once that heading scrolls above the top — even though you're
still reading inside its section. Observed: "One source of truth…" highlights
near the top, then flips back to "How Quoin Gets Built" as soon as you scroll
past the H2, while still deep in the H2 section.

**Where.** `ReaderScreen.currentSection` — `App/macOS/Sources/ReaderScreen.swift:786`.
It walks `model.outline` and keeps the last heading whose
`blockRanges[heading.id].location <= blockRanges[topBlockID].location`, driven by
`onTopBlockChange` → `topBlockID` (line 166) and `currentSectionID` into
`OutlinePanel` (line 369).

**Hypothesis.** The comparison relies on `blockRanges` (the coordinator's
`[BlockID: NSRange]`, `ReaderCoordinator.swift:22`). If a heading scrolled ABOVE
the viewport is absent from / stale in that map (TextKit 2 lays out visible
fragments; off-screen ranges can be unavailable), the loop `continue`s past it
and `current` never advances to the in-view section's heading — so it falls back
to an earlier heading (or `outline.first`). The section you're reading loses its
highlight exactly when its heading leaves the top.

**Fix direction.** Resolve the current section by DOCUMENT block ORDER, not by
possibly-viewport-dependent character ranges: find the top block's index among
`document.blocks`, then the nearest heading at or before that index. Order is
always available even when a block isn't currently laid out. Alternatively,
guarantee `blockRanges` covers every block (not just visible ones) and keep the
range comparison.

**Verify.** Unit-test the section-resolution as a pure function: given a
top-block that is a paragraph inside section B (heading B above it, heading A
before that), it must return B — including when B's own range is unavailable.
Currently it should return A/first, reproducing the bug.

**Shipped.** Extracted to a pure `OutlineNavigation.currentSection(topBlockID:
blocks:outline:)` (QuoinCore) keyed on document block INDEX, wired into
`ReaderScreen.currentSection`. `OutlineNavigationTests` (5) prove a paragraph
deep in a section still reports that section (the failing case), plus the
fallbacks. The outline manual-collapse highlight (#74) is unaffected — it keys
on the same `currentSectionID`, now more accurate.
