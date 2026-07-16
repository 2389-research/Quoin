# Road to 1.0 and public release

Status: PLAN (2026-07-15). The single sequencing document for everything
between here and a public 1.0. Each item links to its ledger task. Two
release events are tracked separately because they have different bars:
**PUBLIC** (repo goes visible) and **1.0** (a version people depend on).

## The two bars

- **PUBLIC** is hygiene + a decision. The engineering already reflects well
  publicly; what's missing is legal/hygiene, not capability.
- **1.0** is *earned trust in byte-safety*, proven by real use — not more
  features. The feature surface is already 1.0-shaped.

## Phase A — Unblock PUBLIC (small, do first)

The gate is mostly one decision.

- **A1. License decision + LICENSE file.** Choose the posture first:
  source-available ("here's the work", restrictive, no contributions) vs.
  open (MIT/Apache, contributions welcome). This decision shapes A3/A4.
  *Owner: Clint (the decision); me (the file + headers).*
- **A2. Git-history secrets scrub.** Verify no keys/tokens/private paths in
  history; confirm fixtures carry no real ClintNotes content.
- **A3. README + docs honesty pass** — the docs overhaul (Phase B) IS this,
  plus a support-matrix-vs-reality diff so nothing claims what it can't do.
- **A4. CONTRIBUTING + issue templates** — only if A1 is "open."

## Phase B — Documentation overhaul (DONE 2026-07-15)

The docs must be ALL about Quoin, feature-current, screenshot-current, and
must defer engine depth to the engine repos.

- **B1. README rewrite** — the review/commenting loop front and center
  (it's the differentiator), every supported feature, the support matrix
  audited against reality. Diagram/math depth links out to
  MermaidKit/Vinculum instead of restating.
- **B2. Engine-doc deferral** — slim `diagram-gallery.md`,
  `diagram-engine-handoff.md`, `math-extraction.md`, and the rendering
  ledgers to Quoin-relevant stubs that point at the engine repos (whose
  own PRODUCT/COVERAGE docs are the source of truth). Update the docs index.
- **B3. Screenshot automation** — extend `-QuoinShotState` + the CI
  screenshot job to capture the NEW surfaces (review panel, comment
  creation, Review Mode, Properties, footnotes, code themes) so images stay
  current *on every push*, not hand-captured once. A screenshot manifest
  (`docs/guide/screenshots.md`) records every shot + its launch args.
- **B4. Feature/capability doc + claim audit** — a features doc covering
  review/commenting/properties/footnotes/themes; audit PRODUCT.md and
  architecture.md claims against the code, report any drift.

## Phase C — Feature gaps that a 1.0 shouldn't ship without

- **C1. Find & Replace (#85)** — Find exists; Replace does not. Table stakes.
- **C2. Formatting toolbar honesty (#86)** — the B/I/edit/link icons read as
  dead; verify wiring, give honest enabled/disabled state, expand actions.
- **C3. Accessibility baseline** — VoiceOver on the core read + review flows
  (currently thin; a public-1.0 table stake). *File as a task.*
- **C4. First-run for a stranger** — onboarding a non-Clint user.

## Phase D — Distribution infrastructure (#87)

The prerequisite chain for shipping updates to real users. Design doc
(`docs/design/distribution.md`) before code.

- **D1. Apple Developer ID + notarization** — the app is ad-hoc signed
  today; a paid account + Developer ID cert + notarization is the
  precondition for everything below. *Owner: Clint (account).*
- **D2. Sparkle integration** — framework (distribution dep, not the
  one-code-dep policy; justify in TRD), EdDSA keys (private key OUT of repo),
  "Check for Updates" UI + release notes.
- **D3. Release pipeline** — build → notarize → sign appcast → publish
  (GitHub Releases). Replaces the current stamped-zip flow for public builds.

## Phase E — Swift 6 language mode (deliberate, safety-netted)

Nothing fundamental blocks it: toolchain is 6.2, both engines are already
Swift 6.0. A measured build surfaced ~48 hard errors in the packages,
concentrated, plus an app-target surface dominated by `ReaderCoordinator`.
Staged to protect the hard-won caret/viewport stability:

- **E1. QuoinCore — DONE (6f69822).** Tools bumped to 6.0; QuoinCore in
  Swift 6 language mode (only `CriticScanner.openers` needed @Sendable +
  nonisolated(unsafe)). QuoinRender + its tests stay Swift 5 mode under the
  6.0 toolchain until E2/E3.
- **E2. QuoinRender** — `@MainActor`-annotate the three AppKit files
  (ReaderCoordinator, FlipTransitionController, AttributedRenderer);
  the invariant suites are the regression net.
- **E3. App target** — LAST, behind the ReaderModel characterization tests
  (#83), because its concurrency IS the settle/pin machinery.
- File as a staged task.

## Phase F — Platform expansion (post-1.0, gated by the dogfood experiment)

Per `docs/design/platforms.md` (five-squad-debated). Not on the 1.0 path.

- **F0. Phase 0 (#83)** — Linux CI + the byWords/CGVector fixes (byWords is
  already fixed locally; CGVector is upstream MermaidKit#2) + ReaderModel
  characterization tests. This is shared substrate: it unblocks E3 AND the
  CLI AND any Linux claim.
- **F1. `quoin` CLI** — the agent-handoff story end-to-end; ships with the
  cross-process write contract + a Claude Code skill.
- **F2. Dogfood gate → phone** — the CLI feeds marks into the synced
  library; if Clint reaches for his phone to triage, R1 starts.
- **F3. Silica spike (#84)** / SVG writers — Linux raster.

## Phase G — The 1.0 gate itself (calendar, not code)

The one bar that can't be rushed:

- **G1. #60 resolved or definitively disproven** — an open list-collapse
  bug can't coexist with a byte-safety 1.0. Needs Clint's verdict on a
  recent build (headless repros pass; two plausible causes fixed since).
- **G2. Real dogfooding** — Clint runs it daily on the actual ClintNotes
  library for weeks with zero corruption. Every test is a proxy for this;
  the adversarial review proved synthetic testing has a ceiling.
- **G3. Stability stretch** — no known crashers; clean forensics.
- Then tag 1.0.

## Upstream (parallel, not gating)

- **MermaidKit#1** — flowchart cycle back-edge (#82). Visible quality wart
  in a headline feature; fix before 1.0, pin-bump.
- **MermaidKit#2** — Linux CGVector (unblocks F0).
- **Vinculum#1** — display-math scanner (Quoin-side fix already shipped;
  upstream may close).

## Critical path to PUBLIC

~~B (docs) — DONE.~~ A1 (license decision) → A2 (secrets) → flip
visibility. The docs are current, the tree is reorganized, and the
support matrix is audited; only the license decision + a secrets scrub
remain, both small.

## Critical path to 1.0

C1/C2 (Find&Replace, toolbar) + G1 (#60 verdict) + G2 (weeks of dogfooding)
→ stability → tag. Distribution (D) and Swift 6 (E) are strongly
recommended for a *public* 1.0 but can trail a soft 1.0 if needed.
