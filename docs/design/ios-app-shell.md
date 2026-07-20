---
title: iOS/iPadOS app shell — architecture proposal
status: DECIDED (2026-07-20) — see Decisions
created: 2026-07-20
---

# iOS/iPadOS app shell — architecture proposal

Quoin ships a mature macOS editor and, today, an iOS **reader**. This doc frames
the decisions needed to build a real iOS/iPadOS **editing shell**, so we settle
the architecture deliberately before writing shell code.

## Decisions (Clint, 2026-07-20)

- **A2 — custom shell**, NOT `DocumentGroup`. Keep the `WindowGroup` +
  `LibraryModel` + `WindowSessionState` model. **Constraint:** architect the
  shell so a **document-based / iCloud Drive layer can be added later without a
  rewrite** (iCloud is a *nice-to-have*, not day-one) — keep the session actor
  the source of truth, isolate the file-provenance layer behind a seam so an
  iCloud/`NSFileProviderItem` backing can slot in.
- **iPad is a FIRST-CLASS editor** at launch — hardware keyboard, multi-column,
  pointer. Not a scaled-up phone reader. This sizes Phase 2/3 up.
- **B1 — extract the shared editing view-model FIRST**, before the iOS editor
  UX. Do it behind the invariant suites; macOS stays green throughout.

The rest of this doc is the reasoning that led here, kept for context.

## Where we are

**Shared, platform-free (`QuoinCore`, builds on Linux):** the whole engine —
`DocumentSession` (open/edit/save/undo/autosave/conflict), `Library`,
`LibraryQuery`, `LibrarySeeding`, `RecentDocuments`, `NewDocumentSeed`,
`QuoinURLScheme`, `WindowSessionState`. Plus `AttributedRenderer` and the
projection in `QuoinRender` (view layers are `canImport`-guarded).

**macOS-only (`App/macOS/Sources`):** `MainWindow` (tabs, panels, restoration),
`LibraryModel` (the observable library + security-scoped bookmarks),
`ReaderModel` (the editing view-model: projection, caret/reveal orchestration,
theme, autosave wiring, held-preview state), and the `NSTextView` editor stack
in `QuoinRender/AppKit`.

**iOS today (`App/iOS`, ~555 lines total):** `IOSReaderScreen` opens ONE
`DocumentSession` and renders it read-only via `MarkdownReaderViewIOS`
(`QuoinRender/UIKit`), with a stats sheet and a share button. There is **no
library, no tabs, no editing, no navigation beyond a single file**.

**The honest gap.** CLAUDE.md states "view models are platform-free; only
navigation containers differ" — but `ReaderModel` and `LibraryModel` live in
`App/macOS`, so that principle is **aspirational, not realized**. Any iOS
editing shell forces the question of whether those view-models become shared.

## Two decisions, not one

### Decision A — the app-shell container (the ADR-0009 fork)

How does a window/scene bind to documents and restore?

- **A1 · Document-based (`DocumentGroup` / `NSDocument`-style).** Adopt Apple's
  document architecture on both platforms. Get iOS's document browser, iCloud
  Drive integration, Files.app, autosave-in-place, and version history "for
  free," plus native macOS Open Recent / restoration. **Cost:** a real
  rearchitecture of the macOS shell (today a plain `WindowGroup` with a custom
  library + tabs), and Quoin's model doesn't map cleanly — we have a
  *library-of-files* with our own tabs and a session actor that is the source of
  truth, not `NSDocument`'s in-memory model. Risk of fighting the framework.

