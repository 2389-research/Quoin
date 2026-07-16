# 0008 — Projection-path drift is prevented by CI equivalence, not code unification

Status: Accepted (editor-modes Phase 3 as-built, 2026-07-14).

## Context
Four projection paths (full render, activation flip, per-keystroke patch,
caret-move restyle) historically re-derived shared logic (separators, styler
config, offsets) and drifted — the root cause of the code-block rendering
overlaps. The plan's ideal was ONE projector function.

## Decision
Ship the GOAL (drift impossibility) via three mechanisms rather than a
literal merge: (1) every shared derivation is single-sourced (SeparatorPolicy,
RevealStylerConfig, presentation map); (2) both patch producers live in the
renderer beside the render loop they must match; (3) ProjectorEquivalenceTests
proves patch-vs-full byte/attribute equality across the whole fixture corpus
on every CI run. The caret-move restyle stays a synchronous view-side
attribute pass consuming the carried config (never the async model pipeline).

## Consequences
- A literal `project()` entry remains an OPTIONAL refactor with no
  correctness stake — do it if the suggestions input mode (S3) wants one
  seam to hook.
- Anyone adding a projection path must extend the equivalence corpus's
  interaction script (docs/reference/invariants.md #6).

## Evidence
docs/design/editor-modes-plan.md "Phase 3 as built"; commit e38ba5d;
ProjectorEquivalenceTests (39 flip + 30 keystroke checks at introduction).
