# 0001 — The markdown string is the source of truth, never attributed strings

Status: Accepted (project-founding; reaffirmed by every phase since).

## Context
A WYSIWYG editor needs an authoritative document representation. The obvious
AppKit path — let NSTextStorage be the document — couples the file format to
the view, makes round-trip fidelity accidental, and forces every exporter and
tool through the view layer.

## Decision
The markdown string + AST is authoritative. The editor is a PROJECTION;
edits mutate the source through `DocumentSession` and the renderer
re-projects. Byte-lossless round-trip for untouched regions is a hard rule.

## Consequences
- Reveal/editing must maintain a character-exact source mapping (the 1:1
  revealed-source invariant, 1pt-clear hidden delimiters).
- The projection machinery (patches, splices, equivalence) exists BECAUSE
  re-projecting must be cheap; see ADR-0008.
- Interop is free: any tool that writes markdown writes Quoin documents —
  the basis of the suggestions/CriticMarkup design (docs/design/suggestions.md),
  where RoughDraft's opposite choice (HTML→ProseMirror→turndown round-trip)
  cost them lossiness their own ADR concedes.

## Evidence
CLAUDE.md non-negotiables; docs/reference/invariants.md #1–3; RoughDraft research
report (2026-07-14) documenting the competing architecture's losses.