- **A2 · Custom shell + restoration, per platform (extend today's macOS model).**
  Keep the `WindowGroup` + `LibraryModel` + `WindowSessionState` model that just
  shipped in 1.2.0, and build the iOS shell the same way: a `NavigationStack`/
  `NavigationSplitView` over `LibraryModel`, tabs-or-columns as platform
  navigation, restoration via the existing `WindowSessionState` +
  security-scoped bookmarks. **Cost:** we reimplement what `DocumentGroup` gives
  free (document browser, iCloud) ourselves, and file provider/Files.app
  integration is more manual. **Benefit:** one proven model, no macOS rewrite,
  the source-of-truth session actor stays authoritative.

ADR-0009 already chose A2 *for macOS 1.2.0 restoration* and explicitly deferred
the A1 migration. This proposal is where we decide if that holds for iOS too.

### Decision B — the editing view-model

`ReaderModel` is the editing brain (projection ↔ source, caret/reveal, autosave,
held-preview). iOS needs the same behavior.

- **B1 · Extract a shared, platform-free editing view-model.** Move the
  platform-independent core of `ReaderModel` down into `QuoinCore` (or a new
  platform-free target), leaving only the `NSTextView`/`UITextView` binding in
  the platform layers. Realizes the CLAUDE.md principle; both platforms share
  edit/caret/reveal logic and its tests. **Cost:** a careful refactor of a
  large, subtle, invariant-critical file — but guarded by the existing
  RevealFidelity/CaretLineAnchor/ProjectorEquivalence suites.

- **B2 · Parallel iOS view-model.** Write a separate `IOSReaderModel`. Faster to
  start, but duplicates the most invariant-sensitive logic in the app — exactly
  the "two recognizers for one grammar WILL diverge" hazard CLAUDE.md warns
  about. Not recommended beyond a throwaway spike.

## Recommendation

**A2 + B1**, phased:

1. **A2 (custom shell):** don't migrate to `DocumentGroup`. The session-actor-
   as-truth model is Quoin's spine and works; a document-based rewrite risks the
   byte-losslessness and conflict machinery for framework conveniences we can
   approximate. Revisit A1 only if iCloud/Files.app integration becomes a
   headline requirement.
2. **B1 (shared view-model), incrementally:** treat the iOS shell as the forcing
   function to finally make the editing view-model platform-free — the thing
   CLAUDE.md already claims. Do it behind the invariant suites, one seam at a
   time, so macOS is never destabilized.

This keeps macOS stable, avoids a framework fight, and pays down the real debt
(the aspirational-but-unrealized shared view-model) as a deliberate byproduct.

## Rough phasing (each phase ships independently, macOS stays green)

- **Phase 0 — reader parity + seams.** Make the iOS reader solid (the #2
  async-image fix already landed here) and identify the exact `ReaderModel`
  surface that is platform-free vs AppKit-bound.
- **Phase 1 — extract the shared editing core (B1).** Move projection/caret/
  reveal/autosave orchestration into a platform-free view-model; macOS
  `ReaderModel` becomes a thin `NSTextView` adapter over it. No iOS yet — this
  is pure refactor, proven by the existing suites.
- **Phase 2 — iOS editing surface.** A `UITextView`-backed editor that binds the
  shared view-model (the UIKit analogue of `QuoinTextView`), with the reveal/
  caret invariant honored on touch.
- **Phase 3 — iOS library + navigation shell (A2).** `LibraryModel` reused (or
  its platform-free core extracted), a `NavigationSplitView` library →
  document flow, restoration via `WindowSessionState`, security-scoped bookmarks.
- **Phase 4 — iOS integration.** Share sheet, Shortcuts (the App Intents from #7
  are already cross-platform-capable), Handoff receive (the macOS side from #36
  already publishes a `quoin://` activity), Quick Look is macOS-only by nature.

## Phase 1 — the `ReaderModel` extraction, grounded (B1)

A full audit of `App/macOS/Sources/ReaderModel.swift` (1646 lines) says the
refactor is **far lower-risk than feared** — the hard decoupling is already done:

- **`ReaderModel` does not `import AppKit`** and never touches `NSTextView`/
  `NSEvent`/`NSResponder`/the coordinator. The view is already inverted into ~40
  closures wired in `ReaderScreen.swift:205-281` (the editor *pushes* facts in,
  *pulls* `rendered`/`caretInActiveBlock` out).
- **Only 3 genuinely AppKit-only touch points** in the whole file: `NSSound.beep()`
  (edit rejection), `NSPasteboard` (image paste read), `NSUserName()` (reviewer
  name). Each becomes a tiny injected seam (`EditorFeedback.beep()`,
  `PasteboardImageSource`, `reviewerNameProvider`); on iOS they map to haptic/
  no-op / `UIPasteboard` / a default.
- A **divergent `IOSReaderModel`** already exists (`IOSReaderScreen.swift:112-268`,
  its own comments say "mirrors macOS ReaderModel") — the exact duplication this
  collapses.

**Target:** a new `@MainActor @Observable final class EditorViewModel` in
`Sources/QuoinRender/` (NOT QuoinCore — it needs `AttributedRenderer`/`Theme`,
which live in QuoinRender; that target already ships both AppKit and UIKit code,
so it compiles for both OSes with no Package.swift change). macOS `ReaderModel`
becomes a thin app-target adapter owning the 3 seams; the `ReaderScreen.swift`
closure surface stays byte-identical.

**Steps (macOS green at each; each lands behind an existing suite):**
1. **Characterize first, no move.** Add `QuoinRenderTests` around the pure
   helpers (`applyToLiveAttributed`, `makeActiveEditSpliceHint`, caret offset
   math) — the orchestration is currently only covered "by the app UI tests," so
   this adds the missing net before touching structure. Also relocate
   `ViewportSnapshot` (a pure data struct currently in `MarkdownReaderView.swift:57`)
   to a shared header.
2. **Introduce the 3 seams in place** (still in the app target): inject
   `feedback.beep()`, wrap the pasteboard read, parameterize `reviewerName`.
   Proves the seams compile; nothing moves yet.
3. **Move the render/session engine** (`ingest`/`rerender`/`rerenderAsync`/
   `buildAsyncRender`/`start`/`stop`/`flush` + renderer/cache/generation state)
   into `EditorViewModel`. Guarded by OffMainRenderEquivalence /
   AsyncImageRerender tests.
4. **Move the caret + edit-pipeline core** (`activateBlock`/`restoreCaret`/
   `replayPendingInsertion`/`applyAbsolute`/the edit/structure/find-replace/
   review/front-matter commands). Guarded by RevealFidelity / CaretLineAnchor /
   ProjectorEquivalence / KeystrokeReplay.
5. **Collapse iOS:** retarget `IOSReaderScreen` onto `EditorViewModel`, delete
   `IOSReaderModel`, reconcile its `ObservableObject`→`@Observable` mismatch.

Only step 1 adds new coverage; every later step is guarded by a suite that
already exists. A side benefit: the model's orchestration (edit-pipeline FIFO,
stale-base stamping, render-generation drop-guard) becomes **unit-testable** for
the first time, since it moves into a package target the tests can import.

