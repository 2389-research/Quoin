# 0002 — TextKit 2, drawn-ink decorations, no HTML/web view

Status: Accepted.

## Context
Rendering rich markdown needs either a web view (Mermaid.js/KaTeX stack), or
native text layout. The product stance is zero JavaScript at runtime,
local-only, native feel.

## Decision
TextKit 2 (`NSTextView` subclass) displays one attributed-string projection.
Block chrome (code canvases, callouts, rules, frames, chips) is DRAWN INK in
the view from laid-out fragment frames — never `.backgroundColor` attributes
(per-glyph backgrounds render as per-line strips; that shipped as a bug
once) and never attachment subviews for passive chrome.

## Consequences
- Viewport-lazy layout scales to novel-length documents.
- Geometry timing becomes OUR problem: every draw must read settled layout
  (the viewWillDraw settle + single measure pass, editor-modes Phase 0/2).
- Drawn ink is invisible to accessibility by default — interactive chrome
  must be explicitly exposed (the ✓ done chip's AX element).

## Evidence
CLAUDE.md pitfalls (per-line strips; maxSize; paragraph spacing);
editor-modes design §3–5; DecorationGeometryTests.
