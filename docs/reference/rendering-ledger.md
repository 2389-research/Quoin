# Rendering & reading-UX ledger

Open gripes about how text *reads* on screen — line metrics, wrapping, and
navigation affordances — that aren't yet issues. Each entry names the symptom,
the suspect code, a hypothesis, a fix direction, and how to prove it. Promote to
a GitHub issue when picked up; delete when shipped.

Format mirrors [`code-hygiene-ledger.md`](code-hygiene-ledger.md): **severity**
(H/M/L) · pointer · what and why.

---

## R1 — H · Revealing a wrapped paragraph explodes its line height

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
paragraph that WRAPS to ≥3 visual lines (the existing paragraph cases are short
enough not to expose the multiplier, or they compare block spacing rather than
intra-block leading). Add a failing test first: render a long paragraph in a
fixed-width container, reveal it, assert total laid-out height is unchanged
within epsilon. Then fix the multiplier and watch it go green.

---

## R2 — M · Real word-wrap / no-wrap setting, applied to source *and* rendered

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

**Status.** Feature, not a bug. Bounded; good standalone issue.

---

## R3 — H · Outline stops highlighting the section you're actually reading

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

**Related.** Interacts with the outline's manual-collapse highlight (#74, done)
— keep "highlight the collapsed ancestor" behavior intact when this changes.
