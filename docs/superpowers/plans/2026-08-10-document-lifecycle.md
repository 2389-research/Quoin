# Document Lifecycle & Authoritative State — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the document lifecycle (create → edit → discard | flush → move/rename/delete) a single-owner state machine with **awaitable teardown**, so no destructive filesystem op can race the async final save — eliminating the resurrection/duplicate/delete-then-fail bug family — and make "untitled" and "empty" one authoritative in-memory property consulted everywhere.

**Architecture:** Teardown stops being fire-and-forget. `DocumentSession.teardown(save:)` becomes an awaitable actor method; `ReaderModel.stop()`/`discard()` and `OpenDocumentStore.release(_:discard:)` become `async` and are awaited before any move/delete. The discard-vs-keep decision is a **pure function** over authoritative state (in QuoinCore, Linux-testable), fed by pipeline-inclusive emptiness (never a debounce-stale disk read). Scratch/untitled identity becomes a document **state flag**, not a filename prefix.

**Tech Stack:** Swift 6 (QuoinCore + macOS app target, strict concurrency), Swift actors (`DocumentSession`), SwiftUI + AppKit shell, XCTest. QuoinCore builds/tests on Linux.

**Source spec:** `docs/superpowers/specs/2026-08-10-editing-lifecycle-first-principles-issues.md` — this plan implements **root cause RC-4** (fire-and-forget teardown racing FS ops) and the emptiness/untitled-state half of **RC-3/ARCH-4**, closing issues LIFE-1, LIFE-2, LIFE-3, LIFE-4, LIFE-5, LIFE-6, ARCH-2, ARCH-4, and SHELL-2. It is **Plan 1 of the redo**; the empty-paragraph node (CARET-1), the keystroke-intent grammar (RC-1), the full in-memory `DocumentID` + platform-free `EditorViewModel` extraction (ARCH-1/ARCH-3), the shell re-layer, and the vault scanner are subsequent plans.

## Global Constraints

- **Source of truth is the in-memory markdown string + AST, never the on-disk file.** Every lifecycle decision reads model/session state, never a `String(contentsOf:)` on the hot path.
- **QuoinCore is Swift 6 strict-concurrency and MUST build/test on Linux** — `DocumentSession`, the lifecycle decision, and state types live there with no AppKit/UIKit/SwiftUI imports.
- **The macOS app target is Swift 6 strict-concurrency** — keep `@MainActor` isolation correct; `ReaderModel`/`OpenDocumentStore`/`MainWindow` wiring must stay warning-clean.
- **No destructive FS op (move/delete/rename) may execute before the session that owns the URL is provably fully stopped** (flushed-or-discarded + unwatched + no pending write).
- **Discard and final-flush are mutually exclusive** under one owner. A discarded document is never written back.
- **Byte-lossless** for kept documents; **no data loss** for saved/moved documents.
- **No new dependencies.**
- Package tests: `swift test` at repo root. App build: `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build`.
- Commit after each task and **push to `main`** (user directive; user consented to working directly on main for this line of work). Revert any incidental `Package.resolved` churn (`git checkout Package.resolved`) before committing — a bare `swift test` drops the Sparkle pin, which must not enter a commit.

---

## File Structure

**Created:**
- `Sources/QuoinCore/DocumentLifecycle.swift` — pure lifecycle decision: given authoritative state (is-scratch, is-empty, is-last-reference, operation), what action (keep-and-save / discard-without-saving / move / no-op). Linux-testable. The single place the "what happens on close/save-as" rule lives.
- `Tests/QuoinCoreTests/DocumentLifecycleTests.swift`
- `Tests/QuoinCoreTests/DocumentSessionTeardownTests.swift`

**Modified:**
- `Sources/QuoinCore/DocumentSession.swift` — add awaitable `teardown(save:)`; harden `saveNow()`'s discard/detached gating (~849).
- `App/macOS/Sources/ReaderModel.swift` — `stop()`→`async`, add `discard() async`, `currentlyEmpty() async` (pipeline-inclusive), authoritative `isUncommitted` state (replaces filename-prefix checks); H1 rename gated on `isUncommitted` (~1360).
- `App/macOS/Sources/OpenDocumentStore.swift` — `release(_:discard:) async -> Bool` (returns was-last-ref); awaits teardown.
- `App/macOS/Sources/MainWindow.swift` — `close(_:)`, `saveActiveDocument()` (Save-As), `persistSession()` routed through the state machine (~532, ~812, ~889).
- `App/macOS/Sources/ScratchStore.swift` — emptiness read consolidated to the authoritative predicate; keep `purgeEmptyUntitled` but via the shared rule.
- `Sources/QuoinCore/FirstRunDecision.swift` — honor `hasLibrary` (SHELL-2); it currently accepts the param and ignores it.

