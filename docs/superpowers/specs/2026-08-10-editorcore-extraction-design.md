---
title: EditorCore extraction — a platform-free, Linux-testable editor engine
created: 2026-08-10
status: APPROVED (design); implementation plan to follow
related:
  - docs/superpowers/specs/2026-08-10-editing-lifecycle-first-principles-issues.md (ARCH-1)
  - docs/superpowers/plans/2026-08-10-document-lifecycle.md (Plan 1 — the lifecycle this makes testable)
  - docs/design/single-file-first.md (the Layer-0 vision)
---

# EditorCore extraction — a platform-free, Linux-testable editor engine

## Why

Clint's directive: *"MAKE this stuff testable and instrumented to the hilt — we
shouldn't need a human to try all this out."* Today none of the document/edit/
lifecycle logic is unit-testable: it lives in a 1748-line `@MainActor @Observable
final class ReaderModel` in the macOS app target, whose only test bundle is
XCUITest. `swift test` (which runs `QuoinCore` + `QuoinRender` on Linux) cannot
reach it. Every lifecycle fix this session shipped (resurrection, Save-As, trash,
emptiness) was *build-verified and hand-tested*, never automatically covered.

That untestability **is** the audit's #1 architecture root cause (ARCH-1): the
document logic is welded to the SwiftUI shell. Extracting it is therefore not
throwaway scaffolding — it is the audit's step 1 and the foundation the CARET-1
(empty-paragraph node) and keystroke-grammar plans build on. "Make it testable"
and "redo it from first principles" are the same move.

This is **sub-project ①** of a larger test-pyramid effort (② app unit-test
target, ③ behavioral XCUITest, ④ headless geometry tests, ⑤ instrumentation).
Each is its own spec → plan → execute cycle. This spec covers ① only.

## The seam

Split `ReaderModel` into two objects along the platform boundary:

- **`EditorCore` (a QuoinCore `actor`, platform-free, Linux-testable)** owns the
  document engine: the `DocumentSession` (already a QuoinCore actor), the
  lifecycle state machine (`start`/`stop`/`discard`/`flush`/`currentlyEmpty` +
  awaitable teardown — the Plan 1 work), edit application, undo/redo, conflict
  resolution, and the programmatic platform-free operations (tidy-blank-lines,
  front-matter edits, suggestion resolution, checkbox toggle). It imports no
  SwiftUI, no AppKit, no `QuoinRender`.
- **`ReaderModel` (stays a `@MainActor @Observable` adapter)** owns only the
  platform-bound half: `RenderedDocument`/`NSAttributedString`, the renderer,
  caret geometry, `restoreCaret`, activation flips, the async off-main render
  tasks, and the viewport. It holds an `EditorCore`, mirrors the core's `State`
  onto its `@Observable` properties for SwiftUI, and does the render/caret work
  after each edit.

### Deliberately NOT moved in this pass

- **Caret-mapping and edit-intent decisions.** They derive from and produce
  AppKit-typed `RenderedDocument`/`NSRange`; moving them now would drag AppKit
  into QuoinCore or force a premature abstraction. Carving a renderer-agnostic
  mapping surface is a later sub-project — and is exactly what CARET-1 needs, so
  it belongs there.
- **H1 auto-rename.** Stays in the shell, keyed on `isUncommitted` (state, not a
  filename prefix — preserving the ARCH-2 fix). It couples to `Library.rename`
  (vault policy). A later pass may inject a `FileRenamer` protocol into the core.

## `EditorCore` surface (platform-free)

```
public actor EditorCore {
    public init(source: String, fileURL: URL?, encoding: String.Encoding = .utf8)

    // Lifecycle
    func start(fileURL: URL?, initialText: String)
    func stop(save: Bool) async          // awaitable teardown (Plan 1 contract)
    func discard() async                 // teardown(save: false)
    func flush() async
    func currentlyEmpty() async -> Bool  // awaits the FIFO drain first

    // State observation (no SwiftUI/Combine)
    func getSnapshot() -> State
    func stateStream() -> AsyncStream<State>

    // Edits (default publishSnapshot:false — keystroke hot-path parity)
    func apply(edit: SourceEdit, baseRevision: Int?, actionName: UndoActionName?,
               publishSnapshot: Bool = false) async throws -> QuoinDocument
    func undo() async
    func redo() async

    // Conflict
    func resolveConflictKeepingMine() async throws
    func resolveConflictTakingDisk(_ diskSource: String) async

    // Programmatic ops (pure session work)
    func tidyBlankLines() async
    func applyFrontMatter(key: String, value: String) async
    func applyTypedFrontMatterEdit(...) async
    func applyResolution(markRange: ByteRange, expectedSlice: String?,
                         action: SuggestionResolver.Action) async
    func resolveAllSuggestions(action: SuggestionResolver.Action) async
    func toggleTask(markerRange: ByteRange) async throws
}
```

`State` — a plain platform-free `Sendable` struct mirrored by the shell:
`document: QuoinDocument`, `contentRevision: Int`, `undoState`,
`fileURL: URL?`, `hasUnsavedChanges: Bool`, `hasUnresolvedConflict: Bool`,
`conflictDiskSource: String?` (nil clears the banner), `isDetached: Bool`,
and a monotonically increasing `version: Int`.

