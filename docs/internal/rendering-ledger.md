# Rendering issues ledger

Field reports from live use, one entry per issue. Status: OPEN → FIXED
(commit) / WONTFIX (reason). Newest first. Screenshots land in
docs/design/ when they carry information the prose doesn't.

## #11 — Fast typing scrambles edits into neighboring text — FIXED

*Reported 2026-07-10 (live use, ER diagram: a relationship label reading
"containsininnao"; "edits swallowed in the source, persisted forever in
the chart").* Root cause: a keystroke arriving BEFORE the previous
edit's projection echo computed its range against stale coordinates —
the model resolved it into the already-changed document, landing
characters at old offsets (inside neighboring labels). The chart
rendered the true, scrambled document; the source view looked like it
swallowed keys. Chart editing surfaced it because per-keystroke preview
renders occasionally push the round-trip past the inter-key interval.
Fix: mid-flight keystrokes (insertions and backspace) QUEUE in order
and flush one per echo, each computed at the freshly restored caret; a
2s watchdog prevents a lost echo from wedging typing; activation
changes drop the queue. Pinned by EditEchoSerializationTests.

## #9 — Venn diagram renders disjoint circles (no overlaps) — OPEN (MermaidKit)

*Reported 2026-07-10 (extreme stress test §18.35 venn-beta).* The four
sets render as four separate circles; every `union` directive is
ignored spatially — a venn with no overlap. This is MermaidLayout's
venn support (circle placement should solve for the union weights, or
at least overlap pairs with nonzero intersections). Belongs to the
MermaidKit repo + its CI; queue a MermaidKit session.

## #8 — Chart editing: preview not updating live; ✓ done leaves corrupted chrome — FIXED (shares #4's root)

*Reported 2026-07-10 (live use, mermaid).* While editing a chart the
anchored preview never re-rendered; clicking ✓ done left a blank
region: an empty diagram frame + ‹/› edit chip at top, and below it an
EMPTY accent editing frame with the drawn ✓ done chip still visible
(and still hit-testable) — a stale editingFrame decoration run that
survived the deactivation patch, over content that isn't the revealed
source anymore. Same family as #4 (stale decoration state across
activation patches). Root-cause plan: move the per-keystroke
ActiveBlockRenderPatch arithmetic from ReaderModel into the renderer
(it is pure projection math and currently UNTESTABLE — App target),
then pin open → type → close equivalence against a fresh full render;
fix what the test exposes, including QuoinTextView.noteStorageEdit run
maintenance if implicated.

## #7 — Diagrams/math must require the explicit ‹/› edit click — FIXED (937adcd)

*Directive 2026-07-10.* Double-clicking (or typing on) a rendered
diagram/equation must NOT flip it to source — those are presentation
objects; accidental flips are jarring. Activation paths for
mermaid/math: the ‹/› edit chip, ⌘↩ (explicit keyboard intent), and the
context menu. Code blocks/tables/TOC keep double-click.

## #6 — Preview-anchored reveal: jumps while typing invalid math; wants side-by-side — FIXED (a+b)

*Reported 2026-07-10 (live use, math blocks).* Two parts:

(a) STABILITY (fix now): typing through invalid states makes the layout
jump. Roots: (1) mid-edit source like `$$x^` stops PARSING as a math
block entirely — the block reclassifies as a paragraph and the whole
preview+frame machinery vanishes for a keystroke, then returns (the
held-last-good logic never runs because the KIND flapped); (2) the
"paused" note line toggles in/out between valid/invalid states, adding/
removing a line of height per keystroke. Fix: preview sticks through
kind reclassification while the editing session holds one (the held
render + note, not a disappearance), and the status line's height is
RESERVED while a preview is showing (empty when healthy) so validity
flaps never reflow.

(b) LAYOUT — SHIPPED as the floating-panel design: the preview no
longer enters the text flow at all. The renderer exposes it as
`RenderedDocument.previewPanel` (image + optional status message,
last-good hold and flap-stick preserved); the revealed source takes a
320pt tail indent; `PreviewPanelView` (click-transparent, hosted inside
the text view) rides the editing frame's drawn geometry via
`onEditingFrameGeometry`. Status lives IN the panel, so text-flow
height never changes with validity — the stacked reveal's whole
height-instability class is gone. Panel width fixed at 320pt for v1;
narrow-window clamping is polish.