---

## Task 1: Pure lifecycle decision model

**Files:**
- Create: `Sources/QuoinCore/DocumentLifecycle.swift`
- Test: `Tests/QuoinCoreTests/DocumentLifecycleTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum DocumentLifecycle` with:
    - `struct CloseState { let isScratch: Bool; let isEmpty: Bool; let isLastReference: Bool }`
    - `enum CloseAction: Equatable { case keepAndSave; case discardWithoutSaving; case keepNoSave }`
    - `static func onClose(_ s: CloseState) -> CloseAction`
    - `static func shouldDeleteBackingFile(_ s: CloseState) -> Bool`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuoinCore

/// THE close-time rule, pure and exhaustive. A scratch doc that is empty AND the
/// last reference is discarded WITHOUT saving (so a final save can't resurrect
/// it); anything else is kept. A backing file is deleted ONLY for that same
/// discard case — never while another reference is live, never for a real doc.
final class DocumentLifecycleTests: XCTestCase {
    typealias S = DocumentLifecycle.CloseState

    func testEmptyScratchLastRefIsDiscardedWithoutSaving() {
        XCTAssertEqual(DocumentLifecycle.onClose(S(isScratch: true, isEmpty: true, isLastReference: true)),
                       .discardWithoutSaving)
        XCTAssertTrue(DocumentLifecycle.shouldDeleteBackingFile(S(isScratch: true, isEmpty: true, isLastReference: true)))
    }

    func testScratchWithContentIsKeptAndSaved() {
        XCTAssertEqual(DocumentLifecycle.onClose(S(isScratch: true, isEmpty: false, isLastReference: true)),
                       .keepAndSave)
        XCTAssertFalse(DocumentLifecycle.shouldDeleteBackingFile(S(isScratch: true, isEmpty: false, isLastReference: true)))
    }

    func testEmptyScratchNotLastRefIsNeverDeleted() {
        // Another live reference is still editing it: must not delete or discard.
        let s = S(isScratch: true, isEmpty: true, isLastReference: false)
        XCTAssertEqual(DocumentLifecycle.onClose(s), .keepAndSave)
        XCTAssertFalse(DocumentLifecycle.shouldDeleteBackingFile(s))
    }

