# 0003 — Math and diagrams are first-party packages consumed from GitHub

Status: Accepted (MermaidKit extracted 2026-07; Vinculum 2026-07).

## Context
The math and diagram engines grew large enough to be products in themselves,
and vendoring them in-repo made their test suites drag Quoin CI while hiding
them from other potential hosts.

## Decision
MermaidKit (github.com/2389-research/MermaidKit) and Vinculum
(github.com/2389-research/Vinculum) are Quoin-owned published packages,
consumed from GitHub like any host would (`from:` pins). Each is
layout/render split (platform-free geometry behind a theme seam). They are
exempt from the one-third-party-dependency policy; engine changes are tested
by THEIR CI, not Quoin's. Docs defer to their repos for feature matrices.

## Consequences
- Co-development uses a local path override or `swift package edit`, then
  publish → tag → bump (never commit the path override).
- Quoin docs must not duplicate engine capability lists (they drift — the
  23-vs-30 diagram-count regression of 2026-07-13 happened exactly this way).

## Evidence
CLAUDE.md Layout section; Package.swift pins; the 2026-07-14 docs audit
(count-drift theme).
