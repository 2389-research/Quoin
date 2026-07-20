# 0009 — Session/window restoration around WindowGroup; NSDocument migration DEFERRED

Status: Accepted (2026-07-17, issue #15).

## Context
The handoff/TRD call for `NSDocument`-style autosave-in-place, version history,
and native restoration, and #15 asked for crash/relaunch + multi-window
restoration of open documents and unsaved sessions. The current macOS shell is a
plain SwiftUI `WindowGroup` → `MainWindow` → `LibraryModel` with open tabs held
in `@State` and one `DocumentSession` per file in the app-level
`OpenDocumentStore` (ADR 0005). Two implementation routes were on the table:

1. Migrate the shell to `DocumentGroup`/`NSDocument` — buys native window tabs,
   Open Recent, restoration, and autosave-in-place "for free".
2. Implement equivalent restoration *around* the existing WindowGroup model.

## Decision
Take route 2. Implement restoration around the current
`WindowGroup`/`MainWindow`/`LibraryModel` model; **the `NSDocument` migration is
intentionally DEFERRED**, not rejected.

Reasons the document-based rearchitecture is out of scope here:
- It is a *shell rewrite*, not a feature: `OpenDocumentStore` (one session per
  file, ref-counted across windows AND tabs — the ledger-#12 dual-autosaver
  fix) and Quoin's own document-tab bar (ADR 0005) already deliver the behaviors
  a `DocumentGroup` would, and an `NSDocument` stack would re-open both of those
  settled decisions.
- The same choice **governs the future iOS/iPadOS shell** (a `DocumentGroup`
  shared across platforms), so it deserves its own deliberate decision rather
  than being made as a side effect of a restoration ticket.
- Restoration does not need it: SwiftUI scene state (`@SceneStorage`) already
  survives relaunch, and the security-scoped-bookmark path (#61) already reopens
  the library safely.

## Consequences
- Per-window session state (open tabs, active tab, sidebar/inspector visibility
  + mode, scroll anchor) is serialized into a single `@SceneStorage`
  (`QuoinWindowSession`) blob. The pure, testable core — the `Codable`
  `WindowSessionState` model, its serialize/deserialize/prune/dedupe, and the
  `SessionRouting` route-to-existing decision — lives in `QuoinCore`
  (`WindowSessionState.swift`, `WindowSessionStateTests`), keeping the
  AppKit/SwiftUI wiring thin.
- The blob carries only **library-root-relative** handles (via
  `QuoinURLScheme.relativePath`) — NEVER an absolute path or a raw
  security-scoped bookmark. The library bookmark stays in the per-folder
  bookmark store keyed by the window root (#61); restore re-resolves each handle
  through the same lexical confinement a `quoin://` link uses.
- Dirty-document crash safety leans on the existing machinery: 400ms-debounced
  autosave-in-place, the `applicationShouldTerminate` flush of every live
  session, atomic `saveNow`, and the file-coordination reload/merge banner — no
  new autosave journal. See architecture.md → "Window & session restoration".
- If/when the `NSDocument` migration happens, `WindowSessionState` and the
  restoration contract documented here are the behavior it must preserve.

## Evidence
Issue #15; ADR 0005 (sessions in an app-level store); #61 (multi-folder windows,
per-window root bookmarks); `WindowSessionStateTests` (round-trip, prune,
no-absolute-path-leak, dedupe).