## #5 — Revealed indented code block: styled as markdown, caret lands oddly — FIXED (styling; caret uses the generic walk)

*Reported 2026-07-10 (kitchen-sink §7.1 Indented Code Block).* Clicking
into an indented (non-fenced) code block reveals source where markdown
is STYLED (**not bold** renders bold, `not link` renders as a live-blue
link, inline-code fills appear) and the caret lands in an odd spot
(below the block in the report). Two roots: (a) the styler's
code-context guard keys on fences/backticks, which indented code lacks,
so span styling and collapses run inside verbatim content; (b) the
rendered body is DEDENTED, so the `embedSourceStart` 1:1 resolution
(`range(of: bodyText)` in the slice) fails, killing the exact caret
mapping — clicks fall back to the generic alignment walk across content
that differs by leading spaces per line. Fix direction: gate the styler
by BLOCK KIND (the renderer knows it's a code block; don't re-derive
from text), and resolve embedSourceStart per-line or map through
line+column instead of a contiguous byte offset.

## #4 — Activating a callout corrupts callout chrome — its own and its neighbors' — FIXED

*Reported 2026-07-10 (kitchen-sink §callouts).* Fresh render is correct.
Click into a callout and: the active callout's tinted box lingers
partially (covering one revealed line, offset from the text); after
activating, FOLLOWING callouts' boxes shrink to cover only their title
line while their body text sits outside the box carrying a stray
reveal-tint highlight. Reads as decoration runs shifted by a wrong
delta across the activation patch, or stale geometry not invalidated.
Recovers on… (verify: does clicking away restore?). Suspects:
QuoinTextView.noteStorageEdit run partitioning around the flip patch,
activationFlipUpdate patch extents for container blocks, restyle
attribute sync.
*Root cause (found via the second field screenshot):* SwiftUI coalesces
projection revisions; the fallback splice trims by common STRING
prefix/suffix, but attributes differ beyond the string change — a
revealed callout body is string-identical to its rendered text, so the
splice kept those characters with their reveal attributes (tint, no box
→ box shrunk to the title line). The same mechanism kept the OLD
attachment when a re-rendered diagram produced the same U+FFFC
character — #8's 'preview never updates' and its stale ✓ done frame.
Fix: the splice now runs syncAttributesWhereDifferent across the whole
document afterwards (walks attribute runs, not characters; perf budgets
hold). Pinned by ActivationNeighborIntegrityTests — the two mechanism
tests fail 2/2 with the sync disabled.

## #3 — Revealed entity line shows a row of bare ampersands — FIXED

*Reported 2026-07-10 (kitchen-sink §2 entities).* Clicking into a line
of rendered HTML entities reveals "& & & & & … &#169; &." — every named
entity collapses to its faded `&` with the tail hidden, so the revealed
source is unreadable and looks corrupted (the characters are still
there at 0.1pt, so edits work; the LOOK is the bug). Expected: entities
follow the span-delimiter rule — the entity under/near the caret shows
its full literal source (`&amp;`), others may stay collapsed; a line of
naked ampersands is never acceptable.

## #2 — Nested content inside loose list items escapes the item — FIXED (937adcd)

*Reported 2026-07-10 (kitchen-sink §6.4 Loose Lists).* Two symptoms, one
family with #1: (a) a continuation paragraph belonging to a loose item
("This paragraph belongs to loose item one.") renders at column x=0 with
no item indent — it reads as a stray paragraph between bullets, not as
the item's content; (b) a fenced code block inside a loose item draws
its canvas full-width, breaking out of the list exactly like #1's quote
case. Expected: nested content aligns under the item's text column;
boxed children inset accordingly.
*Fix note:* cards carry `BlockDecoration.leadingInset`; the quote RULE still
pauses alongside a nested card (one decoration attribute per range) — tracked
as polish, the inset canvas reads as nested either way.

## #1 — Code block inside a blockquote breaks out of the quote — FIXED (937adcd)

*Reported 2026-07-10 (kitchen-sink §5 Blockquotes).* A fenced code block
nested in a blockquote draws its dark canvas at FULL column width,
ignoring the quote's indent: the canvas visually escapes the quote,
covers the quote rule's lane, and reads as a sibling block that
interrupts the quote instead of content inside it. Expected: the canvas
(and its code) sit inset within the quote, the 3pt rule running
unbroken alongside.
