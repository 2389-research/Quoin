# 0006 — The flip transition is cosmetic by construction

Status: Accepted.

## Context
Activate/deactivate flips (rendered ↔ source) change block height abruptly.
Animating REAL layout would put an animation system in the projection's
critical path and make geometry a moving target.

## Decision
Real layout applies instantly (splice → pin → settle). The animation is a
snapshot OVERLAY: pixels frozen before the splice, faded/slid over the
settled truth, transparent to hit-testing, cancelled by any input or newer
projection, force-removed by a 500ms watchdog. Slices are NSImageView on
CGImage crops (raster-space, upright in any hierarchy) — never manual
layer.contents, whose orientation lies differently in different trees.

## Consequences
- The flip can never corrupt geometry — worst case is a stale-looking fade.
- Snapshot pixel tests need an on-screen orientation anchor and must never
  drain the runloop mid-measurement (see ADR-0007).

## Evidence
FlipTransitionController header comment; FlipTransitionFidelityTests;
memory: snapshot-pixel-orientation-needs-onscreen-anchor.
