# EditorCore Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract a platform-free, Linux-testable `EditorCore` actor from the 1748-line `@MainActor @Observable ReaderModel`, so the document/edit/lifecycle logic is covered by `swift test` instead of hand-testing — and `ReaderModel` becomes a thin adapter that mirrors the core's state and does only rendering/caret work.

**Architecture:** `EditorCore` (QuoinCore `actor`) owns the `DocumentSession`, lifecycle, edit application, undo/redo, conflict, and programmatic ops; it publishes an `AsyncStream<State>` + `getSnapshot()` (no SwiftUI/Combine). `ReaderModel` holds an `EditorCore`, mirrors `State` onto its `@Observable` properties, and keeps `RenderedDocument`/caret geometry/rendering. Built strangler-fig: the core is created and fully Linux-tested first (additive, no app change), then the shell is wired to it stage by stage.

**Tech Stack:** Swift 6 strict concurrency, Swift actors, swift-markdown/cmark, XCTest; QuoinCore builds/tests on Linux. macOS app target (SwiftUI + AppKit).

**Source spec:** `docs/superpowers/specs/2026-08-10-editorcore-extraction-design.md` — read it before starting. This is sub-project ① of the test-pyramid effort (ARCH-1). It does NOT touch caret/viewport (CARET-1 is a later plan).

## Global Constraints

