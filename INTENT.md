<!-- ABOUTME: Living intent file for this project - goals, constraints, taste, boundaries. -->
<!-- ABOUTME: Loaded at session start; sessions propose diffs at session end. -->

# INTENT

## Goal
A native WYSIWYG markdown editor whose defining feature — a review loop that
lives in the file as plain bytes — makes any markdown-writing tool or agent a
first-class collaborator. Ships on macOS today; a full-featured Android app is
in flight (`docs/plans/2026-07-17-android-app-design.md`). Serves people who
own their documents as files and review agent-proposed edits in a real UI.

## Constraints (blast-radius facts)
- Visibility: PUBLIC (github.com/2389-research/Quoin, MIT) — commits, docs, and
  CI artifacts are world-readable the moment they push.
- Consumers: macOS app users (Sparkle-updated releases); `QuoinCore` is
  consumed by App/macOS, the App/iOS spike, and the Android app in flight.
  MermaidKit and Vinculum are separate public repos consumed FROM GitHub —
  engine changes there need publish + tag + version bump here.
- Deploy target(s): macOS releases via notarization + Sparkle
  (`docs/reference/distribution.md`); site under `site/`. No servers.
- Shared surfaces: `CLAUDE.md`, `.github/workflows/ci.yml` (CI runs on `main`
  and `claude/**`), the 20 invariants in `docs/reference/invariants.md` —
  treat all as co-owned by humans and agents.
- Engine changes must keep the Linux CI leg and the full test suite green;
  the dependency policy (`docs/reference/dependencies.md`) defaults to no.
- Before proposing a rewrite or parallel implementation of anything
  Quoin-adjacent, verify what the existing Swift engine already provides
  (Linux CI leg, platform guards, scene-IR seams). The engine is the product;
  rebuilding it requires evidence the existing one can't reach the target
  platform.

## Reference implementation
The shipping macOS app is the behavioral reference for every port;
`docs/design/handoff.md` is the visual canon; `docs/design/platforms.md` is
the porting doctrine ("port the lens, never rebuild the document").

## Taste
- Doctrine lives in `CLAUDE.md` and README (zero JS, local-only, byte-lossless,
  files are the only truth) — INTENT.md doesn't restate it.

## NOT doing
- No sync service, no collaboration backend (files sync by syncing files).
- No Mac Catalyst; no Linux GUI toolkit port.
- No client-side JavaScript frameworks, no WebViews, anywhere.
- No RTF export on Android.

## Decision log
- 2026-07-17: Android app approved — lives in this monorepo as `App/Android` [stated]
- 2026-07-17: Android engine = real QuoinCore compiled with the Swift SDK for
  Android + synchronous swift-java facade; Rust/UniFFI rewrite rejected after
  verifying the engine is platform-free [stated]
- 2026-07-17: Android editing is block-focused (invariant 10 as mobile
  grammar); SAF-first storage with optional all-files upgrade [stated]
- 2026-07-17: Milestone 0 toolchain spike gates all Android UI work [stated]