### Progress + Step-3 execution notes (2026-07-20)

**Done and shipped:** Step 1 (`ViewportSnapshot` → shared header) and Step 2
(all three AppKit seams inverted: `EditorFeedback`, `PasteboardImageSource`,
plus the finding that `reviewerName`'s `NSUserName()` is Foundation, not a
blocker). `ReaderModel`'s entire AppKit surface is now a single 2-line
`insertPastedImage(NSPasteboard)` wrapper.

**Step 3 was attempted and reverted** — it is bigger than "move a file," and the
next attempt must plan for this:

- **Move mechanics that worked:** `git mv` to `Sources/QuoinRender/EditorViewModel.swift`,
  rename the type, drop the self-`import QuoinRender` and `import SwiftUI`
  (only a comment used it) → `import Observation`, change the `feedback` default
  to a platform-free `SilentEditorFeedback` (add it to `EditorFeedback.swift`),
  delete the macOS `insertPastedImage(NSPasteboard)` wrapper from the moved file,
  add `public init() {}`, and in the app target add
  `typealias ReaderModel = EditorViewModel` + an extension carrying the
  `NSPasteboard` wrapper, and set `model.feedback = SystemEditorFeedback()` in
  `OpenDocumentStore.acquire`. The package compiled cleanly this far.
- **The real cost:** moving to a package target means **~56 members the app
  touches must become `public`** (51 `model.<member>` + the `ActionFailure` /
  `StructureCommand` nested types). This is the bulk of the work.
- **The trap (learned the hard way):** a naive script that adds `public` to any
  `var|let|func <name>` matching a member name ALSO rewrites **local variables**
  of the same name inside method bodies (`document`, `stats`, `outline` are
  common locals), corrupting `if let` patterns ("`public` can only be used in a
  non-local scope"). **Fix:** scope the annotation to **class-level declarations
  only** — lines at exactly the class member indent (4 spaces), never 8+, and
  skip anything already `public`/inside a body. Also: `rendered` is
  `Identifiable`-adjacent — the `id`/`Identifiable` conformance forces its
  property `public` (a distinct error to expect).
- **Alternative to weigh:** rather than publicize 56 members, expose a narrower
  **facade protocol** the app's `ReaderScreen` binds to. Bigger up-front
  refactor, smaller public surface. The 56-public-member path is faster and
  matches how QuoinRender already exposes `MarkdownReaderView`'s ~40 public
  props, so it's the recommended default unless the surface feels wrong.
- **Verification net:** the package build + macOS app build + the 1117-test
  suite (RevealFidelity / CaretLineAnchor / ProjectorEquivalence /
  OffMainRenderEquivalence) fully guard a pure move — the change is mechanical
  (relocation + access levels), so no behavior can drift silently. Do it as ONE
  focused pass, not at the tail of another session.

## Open questions — answered (2026-07-20)

1. **iCloud / Files.app**: *nice-to-have*, not day-one → A2 stands; design the
   file-provenance seam so an iCloud/document-based layer can be added without a
   rewrite.
2. **iPad scope**: *first-class editor* at launch (keyboard, multi-column,
   pointer) → Phase 2/3 sized up.
3. **B1 refactor now** vs. spike: *refactor first* → the Phase-1 extraction above
   is the immediate next work.

Decision recorded in [ADR 0010](../reference/adr/0010-ios-shell-custom-not-documentgroup.md).