- **Source of truth is the in-memory markdown string + AST** (owned by `DocumentSession`, an existing QuoinCore actor). `EditorCore` never reads disk for a decision on the hot path.
- **QuoinCore is Swift 6 strict-concurrency and MUST build/test on Linux** — `EditorCore` and `State` import no SwiftUI, no AppKit, no `QuoinRender`; all types are `Sendable`.
- **The keystroke hot path must not regain the async echo:** `EditorCore.apply(edit:)` defaults `publishSnapshot: false`; the shell computes the edit, calls `apply`, gets the new `QuoinDocument`, and renders synchronously (its existing path).
- **Single serialized edit FIFO / one-writer:** every mutation funnels through the `EditorCore` actor into the `DocumentSession` actor. Ordering (edit vs undo vs resolve) and `staleEditBase` rejection are preserved.
- **Discard/flush mutual exclusion + awaitable teardown** (Plan 1 invariant #19) is preserved: `EditorCore.stop(save:)`/`discard()` build on `DocumentSession.teardown(save:)`.
- **The app builds and every existing test stays green at every task.** Strangler-fig: the core is additive until the shell is wired.
- **No new dependencies.**
- Package tests: `swift test`. App build: `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build`. Revert incidental `Package.resolved` churn (`git checkout Package.resolved`) before each commit.
- Commit after each task and **push to `main`** (user directive).

---

## Real APIs this plan builds on (verified)

`DocumentSession` (QuoinCore `actor`) already provides:
- `init(source: String, fileURL: URL? = nil, encoding:)`, `static func open(fileURL:) throws -> DocumentSession`
- `var contentRevision: Int`, `var hasUnsavedChanges: Bool`, `var isDetached: Bool`, `var hasUnresolvedConflict: Bool`, `var undoState: UndoState` (`Sendable, Equatable`)
- `func revisionedSnapshots() -> AsyncStream<RevisionedSnapshot>` (`RevisionedSnapshot { document, contentRevision }`)
- `func setConflictHandler(_ @escaping @Sendable (String)->Void)`, `func setSaveFailureHandler(_ @escaping @Sendable (String)->Void)`
- `func startWatching()`, `func stopWatching()`, `func teardown(save: Bool) async`, `func saveNow() throws`, `func flush()`-equivalent via teardown, `func relocate(to:)`, `func reloadFromDisk()`
- `func applyEdit(_ SourceEdit, baseRevision: Int? = nil, publishSnapshot: Bool = true, actionName: UndoActionName? = nil) throws -> QuoinDocument` (throws `SessionError.staleEditBase` on base mismatch)
- `func undo() throws -> QuoinDocument?`, `func redo() throws -> QuoinDocument?`
- `func resolveConflictKeepingMine() throws`, `func resolveConflictTakingDisk(_:)`
- `func applyResolution(...)`, `func applyBulkResolution(...)`, `func applyTidyBlankLines(publishSnapshot:) throws -> QuoinDocument?`, `func applyFrontMatterEdit(...)`, `func applyTypedFrontMatterEdit(...)`, `func removeFrontMatterField(...)`, `func appendText(_:publishSnapshot:) throws -> QuoinDocument?`, `func toggleTask(markerRange:) throws`

`ReaderModel` today subscribes in `start()` (App/macOS/Sources/ReaderModel.swift ~207-231): sets conflict/save-failure handlers, `startWatching()`, then `for await snapshot in session.revisionedSnapshots() { ingest(snapshot.document, contentRevision:) }`. Lifecycle: `stop()`/`discard()`/`flush()`/`currentlyEmpty()` (~300-341). Edits: `applyAbsolute` → `session.applyEdit(..., publishSnapshot:false)` then `restoreCaret` + `rerender` (~1298-1340).

---

## File Structure

**Created:**
- `Sources/QuoinCore/EditorCore.swift` — the actor + `State`.
- `Tests/QuoinCoreTests/EditorCoreTests.swift` — state/observation/edit-pipeline/undo/conflict.
- `Tests/QuoinCoreTests/EditorCoreLifecycleTests.swift` — the Plan-1 lifecycle behaviors, now against `EditorCore` directly.

**Modified (stages 1-5, one task each):**
- `App/macOS/Sources/ReaderModel.swift` — subscribe to core stream; delegate lifecycle, programmatic ops, and edit application to the core; finally drop the direct `session`.

---

## Task 1: `EditorCore` actor — state, observation, session ownership (Stage 0)

**Files:**
- Create: `Sources/QuoinCore/EditorCore.swift`
- Test: `Tests/QuoinCoreTests/EditorCoreTests.swift`

**Interfaces:**
- Consumes: `DocumentSession` (QuoinCore).
- Produces: `EditorCore` actor with `init(source:fileURL:encoding:)`, `func getSnapshot() -> State`, `func stateStream() -> AsyncStream<State>`, `func start() async`, and `EditorCore.State` (`Sendable`). Later tasks add lifecycle/edit/ops methods.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuoinCore

final class EditorCoreTests: XCTestCase {

    func testInitialSnapshotReflectsSource() async {
        let core = EditorCore(source: "# Hi\n\nbody", fileURL: nil)
        let s = await core.getSnapshot()
        XCTAssertEqual(s.document.source, "# Hi\n\nbody")
        XCTAssertFalse(s.hasUnsavedChanges)
        XCTAssertFalse(s.hasUnresolvedConflict)
        XCTAssertNil(s.fileURL)
    }

    func testStateStreamEmitsAfterAnEdit() async throws {
        let core = EditorCore(source: "a", fileURL: nil)
        await core.start()
        var iterator = await core.stateStream().makeAsyncIterator()
        // The stream yields the current state first (initial mirror).
        let first = await iterator.next()
        XCTAssertEqual(first?.document.source, "a")
        _ = try await core.apply(edit: SourceEdit(range: ByteRange(offset: 1, length: 0),
                                                  replacement: "b"), baseRevision: nil,
                                 actionName: nil, publishSnapshot: true)
        let next = await iterator.next()
        XCTAssertEqual(next?.document.source, "ab")
        XCTAssertGreaterThan(next!.version, first!.version)
    }
}
```

Note: if `SourceEdit`/`ByteRange` initializers differ, use the real ones (grep `struct SourceEdit` / `struct ByteRange` in QuoinCore). `apply` is added in Task 2 — for Task 1, keep only `testInitialSnapshotReflectsSource` and `testStateStreamEmitsInitialState` (assert the stream yields the initial state); move the edit assertion to Task 2.

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter EditorCoreTests`
Expected: FAIL — `cannot find 'EditorCore' in scope`.

- [ ] **Step 3: Implement the actor scaffold**

```swift
import Foundation

/// The platform-free editor engine for ONE document. Owns the DocumentSession,
/// serializes edits/lifecycle, and publishes a Sendable State snapshot. No
/// SwiftUI/AppKit/QuoinRender — Linux-testable. The @MainActor @Observable
/// ReaderModel is a thin adapter that mirrors this State and does rendering.
public actor EditorCore {

    public struct State: Sendable, Equatable {
        public var document: QuoinDocument
        public var contentRevision: Int
        public var undoState: DocumentSession.UndoState
        public var fileURL: URL?
        public var hasUnsavedChanges: Bool
        public var hasUnresolvedConflict: Bool
        public var conflictDiskSource: String?
        public var isDetached: Bool
        /// Monotonic; bumps on every published State so mirrors never miss one.
        public var version: Int
    }

    private let session: DocumentSession
    private var version = 0
    private var conflictDiskSource: String?
    private var continuations: [UUID: AsyncStream<State>.Continuation] = [:]
    private var pump: Task<Void, Never>?

    public init(source: String, fileURL: URL? = nil, encoding: String.Encoding = .utf8) {
        self.session = DocumentSession(source: source, fileURL: fileURL, encoding: encoding)
    }

    /// Convenience for opening from disk (mirrors DocumentSession.open); nil-safe.
    public static func open(fileURL: URL) -> EditorCore? {
        guard let s = try? DocumentSession.open(fileURL: fileURL) else { return nil }
        return EditorCore(adopting: s)
    }
    private init(adopting session: DocumentSession) { self.session = session }

    /// Begin bridging conflict/save-failure and the session snapshot stream into
    /// State. Idempotent.
    public func start() async {
        guard pump == nil else { return }
        await session.setConflictHandler { [weak self] disk in
            Task { await self?.setConflict(disk) }
        }
        await session.setSaveFailureHandler { _ in }   // surfaced via State.isDetached / a later lastSaveError
        await session.startWatching()
        let stream = await session.revisionedSnapshots()
        pump = Task { [weak self] in
            for await snap in stream {
                await self?.ingest(snap)
            }
        }
        await publish()
    }

    public func getSnapshot() -> State { snapshot() }

    public func stateStream() -> AsyncStream<State> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(snapshot())   // initial mirror
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    // MARK: private
    private func removeContinuation(_ id: UUID) { continuations[id] = nil }
    private func setConflict(_ disk: String?) { conflictDiskSource = disk; publishSync() }
    private func ingest(_ snap: DocumentSession.RevisionedSnapshot) async { await publish() }

    private func snapshot() -> State {
        // NOTE: reads from `session` require await; snapshot() is used where we
        // already have the values. See publish() which gathers them.
        currentState
    }
    private var currentState = State(
        document: .empty, contentRevision: 0, undoState: .init(undoActionName: nil, redoActionName: nil),
        fileURL: nil, hasUnsavedChanges: false, hasUnresolvedConflict: false,
        conflictDiskSource: nil, isDetached: false, version: 0)

    private func publish() async {
        version += 1
        currentState = State(
            document: await session.document,
            contentRevision: await session.contentRevision,
            undoState: await session.undoState,
            fileURL: await session.fileURL,
            hasUnsavedChanges: await session.hasUnsavedChanges,
            hasUnresolvedConflict: await session.hasUnresolvedConflict,
            conflictDiskSource: conflictDiskSource,
            isDetached: await session.isDetached,
            version: version)
        for c in continuations.values { c.yield(currentState) }
    }
    private func publishSync() { Task { await publish() } }
}
```

Note on `session.documentValue`/`fileURL`: `DocumentSession` exposes `document` and `fileURL`; if the property names differ, use the real accessors (grep). If `document` is not public, add a `public var document: QuoinDocument` getter to `DocumentSession` (it already publishes documents via snapshots, so a read accessor is in-keeping). Keep `currentState`/`snapshot()` in sync — the implementer may simplify to always compute `publish()` and have `getSnapshot()` return `currentState` (initialize `currentState` in `init` from the passed source rather than `.empty`).

- [ ] **Step 4: Run the tests**

Run: `swift test --filter EditorCoreTests`
Expected: PASS (initial-snapshot + initial-stream tests).

- [ ] **Step 5: Full suite (additive — nothing else changes)**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinCore/EditorCore.swift Tests/QuoinCoreTests/EditorCoreTests.swift
git commit -m "EditorCore actor scaffold: State + AsyncStream observation + session ownership"
git push origin main
```

---

## Task 2: `EditorCore` lifecycle + edit pipeline + programmatic ops, fully Linux-tested (Stage 0 cont.)

This task is the **testability payoff**: it adds the whole engine surface and covers the behaviors we have only ever hand-tested. All additive — no app change.

**Files:**
- Modify: `Sources/QuoinCore/EditorCore.swift`
- Test: `Tests/QuoinCoreTests/EditorCoreTests.swift` (extend), `Tests/QuoinCoreTests/EditorCoreLifecycleTests.swift` (create)

**Interfaces:**
- Produces on `EditorCore`: `stop(save:) async`, `discard() async`, `flush() async`, `currentlyEmpty() async -> Bool`, `apply(edit:baseRevision:actionName:publishSnapshot:) async throws -> QuoinDocument`, `undo() async -> QuoinDocument?`, `redo() async -> QuoinDocument?`, `resolveConflictKeepingMine() async throws`, `resolveConflictTakingDisk(_:) async`, `tidyBlankLines() async`, `applyResolution(...) async`, `resolveAllSuggestions(action:) async`, front-matter ops, `toggleTask(markerRange:) async throws`. Each delegates to `DocumentSession` and calls `publish()`.

- [ ] **Step 1: Write the failing tests**

```swift
// EditorCoreLifecycleTests.swift
import XCTest
@testable import QuoinCore

/// The Plan-1 lifecycle invariants, now covered against EditorCore directly
/// (previously only hand-tested through the GUI).
final class EditorCoreLifecycleTests: XCTestCase {

    private func tempURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editorcore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Untitled.md")
        try Data("".utf8).write(to: url)
        return url
    }

    func testCurrentlyEmptyIsPipelineInclusive() async throws {
        let core = EditorCore(source: "", fileURL: nil)
        await core.start()
        _ = try await core.apply(edit: SourceEdit(range: ByteRange(offset: 0, length: 0),
                                                  replacement: "x"), baseRevision: nil,
                                 actionName: nil, publishSnapshot: false)
        let empty = await core.currentlyEmpty()
        XCTAssertFalse(empty, "content typed via the pipeline must be seen")
    }

    func testDiscardDoesNotWriteAfterFileRemoved() async throws {
        let url = try tempURL()
        let core = EditorCore(adoptingForTest: DocumentSession(source: "", fileURL: url))
        await core.start()
        _ = try await core.apply(edit: SourceEdit(range: ByteRange(offset: 0, length: 0),
                                                  replacement: "typed"), baseRevision: nil,
                                 actionName: nil, publishSnapshot: false)
        try FileManager.default.removeItem(at: url)
        await core.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "discard must never resurrect the removed file")
    }

    func testStaleEditBaseRejected() async throws {
        let core = EditorCore(source: "abc", fileURL: nil)
        await core.start()
        let base = await core.getSnapshot().contentRevision
        // Force a revision bump out of band, then apply against the old base.
        await core.reloadForTest(source: "abcd")   // bumps contentRevision
        do {
            _ = try await core.apply(edit: SourceEdit(range: ByteRange(offset: 3, length: 0),
                                                      replacement: "z"), baseRevision: base,
                                     actionName: nil, publishSnapshot: false)
            XCTFail("expected staleEditBase")
        } catch SessionError.staleEditBase { /* ok */ }
    }

    func testUndoRedoOrdering() async throws {
        let core = EditorCore(source: "abc\n", fileURL: nil)
        await core.start()
        _ = try await core.apply(edit: SourceEdit(range: ByteRange(offset: 3, length: 0),
                                                  replacement: "d"), baseRevision: nil,
                                 actionName: .append, publishSnapshot: false)
        XCTAssertEqual(await core.getSnapshot().document.source, "abcd\n")
        let undone = await core.undo()
        XCTAssertEqual(undone?.source, "abc\n")
        let redone = await core.redo()
        XCTAssertEqual(redone?.source, "abcd\n")
    }
}
```

Add small `@testable`-only test seams to `EditorCore` if needed: `init(adoptingForTest:)` wrapping the private adopting init, and `reloadForTest(source:)` calling `session.apply(source:)` then `publish()`. Prefer real public paths where they exist.

- [ ] **Step 2: Run and watch fail**

Run: `swift test --filter EditorCore`
Expected: FAIL — missing `apply`/`discard`/`currentlyEmpty`/`undo`/`redo` (and the test seams).

- [ ] **Step 3: Implement the surface**

Add to `EditorCore`, each method delegating to `session` and then `await publish()`:

```swift
    public func stop(save: Bool) async {
        pump?.cancel(); pump = nil
        await session.teardown(save: save)
    }
    public func discard() async { await stop(save: false) }
    public func flush() async { try? await session.saveNow(); await publish() }
    public func currentlyEmpty() async -> Bool {
        // The DocumentSession is the FIFO; because apply() is awaited by callers,
        // a read here reflects all applied edits. Emptiness is whitespace-only source.
        (await session.document).source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    @discardableResult
    public func apply(edit: SourceEdit, baseRevision: Int?, actionName: UndoActionName?,
                      publishSnapshot: Bool = false) async throws -> QuoinDocument {
        let doc = try await session.applyEdit(edit, baseRevision: baseRevision,
                                              publishSnapshot: publishSnapshot, actionName: actionName)
        await publish()
        return doc
    }
    public func undo() async -> QuoinDocument? { let d = try? await session.undo(); await publish(); return d }
    public func redo() async -> QuoinDocument? { let d = try? await session.redo(); await publish(); return d }
    public func resolveConflictKeepingMine() async throws { try await session.resolveConflictKeepingMine(); conflictDiskSource = nil; await publish() }
    public func resolveConflictTakingDisk(_ disk: String) async { await session.resolveConflictTakingDisk(disk); conflictDiskSource = nil; await publish() }
    public func tidyBlankLines() async { _ = try? await session.applyTidyBlankLines(); await publish() }
    public func toggleTask(markerRange: ByteRange) async throws { try await session.toggleTask(markerRange: markerRange); await publish() }
    // front-matter + suggestion resolution: one thin delegator each, then publish()
```

Because `apply(edit:)` defaults `publishSnapshot:false`, the shell's synchronous caret/render path is preserved; `EditorCore.apply` still calls `publish()` so `State` mirrors advance for observers that want them (the shell's keystroke path uses the returned `QuoinDocument` directly and its `ingest` echo-skip drops the duplicate — no double render).

If `DocumentSession` lacks a public `document` getter or a non-throwing save entry, add minimal public accessors to `DocumentSession` in this task (`public var document`), keeping it Linux-safe.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter EditorCore`
Expected: PASS (all EditorCore + EditorCoreLifecycle tests).

- [ ] **Step 5: Full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinCore/EditorCore.swift Sources/QuoinCore/DocumentSession.swift Tests/QuoinCoreTests/EditorCore*.swift
git commit -m "EditorCore: lifecycle + edit pipeline + ops, Linux-tested (retro-covers Plan 1)"
git push origin main
```

---

## Task 3: `ReaderModel` reads via `EditorCore.stateStream()` (Stage 1)

**Files:** Modify `App/macOS/Sources/ReaderModel.swift` (`start()` ~176-231).

**Interfaces:** Consumes `EditorCore.start()`/`stateStream()`/`State`. `ReaderModel` gains `private var core: EditorCore`.

- [ ] **Step 1: Wire the core (build-verified — app target has no unit bundle)**

In `start()`, construct an `EditorCore` from the same source/URL logic currently used to build the `DocumentSession` (the open/detached/blank branches at ~184-199 — build the `EditorCore` the same way; `EditorCore.open(fileURL:)` for the openable case, `EditorCore(source:fileURL:)` otherwise). Keep the existing `session` property FOR NOW (stages 2-4 remove its uses). Replace the snapshot subscription block (~207-231) with:

```swift
        core = editorCore
        Self.registerLiveSession(session)   // unchanged for now
        snapshotTask = Task { [weak self] in
            await editorCore.start()
            for await state in await editorCore.stateStream() {
                guard let self else { break }
                self.fileURL = state.fileURL ?? self.fileURL
                self.conflictDiskSource = state.conflictDiskSource
                self.ingest(state.document, contentRevision: state.contentRevision)
                self.refreshUndoStateFrom(state.undoState)   // mirror undo/redo names
            }
        }
```

Add a small `refreshUndoStateFrom(_:)` that sets `undoActionName`/`redoActionName` from `state.undoState`. The conflict/save-failure handlers previously set on the session move into `EditorCore.start()` (Task 1 already bridges them into `State`), so delete the `setConflictHandler`/`setSaveFailureHandler` calls here. Leave `startWatching()` to the core (it calls it).

- [ ] **Step 2: Build the app**

Run: `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build`
Expected: BUILD SUCCEEDED. Fix isolation/await errors.

- [ ] **Step 3: Full suite + commit**

Run: `swift test`. Then:
```bash
git checkout Package.resolved 2>/dev/null || true
git add App/macOS/Sources/ReaderModel.swift
git commit -m "ReaderModel reads document/undo/conflict state via EditorCore.stateStream"
git push origin main
```

---

## Task 4: `ReaderModel` lifecycle delegates to `EditorCore` (Stage 2)

**Files:** Modify `App/macOS/Sources/ReaderModel.swift` (`stop`/`discard`/`flush`/`currentlyEmpty` ~300-341).

- [ ] **Step 1: Delegate (build-verified)**

Replace the bodies so they call the core (keeping `cancelBackgroundWork()` for the shell's own render tasks):

```swift
    func stop() async { cancelBackgroundWork(); await core.stop(save: true) }
    func discard() async { cancelBackgroundWork(); await core.discard() }
    func flush() async { await core.flush() }
    func currentlyEmpty() async -> Bool { await core.currentlyEmpty() }
```

Remove the now-dead `editPipelineTask` drain + `session.teardown` from these bodies (the core owns the FIFO/teardown). Keep `isEffectivelyEmpty` (the synchronous property `persistSession` uses) reading `document`.

- [ ] **Step 2: Build + full suite + commit**

Run the app build and `swift test`.
```bash
git checkout Package.resolved 2>/dev/null || true
git add App/macOS/Sources/ReaderModel.swift
git commit -m "ReaderModel lifecycle (stop/discard/flush/currentlyEmpty) delegates to EditorCore"
git push origin main
```

---

## Task 5: `ReaderModel` programmatic ops delegate to `EditorCore` (Stage 3)

**Files:** Modify `App/macOS/Sources/ReaderModel.swift` (tidy/front-matter/suggestion-resolution/checkbox sites).

- [ ] **Step 1: Delegate each programmatic op to the core**

Route `resolveAllSuggestions`, `tidyBlankLines`, front-matter edits, single/bulk suggestion resolution, and the checkbox `toggleTask` wrapper through the corresponding `EditorCore` methods instead of the direct `session`/`applySessionResolution` calls. Each was already computed in-actor on `DocumentSession`; the core just forwards. The shell keeps whatever caret/flash bookkeeping it does after the op (the op returns via the `State` stream / returned document).

- [ ] **Step 2: Build + full suite + commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add App/macOS/Sources/ReaderModel.swift
git commit -m "ReaderModel programmatic ops (tidy/front-matter/resolution/checkbox) delegate to EditorCore"
git push origin main
```

---

## Task 6: Route absolute edits through `EditorCore.apply` (Stage 4) — the hot path

**Files:** Modify `App/macOS/Sources/ReaderModel.swift` (`applyAbsolute`/`applyEdit` ~694-739, ~1298-1340).

- [ ] **Step 1: Route the edit, keep caret/render in the shell**

The shell still computes the `SourceEdit`, caret mapping, and splice hint. Replace the direct `session.applyEdit(..., publishSnapshot:false)` call with `try await core.apply(edit: edit, baseRevision: baseRevision, actionName: actionName, publishSnapshot: false)`, then run the existing `restoreCaret(...)` + `rerender(...)` path on the returned `QuoinDocument`. Preserve the `baseRevision` stamping (shell stamps `sessionContentRevision`; core forwards to the session which validates). The `State`-stream echo of this edit must be dropped by the existing `ingest` echo-skip (content+reveal unchanged) so there is no double render — verify that guard still fires for a same-revision echo.

- [ ] **Step 2: Build the app**

Run the app build.
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Verify the hot path in the app (REQUIRED)**

Launch the debug build; type a burst of characters and a paste. Confirm: no per-keystroke lag/echo-wedge; undo/redo work; a mid-document edit renders once (no double flash). Per CLAUDE.md, drive with a real keyboard for the burst; if you cannot drive the GUI, say so and give exact human steps — do not claim verification you didn't do. (This is the one task whose risk is the keystroke path; the Linux tests from Task 2 cover the edit-pipeline correctness, but latency/echo is GUI-observable.)

- [ ] **Step 4: Full suite + commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add App/macOS/Sources/ReaderModel.swift
git commit -m "Route absolute edits through EditorCore.apply (publishSnapshot:false hot path preserved)"
git push origin main
```

---

## Task 7: Drop `ReaderModel`'s direct `DocumentSession` (Stage 5)

**Files:** Modify `App/macOS/Sources/ReaderModel.swift`.

- [ ] **Step 1: Remove the session property and its remaining direct uses**

`ReaderModel` should hold only `core: EditorCore` plus platform-bound render/caret state. Remove the `session` stored property and any lingering direct `session.` calls (route them through the core or drop them). Conflict/save-failure banners already mirror from `State` (Task 3). Update `registerLiveSession`/`liveSessionSnapshot` (the ⌘Q flush registry) to work against the core (add an `EditorCore.flush()`-based registry entry, or register the core). H1-rename stays in the shell keyed on `isUncommitted` (unchanged), but its `session.saveNow()`/`relocate` calls route through new thin `EditorCore` passthroughs (`saveNow()`/`relocate(to:)`) if needed — add them to the core if the shell still needs them.

- [ ] **Step 2: Build the app + full suite**

Run the app build and `swift test`.
Expected: both green; grep confirms `ReaderModel` has no `DocumentSession` property.

- [ ] **Step 3: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add App/macOS/Sources/ReaderModel.swift App/macOS/Sources/QuoinApp.swift Sources/QuoinCore/EditorCore.swift
git commit -m "ReaderModel holds only EditorCore; no direct DocumentSession"
git push origin main
```

---

## Final verification

- [ ] `swift test` — full suite green, including all `EditorCore*` tests (the lifecycle/edit-pipeline/undo/conflict payoff).
- [ ] App builds: `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build`.
- [ ] **`ReaderModel` no longer owns a `DocumentSession`** (grep) — the exit criterion for ①.
- [ ] **Hot path intact** (Task 6 repro): typing burst + paste, no echo wedge, single render per edit, undo/redo work.
- [ ] **Lifecycle intact** (now automated): the resurrection/discard/Save-As behaviors are covered by `EditorCoreLifecycleTests` — run them explicitly and confirm green.
- [ ] Port the applicable Plan-1 GUI-only checks into `EditorCoreLifecycleTests` where they are now expressible headlessly (discard-vs-save, currentlyEmpty pipeline-inclusive, staleEditBase).
- [ ] Update `docs/reference/architecture.md` (concurrency/lifecycle section) to describe the `EditorCore` (engine) / `ReaderModel` (adapter) split and the AsyncStream mirroring.

## Notes for the redo sequence

This is sub-project ① (the engine + its Linux tests). It unblocks: ② an app unit-test target for the remaining `@MainActor` glue; ④ headless geometry tests; and the CARET-1 empty-paragraph-node plan (which now has a clean `EditorCore` to build the model change on) and the keystroke-grammar plan (which will carve the deferred edit-intent/caret-mapping surface out of the shell against this seam). ③ XCUITest is independent and can proceed in parallel.