    func testRealDocumentIsKeptAndSaved() {
        let s = S(isScratch: false, isEmpty: true, isLastReference: true)
        XCTAssertEqual(DocumentLifecycle.onClose(s), .keepAndSave)
        XCTAssertFalse(DocumentLifecycle.shouldDeleteBackingFile(s), "a real doc file is never deleted on close")
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter DocumentLifecycleTests`
Expected: FAIL — `cannot find 'DocumentLifecycle' in scope`.

- [ ] **Step 3: Implement the pure model**

```swift
/// The document lifecycle's close-time decision, as a pure function of
/// authoritative state. Keeping this in one place is what makes discard and
/// final-flush provably mutually exclusive: a document is discarded (never
/// saved) ONLY when it is a scratch doc, effectively empty, and the last
/// reference — every other case keeps and saves. A backing file is deleted only
/// for that same discard case, so a delete can never race a live session or a
/// pending write to a real document.
public enum DocumentLifecycle {
    public struct CloseState: Equatable, Sendable {
        public let isScratch: Bool
        public let isEmpty: Bool
        public let isLastReference: Bool
        public init(isScratch: Bool, isEmpty: Bool, isLastReference: Bool) {
            self.isScratch = isScratch
            self.isEmpty = isEmpty
            self.isLastReference = isLastReference
        }
    }

    public enum CloseAction: Equatable, Sendable {
        /// Flush the document to disk, then tear down.
        case keepAndSave
        /// Tear down WITHOUT saving; the backing file is discarded.
        case discardWithoutSaving
        /// Tear down without saving, but keep the backing file (a non-last
        /// reference releasing — another session owns the save).
        case keepNoSave
    }

    public static func onClose(_ s: CloseState) -> CloseAction {
        guard s.isLastReference else { return .keepAndSave }
        if s.isScratch && s.isEmpty { return .discardWithoutSaving }
        return .keepAndSave
    }

    public static func shouldDeleteBackingFile(_ s: CloseState) -> Bool {
        onClose(s) == .discardWithoutSaving
    }
}
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter DocumentLifecycleTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuoinCore/DocumentLifecycle.swift Tests/QuoinCoreTests/DocumentLifecycleTests.swift
git commit -m "Pure document-lifecycle close decision (discard/keep/delete)"
git push origin main
```

---

## Task 2: Awaitable, discard-aware session teardown

**Files:**
- Modify: `Sources/QuoinCore/DocumentSession.swift` (add `teardown(save:)`; harden `saveNow` ~849)
- Test: `Tests/QuoinCoreTests/DocumentSessionTeardownTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `DocumentSession.teardown(save: Bool) async` — cancels the debounced autosave, awaits nothing external, writes to disk only when `save == true` AND `hasUnsavedChanges`, then `stopWatching()`. After it returns, the session performs no further disk writes. Idempotent (a second call is a no-op).

- [ ] **Step 1: Write the failing test**

`DocumentSession` is a `public actor`; construct it with `DocumentSession(source:fileURL:)` and dirty it with the real `appendText` edit path (as `DocumentSessionAppendTests` does). `appendText("keep me")` yields source `"keep me\n"` and sets `isDirty`.

```swift
import XCTest
@testable import QuoinCore

/// Teardown must be awaitable and must NOT write when discarding — the fix for
/// the resurrection family (a fire-and-forget final save re-creating a
/// just-deleted file). After teardown(save:false) the file the session backed
/// must not be (re)written; after teardown(save:true) dirty content is flushed.
final class DocumentSessionTeardownTests: XCTestCase {

    private func tempFileURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quoin-teardown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Untitled.md")
        try Data("".utf8).write(to: url)
        return url
    }

    func testDiscardingTeardownDoesNotWriteAfterFileIsRemoved() async throws {
        let url = try tempFileURL()
        let session = DocumentSession(source: "", fileURL: url)
        _ = try await session.appendText("typed text")   // now dirty + non-empty
        try FileManager.default.removeItem(at: url)
        await session.teardown(save: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a discarding teardown must not resurrect the removed file")
    }

    func testSavingTeardownFlushesDirtyContent() async throws {
        let url = try tempFileURL()
        let session = DocumentSession(source: "", fileURL: url)
        _ = try await session.appendText("keep me")
        await session.teardown(save: true)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, "keep me\n", "appendText normalizes a trailing newline")
    }
}
```

Note: use `UUID()` for the temp dir — `Date()`/`Math.random` restrictions apply only to Workflow scripts, not to test code, so `UUID()` is fine here. If `appendText` is not the most convenient dirtying path, `try await session.apply(source: "keep me")` (line 470) is an equivalent in-actor mutation.

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter DocumentSessionTeardownTests`
Expected: FAIL — `value of type 'DocumentSession' has no member 'teardown'` (and/or the testing seam).

- [ ] **Step 3: Implement `teardown` + harden `saveNow`**

Add to `DocumentSession`:

```swift
    /// Awaitable, discard-aware teardown. Replaces the fire-and-forget final
    /// save: the caller can sequence a move/delete strictly AFTER this returns,
    /// and a discard (save == false) never writes — so a deleted scratch file
    /// is never resurrected. Idempotent.
    public func teardown(save: Bool) async {
        autosaveTask?.cancel()
        autosaveTask = nil
        if save {
            try? saveNowIfSafe()
        }
        stopWatching()
    }

    /// saveNow, but silently declines when there is nothing safe to write
    /// (not dirty, detached, or an unresolved conflict). Distinct from saveNow()
    /// which throws for those — teardown must not throw.
    private func saveNowIfSafe() throws {
        guard isDirty, !isDetached, !hasUnresolvedConflict else { return }
        try saveNow()
    }
```

`saveNow()` (~849) already guards `isDetached`/`isDirty`; keep it. The new `saveNowIfSafe` is the teardown-safe wrapper. Do NOT change existing `saveNow()` callers.

- [ ] **Step 4: Run the test**

Run: `swift test --filter DocumentSessionTeardownTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the whole package suite**

Run: `swift test`
Expected: PASS (no regressions to existing DocumentSession tests).

- [ ] **Step 6: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinCore/DocumentSession.swift Tests/QuoinCoreTests/DocumentSessionTeardownTests.swift
git commit -m "DocumentSession.teardown(save:): awaitable, discard-aware, never resurrects"
git push origin main
```

---

## Task 3: ReaderModel — awaitable stop/discard, pipeline-inclusive emptiness, uncommitted state

**Files:**
- Modify: `App/macOS/Sources/ReaderModel.swift` (`stop()` ~277, `flush()` ~306, `isEffectivelyEmpty` ~66, H1 rename ~1360)

**Interfaces:**
- Consumes: `DocumentSession.teardown(save:)` (Task 2).
- Produces:
  - `ReaderModel.stop() async` — `await session?.teardown(save: true)` after draining `editPipelineTask`.
  - `ReaderModel.discard() async` — `await session?.teardown(save: false)` after draining the pipeline.
  - `ReaderModel.currentlyEmpty() async -> Bool` — awaits `editPipelineTask` then returns `isEffectivelyEmpty` (pipeline-inclusive; fixes the LIFE-2 lag).
  - `ReaderModel.isUncommitted: Bool` — a stored state flag (scratch/untitled, not yet saved to a real home), set at `start` from whether the file is a scratch URL, cleared on relocate/Save-As. Replaces filename-prefix checks.

- [ ] **Step 1: Confirm the current shape (no test — App target has no unit bundle)**

The app target has no SwiftPM test bundle (only `QuoinUITests`, XCUITest). This task is verified by the app build + the pure seams it feeds (Tasks 1/2 tests) and by Task 5/6's behavior. Grep to confirm the current `stop()` fires a detached `Task` (~284–288) and `isEffectivelyEmpty` reads `document.source` (~66), and that `editPipelineTask` is the FIFO drained by `flush()` (~298).

- [ ] **Step 2: Make stop/discard awaitable**

Replace the fire-and-forget body of `stop()` (the `Task { await pendingEdits?.value; try? await session?.saveNow(); await session?.stopWatching() }` block) with:

```swift
    /// Cancel background tasks and return WITHOUT tearing down the session; the
    /// async teardown is a separate awaitable step so callers can sequence a
    /// move/delete strictly after it. Kept synchronous for onDisappear paths
    /// that only need background-task cancellation.
    func cancelBackgroundWork() {
        snapshotTask?.cancel(); snapshotTask = nil
        backgroundRenderTask?.cancel(); backgroundRenderTask = nil
        asyncRerenderTask?.cancel(); asyncRerenderTask = nil
        renameTask?.cancel(); renameTask = nil
        actionFailureTask?.cancel(); actionFailureTask = nil
    }

    /// Awaitable teardown that SAVES pending work (normal close of a kept doc).
    func stop() async {
        cancelBackgroundWork()
        await editPipelineTask?.value
        await session?.teardown(save: true)
    }

    /// Awaitable teardown that DISCARDS (empty scratch doc being thrown away).
    /// Never writes — so a subsequent removeItem can't be resurrected.
    func discard() async {
        cancelBackgroundWork()
        await editPipelineTask?.value
        await session?.teardown(save: false)
    }

    /// Emptiness AFTER the edit pipeline drains — the authoritative value a
    /// close/discard decision must use. `isEffectivelyEmpty` alone reads
    /// `document`, which lags until restoreCaret runs inside the pipeline
    /// (LIFE-2): a fast type-then-close would read pre-edit-empty and discard a
    /// doc that actually has text.
    func currentlyEmpty() async -> Bool {
        await editPipelineTask?.value
        return isEffectivelyEmpty
    }
```

- [ ] **Step 3: Add the uncommitted-state flag**

Add a stored property and set it in `start(fileURL:initialText:)` (~170) from `ScratchStore.isScratch(fileURL)`; clear it in the relocate/Save-As path when the doc gets a real home. Replace the filename-prefix guard in `scheduleH1Rename` (~1360, currently `url...lastPathComponent.hasPrefix("Untitled")`) with `guard isUncommitted else { return }` so a committed `Untitled thoughts.md` is never auto-renamed (ARCH-2).

```swift
    /// True while this document is an uncommitted scratch/untitled buffer that
    /// has not been saved to a user-chosen home. STATE, not a filename prefix —
    /// a real file named "Untitled…" is committed and must not be auto-renamed.
    private(set) var isUncommitted: Bool = false
```

Set `isUncommitted = ScratchStore.isScratch(url)` in `start`; set it `false` wherever the session relocates to a real home.

- [ ] **Step 4: Build the app**

Run: `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build`
Expected: BUILD SUCCEEDED, warning-clean on changed files. Fix any `@MainActor`/async-isolation errors (callers of the now-async `stop()` must `await`).

- [ ] **Step 5: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add App/macOS/Sources/ReaderModel.swift
git commit -m "ReaderModel: awaitable stop/discard, pipeline-inclusive emptiness, uncommitted state"
git push origin main
```

---

## Task 4: OpenDocumentStore — async release with discard + last-ref result

**Files:**
- Modify: `App/macOS/Sources/OpenDocumentStore.swift` (`release` ~90)

**Interfaces:**
- Consumes: `ReaderModel.stop()`/`discard()` (Task 3).
- Produces: `OpenDocumentStore.release(_ url: URL, discard: Bool) async -> Bool` — drops a reference; on the LAST reference tears the model down (`await model.discard()` when `discard`, else `await model.stop()`) and forgets it; returns `true` iff this call released the last reference. The entry is removed from `entries` synchronously (before the await) so a concurrent `acquire` of a reused URL never returns the dying model.

- [ ] **Step 1: Confirm current shape (build-verified task)**

Grep `OpenDocumentStore.release` (~90): it is synchronous, decrements refs, and on 0 calls `entry.model.stop()` (now async) + removes the entry. This task makes it async and returns the last-ref bool. Verified by the app build + Task 5 behavior.

- [ ] **Step 2: Implement**

```swift
    /// Drop a reference. On the LAST reference, tear the model down
    /// (awaitably) — discarding (no save) or stopping (save) per `discard` —
    /// and forget it. Returns whether this released the last reference, so the
    /// caller can gate a backing-file delete on last-ref (never delete a file a
    /// live session still owns). The entry is removed BEFORE the await so a
    /// racing acquire() of a reused URL builds a fresh model, never the dying one.
    @discardableResult
    func release(_ url: URL, discard: Bool = false) async -> Bool {
        let key = Self.key(for: url)
        guard let entry = entries[key] else { return false }
        entry.refs -= 1
        guard entry.refs <= 0 else { return false }
        entries[key] = nil
        if discard { await entry.model.discard() } else { await entry.model.stop() }
        return true
    }
```

Update the sync `release(_:)` callers (grep for `store.release(`): `onDisappear` (~onDisappear in MainWindow) becomes `Task { for tab in openTabs { await store.release(tab.url) } }` (or a single awaited loop). Every call site must `await`.

- [ ] **Step 3: Build the app**

Run: `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build`
Expected: BUILD SUCCEEDED. Resolve all `await`/isolation errors at call sites.

- [ ] **Step 4: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add App/macOS/Sources/OpenDocumentStore.swift App/macOS/Sources/MainWindow.swift
git commit -m "OpenDocumentStore.release: async, discard-aware, returns last-ref"
git push origin main
```

---

## Task 5: close() through the state machine (fixes LIFE-1, LIFE-2, LIFE-5)

**Files:**
- Modify: `App/macOS/Sources/MainWindow.swift` (`close(_:)` ~889)

**Interfaces:**
- Consumes: `DocumentLifecycle.onClose`/`shouldDeleteBackingFile` (Task 1), `ReaderModel.currentlyEmpty()`/`isUncommitted` (Task 3), `OpenDocumentStore.release(_:discard:)` (Task 4).
- Produces: no new API.

- [ ] **Step 1: Rewrite close() (build + manual-verified)**

`close()` runs on the main actor from button/⌘W handlers. Make the teardown path async via a `Task`. The decision uses **pipeline-inclusive** emptiness captured before release, `discard` is threaded into `release`, and the file delete is gated on `shouldDeleteBackingFile` with the **actual last-ref** result:

```swift
    private func close(_ tab: DocumentTab) {
        let closedIndex = openTabs.firstIndex { $0.id == tab.id }
        openTabs.removeAll { $0.id == tab.id }
        let model = store.model(for: tab.url)
        let url = tab.url
        Task {
            let isScratch = ScratchStore.isScratch(url)
            // Pipeline-inclusive emptiness — never the debounce-stale disk file.
            let isEmpty = isScratch ? await (model?.currentlyEmpty() ?? true) : false
            // We don't yet know last-ref; ask release. Compute the discard intent
            // from a provisional last-ref=true, then reconcile with the truth.
            let wantsDiscard = DocumentLifecycle.onClose(
                .init(isScratch: isScratch, isEmpty: isEmpty, isLastReference: true)) == .discardWithoutSaving
            let wasLast = await store.release(url, discard: wantsDiscard)
            if DocumentLifecycle.shouldDeleteBackingFile(
                .init(isScratch: isScratch, isEmpty: isEmpty, isLastReference: wasLast)) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if activeTabID == tab.id {
            activeTabID = closedIndex
                .flatMap { TabSuccession.successorIndex(closedIndex: $0, remainingCount: openTabs.count) }
                .map { openTabs[$0].id }
        }
    }
```

Note: `release` performed `discard` teardown (no save) when `wantsDiscard`; because teardown is awaited before `removeItem`, and discard never writes, the file cannot be resurrected. When `wasLast` is false, `shouldDeleteBackingFile` is false → never delete a file a live session owns (LIFE-5).

- [ ] **Step 2: Build the app**

Run: `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual verification — the resurrection repro (REQUIRED)**

Launch the debug build. Reproduce the reported bug and confirm it's fixed:
1. ⌘N (no library) → an Untitled doc. Type `hello`. Immediately ⌘W. Then ⌘N again several times. Expected: the new doc is EMPTY — `hello` never reappears. (LIFE-1/LIFE-2.)
2. ⌘N → type nothing → ⌘W → ⌘N. Expected: no accumulation of `Untitled 2/3/…`.

Per CLAUDE.md, drive this with a real keyboard (synthetic Return/⌘ keys are unreliable). If you cannot drive the GUI, say so explicitly and give the exact human steps — do not claim manual verification you didn't perform.

- [ ] **Step 4: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add App/macOS/Sources/MainWindow.swift
git commit -m "close() through the lifecycle state machine: no resurrection, last-ref-gated delete"
git push origin main
```

---

## Task 6: Save-As sequenced after teardown, move-first (fixes LIFE-3, LIFE-4)

**Files:**
- Modify: `App/macOS/Sources/MainWindow.swift` (`saveActiveDocument()` ~812)

**Interfaces:**
- Consumes: `OpenDocumentStore.release(_:discard:)` (Task 4).
- Produces: no new API.

- [ ] **Step 1: Rewrite Save-As so the move is strictly after teardown, and never routed through a delete**

The bug: `close(tab)` schedules async teardown, then `moveItem` runs before it (LIFE-3), and `close()` may GC-delete the source first (LIFE-4). Fix: flush, then **await a non-discarding release** (teardown with save, watcher stopped, no pending write), THEN move. Do not call `close()` (which couples in the GC):

```swift
    private func saveActiveDocument() {
        guard let tab = activeTab else { return }
        guard ScratchStore.isScratch(tab.url) else {
            Task { await store.flush(tab.url) }
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.markdownDocument]
        panel.nameFieldStringValue = tab.url.lastPathComponent
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.message = "Save this document."
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let source = tab.url
        openTabs.removeAll { $0.id == tab.id }   // drop the tab; we reopen at destination
        Task {
            await store.flush(source)                 // write current content into the scratch file
            _ = await store.release(source, discard: false)  // AWAITED teardown: saved + unwatched, no pending write
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: source, to: destination)  // move-first; source is quiescent
            } catch {
                NSSound.beep()
                // The source still exists and is intact (teardown saved it); reopen it so no work is lost.
                open(source)
                return
            }
            open(destination)
        }
    }
```

Key properties: teardown is **awaited** before the move (no detached `stop()` writing to `source` after the move → no duplicate at the old path, LIFE-3); Save-As never routes through `close()`'s empty-scratch GC (LIFE-4); on move failure the source is intact and reopened (no data loss).

- [ ] **Step 2: Build the app**

Run: `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual verification (REQUIRED)**

1. ⌘N → type `content` → ⌘S → pick a destination. Expected: EXACTLY ONE file at the destination with `content`; NO leftover `Untitled.md` in the scratch store; the reopened tab points at the destination.
2. ⌘N → type only spaces → ⌘S → pick a destination. Expected: a file exists at the destination (LIFE-4 — Save-As must not delete-then-fail).

Same GUI-honesty rule as Task 5.

- [ ] **Step 4: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add App/macOS/Sources/MainWindow.swift
git commit -m "Save-As: await teardown before move, move-first, never delete-then-fail"
git push origin main
```

---

## Task 7: H1 auto-rename gated on uncommitted state + serialized (fixes ARCH-2, LIFE-6)

**Files:**
- Modify: `App/macOS/Sources/ReaderModel.swift` (`scheduleH1Rename` ~1360, `performH1Rename` ~1376)

**Interfaces:**
- Consumes: `ReaderModel.isUncommitted` (Task 3).
- Produces: no new API.

- [ ] **Step 1: Gate on state, not filename; honor cancellation at each suspension**

Replace the filename-prefix guard (`url.deletingPathExtension().lastPathComponent.hasPrefix("Untitled")`) with `guard isUncommitted else { return }` (a committed file, even one named `Untitled thoughts.md`, is never auto-renamed — ARCH-2). In `performH1Rename` (~1376), check `Task.isCancelled` AFTER each `await` (the `saveNow`/`relocate` suspension points), not only once before starting, so a concurrent teardown/Save-As cancel is honored (LIFE-6). After a successful relocate, set `isUncommitted = false`.

- [ ] **Step 2: Build the app**

Run: `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual verification (REQUIRED)**

1. Create a REAL file named `Untitled thoughts.md` in a connected library, open it, type `# Meeting notes`, wait ~1s. Expected: the file is NOT renamed to `Meeting notes.md`.
2. ⌘N scratch doc, type `# My note`, then within ~1s ⌘S and pick a destination. Expected: exactly one file at the destination; no orphaned `My note.md` in the scratch store (the rename either didn't fire or was cancelled by teardown).

- [ ] **Step 4: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add App/macOS/Sources/ReaderModel.swift
git commit -m "H1 auto-rename gates on uncommitted state, honors cancellation (no committed-file rename)"
git push origin main
```

---

## Task 8: One authoritative emptiness/untitled predicate everywhere (fixes ARCH-4)

**Files:**
- Modify: `App/macOS/Sources/ScratchStore.swift` (`purgeEmptyUntitled` ~64, keep `isDiscardableEmptyScratch`), `App/macOS/Sources/MainWindow.swift` (`persistSession` ~532)

**Interfaces:**
- Consumes: `ReaderModel.currentlyEmpty()`/`isEffectivelyEmpty` (Task 3), `ScratchHousekeeping.isDiscardableEmptyScratch` (existing).
- Produces: no new API — consolidation only.

- [ ] **Step 1: Route every emptiness check through one predicate**

The audit (ARCH-4) found three divergent emptiness reads: `close()` (now fixed, pipeline-inclusive), `purgeEmptyUntitled` (disk read), `persistSession` (inline disk read + trim). For OPEN documents, `persistSession` must consult the live model (`store.model(for:url)?.isEffectivelyEmpty`) rather than re-reading disk, so it agrees with `close()`. For CLOSED files at launch, `purgeEmptyUntitled` legitimately reads disk (no model exists) but must use the shared `ScratchHousekeeping.isDiscardableEmptyScratch(contents:)` predicate (already introduced) — confirm it does and that `persistSession`'s guard (`ScratchHousekeeping.shouldPersistSession`) reads the model for open tabs, not disk.

Concretely, in `persistSession` replace the inline `(try? String(contentsOf:tab.url…))?.trimmed.isEmpty` for the sole-tab scratch case with `store.model(for: tab.url)?.isEffectivelyEmpty ?? false`.

- [ ] **Step 2: Build + full test**

Run: `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build` and `swift test`
Expected: both green.

- [ ] **Step 3: Manual verification (REQUIRED)**

⌘N → type text → quit (⌘Q) → relaunch. Expected: the typed doc reopens (persisted because the model reported non-empty, even if the disk write was mid-debounce at quit). ⌘N → type nothing → quit → relaunch. Expected: no blank Untitled reopens and none accumulate.

- [ ] **Step 4: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add App/macOS/Sources/ScratchStore.swift App/macOS/Sources/MainWindow.swift
git commit -m "One authoritative emptiness predicate: persistSession reads the model, not stale disk"
git push origin main
```

---

## Task 9: FirstRunDecision honors hasLibrary (fixes SHELL-2)

**Files:**
- Modify: `Sources/QuoinCore/FirstRunDecision.swift`
- Test: `Tests/QuoinCoreTests/FirstRunDecisionTests.swift` (extend)

**Interfaces:**
- Consumes: nothing.
- Produces: `FirstRunDecision.shouldCreateUntitled(...)` now consults `hasLibrary` — a window WITH a connected library but zero tabs does NOT auto-create a scratch Untitled (it shows the library empty state / library document instead).

- [ ] **Step 1: Write the failing test**

Extend `FirstRunDecisionTests`:

```swift
    func testLibraryWindowWithNoTabsDoesNotGetAScratchUntitled() {
        // A window with a connected library and zero tabs should NOT materialize
        // a scratch Untitled — it should show the library empty state instead.
        XCTAssertFalse(FirstRunDecision.shouldCreateUntitled(
            hasOpenTabs: false, hasLibrary: true, hasPendingOpens: false,
            isLaunchRestoration: false, reopenedScratchCount: 0))
    }

    func testNoLibraryTrueFirstLaunchStillGetsUntitled() {
        XCTAssertTrue(FirstRunDecision.shouldCreateUntitled(
            hasOpenTabs: false, hasLibrary: false, hasPendingOpens: false,
            isLaunchRestoration: false, reopenedScratchCount: 0))
    }
```

Note: this REVERSES the earlier `testAConnectedLibraryStillGetsAnUntitledDocument` (which encoded the now-rejected behavior). Delete that stale test in the same commit and cite the audit (SHELL-2) in the message.

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter FirstRunDecisionTests`
Expected: FAIL — the library case still returns true.

- [ ] **Step 3: Implement**

```swift
    public static func shouldCreateUntitled(
        hasOpenTabs: Bool, hasLibrary: Bool, hasPendingOpens: Bool,
        isLaunchRestoration: Bool, reopenedScratchCount: Int
    ) -> Bool {
        if hasOpenTabs || hasPendingOpens { return false }
        if isLaunchRestoration && reopenedScratchCount > 0 { return false }
        // A library window with no tabs shows its library empty state; only a
        // single-file (no-library) window auto-materializes a scratch doc.
        if hasLibrary { return false }
        return true
    }
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter FirstRunDecisionTests`
Expected: PASS.

- [ ] **Step 5: Build + verify the empty state**

Build the app; with a connected library and no open doc, confirm the empty state (with the New Document button, Task-10-of-the-original-plan fix) shows rather than a stray Untitled tab.

- [ ] **Step 6: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinCore/FirstRunDecision.swift Tests/QuoinCoreTests/FirstRunDecisionTests.swift
git commit -m "FirstRunDecision honors hasLibrary: library window shows empty state, not a scratch Untitled (SHELL-2)"
git push origin main
```

---

## Task 10: Remove the temporary clamp diagnostic + tidy

**Files:**
- Modify: `Sources/QuoinRender/AttributedRenderer.swift` (remove the `clamp.trailingPhantom` diagnostic added during live debugging)

**Interfaces:** none.

- [ ] **Step 1: Remove the diagnostic**

The live-debugging `QuoinPerformanceTrace.log("clamp.trailingPhantom", …)` in `clampTrailingNewlinePhantom` was for investigating CARET-1 (a later plan). It is not part of this plan's shipped behavior and the audit flagged the leftover log. Remove it.

- [ ] **Step 2: Build + full test**

Run: `swift test` and the app build.
Expected: green.

- [ ] **Step 3: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinRender/AttributedRenderer.swift
git commit -m "Remove temporary clamp diagnostic (CARET-1 investigation is a later plan)"
git push origin main
```

---

## Final verification

- [ ] `swift test` — full suite green (new DocumentLifecycle, DocumentSessionTeardown, FirstRunDecision cases included).
- [ ] App builds: `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build`.
- [ ] **Resurrection is dead** (Task 5 repro): type→⌘W→⌘N never resurrects text; no Untitled accumulation.
- [ ] **Save-As is safe** (Task 6 repro): exactly one file at the destination; whitespace-only Save-As still lands a file; move-failure keeps the source.
- [ ] **No committed-file auto-rename** (Task 7 repro).
- [ ] **Persisted docs survive quit; empties don't accumulate** (Task 8 repro).
- [ ] **Library window shows its empty state**, not a stray Untitled (Task 9).
- [ ] No fire-and-forget teardown Task remains in the lifecycle (grep `ReaderModel`/`OpenDocumentStore` for detached `Task {` around save/stop).
- [ ] Update `docs/reference/architecture.md` (concurrency/lifecycle section) and `docs/reference/invariants.md` with the awaitable-teardown + discard/flush-exclusivity + FS-op-sequencing invariants this plan establishes.

## Notes for the redo sequence

This is Plan 1 (RC-4 + the emptiness/state half of RC-3). It intentionally does NOT introduce the full in-memory `DocumentID` that replaces URL keying (`OpenDocumentStore.key(for:)`'s per-call filesystem stat, ARCH-3) — that lands with the platform-free `EditorViewModel` extraction (a later plan), for which the awaitable teardown and authoritative state established here are prerequisites. The empty-paragraph model node (CARET-1) — the blank-line caret/viewport bug — is a separate plan and is why Task 10 only removes the diagnostic rather than fixing the clamp.
