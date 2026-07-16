# 0004 — The live embed preview is a side panel, not an inline run

Status: Accepted (supersedes the original inline lead-preview design).

## Context
While editing a mermaid/math block you need to see the artifact. The first
implementation led the revealed fragment with an INLINE preview run, which
made the editable range start mid-fragment (`editableRange.location != 0`)
and forced every projection path to offset through it.

## Decision
The preview is a floating SIDE PANEL beside the source (source paragraphs
take a matching tail indent). The last-good render is held while mid-edit
source is broken (never blank, never flashing); retention state is
`HeldPreview`, owned by the model and threaded through render passes as an
explicit inout.

## Consequences
- `editableRange.location == 0` became an invariant; the offset arithmetic
  the inline design required was dead code for months until deleted
  (editor-modes review finding 1 / plan 3.4) — the cautionary tale for
  leaving accommodations after their reason moves.
- Text-flow height never changes with parse validity (no reflow while typing
  through broken source).

## Evidence
AttributedRenderer.assembleRevealedFragment; PreviewAnchoredRevealTests;
editor-modes review (2026-07-14) findings 1 and T4.