(Exact signatures are finalized against the current `ReaderModel`/`DocumentSession`
APIs during the plan; the above is the shape, not the literal final list.)

## Notification: core → shell

`EditorCore` publishes state via `AsyncStream<State>` plus a synchronous
`getSnapshot()` for the initial mirror — the same pattern `ReaderModel` already
uses for `session.revisionedSnapshots()`. The core owns exactly one subscription
to its session's snapshot stream and republishes a derived `State`. The shell
subscribes once at start and mirrors each `State` onto its `@Observable`
properties. No callbacks (cancellation/backpressure pain), no version-polling
(racy, flaky) — the AsyncStream is already proven in this codebase.

## Isolation

`EditorCore` is an **actor** — not `@MainActor`, not a plain class. It serializes
the app-facing edit FIFO and calls into the `DocumentSession` actor, preserving
the single-pipeline ordering `ReaderModel` has today, with no main-thread
coupling so it runs in Linux unit tests. `apply(edit:)` defaults
`publishSnapshot: false` so the keystroke path stays synchronous in the shell
(the shell computes the edit, calls `apply`, gets back the new `QuoinDocument`,
and does caret/render itself) — the async echo is never reintroduced on the hot
path.

## Staging (strangler-fig — app builds and works at every commit)

Each stage is an independently committable, reviewable task.

0. **Create `EditorCore` façade in QuoinCore** owning a `DocumentSession`, with
   `start`, the `State` type, `getSnapshot()`, `stateStream()`, and conflict/
   save-failure bridging into `State`. No `ReaderModel` change yet. Ship the
   first Linux tests: construct `EditorCore(source:)`, assert `State` and basic
   session ops.
1. **`ReaderModel` reads via the core's state stream** — replace its direct
   `session.revisionedSnapshots()` subscription with `EditorCore.stateStream()`,
   feeding the existing `ingest(document:contentRevision:)`. Keep the `session`
   property temporarily.
2. **Move lifecycle ops** — `stop`/`discard`/`flush`/`currentlyEmpty` delegate to
   the core (which owns the FIFO drain + teardown). Remove the session-teardown
   logic from `ReaderModel`.
3. **Move programmatic ops** — tidy-blank-lines, front-matter, suggestion
   resolution (single + bulk), checkbox toggle delegate to core APIs. Add Linux
   tests for each, including conflict/dirty edge cases.
4. **Route absolute edits through the core** — the shell still computes the
   `SourceEdit`, caret mapping, splice hints, and rendering; it then calls
   `core.apply(edit:baseRevision:actionName:publishSnapshot:false)`, receives the
   `QuoinDocument`, and runs the existing `restoreCaret` + `rerender` path. The
   `baseRevision` stamping invariant is preserved (shell stamps, core validates).
5. **Remove `ReaderModel`'s direct `session` use** — it holds only an
   `EditorCore` handle plus platform-bound render/caret state; conflict/
   save-failure banners mirror from `State`.

## Testability — the payoff (sub-project ① exit criterion)

After stage 0, and growing through stage 5, these become `swift test` (Linux),
no GUI:

- **Lifecycle/data-integrity (retro-covers Plan 1):** discard-vs-save mutual
  exclusion; teardown never writes when discarding; `currentlyEmpty()` reflects
  pending edits after the FIFO drains; a discarded doc is never re-saved.
- **Edit pipeline:** `apply(edit:)` returns the correct new `QuoinDocument`
  (bytes + AST); `staleEditBase` rejection when the base revision moved;
  `publishSnapshot:false` vs `true` behavior.
- **Undo/redo:** ordering across edit/undo/redo; `undoState` action-name
  evolution.
- **Conflict:** save-failure and disk-conflict transitions surface in `State`.

**Exit criterion for ①:** `EditorCore` builds and tests on Linux; the lifecycle
and edit-pipeline behaviors above are covered by `swift test`; `ReaderModel` no
longer owns a `DocumentSession` directly; the app builds and every existing test
stays green.

## Risks & guards

- **FIFO/ordering regression** (edits vs undo vs resolve racing). Guard: the core
  is an actor funnelling every mutation through one serialized pipeline; Linux
  tests assert edit/undo ordering and `staleEditBase`.
- **Re-introducing the async echo on the keystroke hot path.** Guard:
  `apply(edit:)` defaults `publishSnapshot:false`; a test asserts the
  false-vs-true modes; the shell keeps its synchronous caret/render path and its
  echo-skip in `ingest`.
- **Lifecycle regression** (resurrection/duplicate/move). Guard: `stop(save:)`/
  `discard` move as awaitable ops built on the existing `teardown(save:)`; the
  Plan 1 lifecycle tests are ported to run against `EditorCore` directly.
- **State-mirror leaks / double-subscribe.** Guard: the core owns exactly one
  session subscription, cancelled on stop/deinit; the shell never touches the
  session stream after stage 1.

## Non-goals

Caret-mapping/edit-intent extraction, the empty-paragraph model node (CARET-1),
the keystroke-intent grammar, the app unit-test target (②), XCUITest (③),
headless geometry tests (④), and the instrumentation layer (⑤) are separate
sub-projects. This spec is the engine extraction that unblocks them.
