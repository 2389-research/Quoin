# Quoin for Android Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
> Design doc (approved): `docs/plans/2026-07-17-android-app-design.md` — read it first.
> Milestones 2–8 are specs with re-plan checkpoints: when a milestone is reached, expand it into
> bite-sized tasks with superpowers:writing-plans using what earlier milestones taught us.

**Goal:** Full-featured Quoin for Android in `App/Android` — real QuoinCore compiled with the Swift SDK for Android, Kotlin/Compose UI, complete review loop.

**Architecture:** Four layers — Compose app shell → QuoinDroidRender (Kotlin block composables + scene-IR renderer) → QuoinBridge (thin synchronous swift-java JNI facade) → QuoinCore + MermaidLayout + VinculumLayout compiled per-ABI. Files are the only truth; SAF-first storage.

**Tech Stack:** Swift 6.3 + Swift SDK for Android, swift-java (`wrap-java`), Kotlin, Jetpack Compose, Gradle, SAF (`DocumentFile`), `PdfDocument`.

**Working style:** All work on a `claude/android-*` branch (CI runs on `claude/**`). TDD throughout. Engine changes must keep the Linux CI leg and all 600+ existing tests green — the invariants in `docs/reference/invariants.md` are non-negotiable. Quoin's dependency policy applies to Swift targets; the Android app defines its own minimal-deps policy (AndroidX/Compose baseline, no networking libs, no analytics, no WebView — enforced by a `scripts/check-android-dependency-policy.sh` added in M2).

---

## Milestone 0 — Feasibility spike (GATE: no UI work until this passes)

**Deliverable:** a scratch Android app that parses a fixture document and accepts a suggestion via the real QuoinCore, plus a written spike report. Nothing from this milestone ships; the spike lives in `spikes/android/` and is deleted or archived after M2 adopts its lessons.

### Task 0.1: Install the toolchain

**Files:** none (machine setup)

**Step 1:** Fetch the official getting-started doc and follow it exactly — do not guess versions or triples:
`https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html`

**Step 2:** Install Swift 6.3+ via swiftly (or verify existing: `swift --version` must be ≥ 6.3).

**Step 3:** Install the Android Swift SDK bundle per the doc (`swift sdk install <url-from-doc>`), then verify:
Run: `swift sdk list`
Expected: an entry containing `android` (note its exact ID — every later build command uses it).

**Step 4:** Verify Android build prerequisites: `sdkmanager --list_installed` shows an NDK; note NDK version. Android Studio + an API 34+ emulator image available (`emulator -list-avds`).

**Step 5:** Record versions (Swift, SDK bundle ID, NDK, min API level supported by the SDK) in `spikes/android/NOTES.md`. Commit.

### Task 0.2: Cross-compile QuoinCore for Android

**Files:**
- Create: `spikes/android/NOTES.md` (running log)
- Possibly modify: `Sources/QuoinCore/*` (only if Android-specific guards are needed)

**Step 1:** From the repo root:
Run: `swift build --swift-sdk <android-sdk-id-for-aarch64> --product QuoinCore`
Expected: success — QuoinCore's non-Darwin paths are already proven on Linux. Android uses Bionic (not Glibc); if a guard like `#if canImport(Glibc)` fails, the fix is adding `canImport(Android)`/`canImport(Bionic)` arms to the existing guards in `FileWatcher.swift`, `SHA256Hex.swift`, `WordCounting.swift`, `DocumentSession.swift:177`, `FileCoordination.swift`, `DocumentFilePresenter.swift`.

**Step 2:** If guards changed: run `swift test` on macOS AND confirm the Linux CI container build (`docker run -v $PWD:/src -w /src swift:6.2 swift build`) still passes. Commit any guard fixes separately: `fix: Android (Bionic) arms for platform guards`.

**Step 3:** Repeat the cross-build for `x86_64` (emulator ABI). Record `.so`/static-artifact sizes per ABI in NOTES.md. Commit.

### Task 0.3: Minimal Swift facade for the spike

**Files:**
- Create: `spikes/android/SpikeBridge/Package.swift` (local package depending on Quoin via `path: "../.."`)
- Create: `spikes/android/SpikeBridge/Sources/SpikeBridge/SpikeBridge.swift`

**Step 1:** Write the smallest possible facade — three synchronous functions, no actors exposed:

```swift
// ABOUTME: Spike-only JNI facade proving QuoinCore runs on Android.
// ABOUTME: Exposes parse stats and a review round-trip as sync calls.
import QuoinCore

public struct SpikeBridge {
    /// Parse markdown, return "blocks=N words=N suggestions=N".
    public static func parseStats(_ source: String) -> String
    /// Accept the first suggestion mark; return the new source, or the input unchanged if none.
    public static func acceptFirstSuggestion(_ source: String) -> String
    /// Round-trip proof: parse then re-emit; must equal input byte-for-byte.
    public static func roundTrip(_ source: String) -> Bool
}
```

Implement with `MarkdownConverter.parse`, `SuggestionResolver`, and direct string comparison. Where session-actor APIs are needed, wrap with a `DispatchSemaphore` + `Task` bridge *inside* the facade (pattern to be productionized in M1).

**Step 2:** Test on host first: `swift test` with 3 unit tests (one per function) against a fixture from `Fixtures/`. Expected: PASS on macOS before any Android attempt. Commit.

### Task 0.4: Generate Kotlin bindings and build the scratch app

**Files:**
- Create: `spikes/android/app/` (minimal single-activity Compose app, `min SDK` per Task 0.1 findings)

**Step 1:** Follow swift-java's `wrap-java` docs to generate Kotlin/Java bindings for `SpikeBridge` and wire the swift-build-per-ABI + `.so` packaging into the app's Gradle build (the official Gradle plugin if it fits; hand-rolled `Exec` tasks if not — record which in NOTES.md).

**Step 2:** App behavior: on launch, load a bundled fixture (copy `Fixtures/showcase*.md` into assets), call all three facade functions, render results in a `Text`. Run on the x86_64 emulator.
Expected: correct stats string, suggestion accepted, `roundTrip == true`.

**Step 3:** Measure: release APK size with/without the Swift `.so`s (budget from design: ≤ 25 MB added), cold parse time for a 1 MB fixture on the emulator, and one physical arm64 device if available. Record in NOTES.md.

**Step 4:** Commit the spike. Write `spikes/android/REPORT.md`: versions, what broke, binding ergonomics (how Swift `String`/structs surfaced in Kotlin), sizes, timings, and a **GO / NO-GO recommendation**.

### Task 0.5: Gate review

Present REPORT.md to Dylan. **GO** → proceed to M1. **NO-GO** → stop; re-open engine strategy (SVG-fallback-only rendering, Rust core, or wait out toolchain issues) with superpowers:brainstorming.

---

## Milestone 1 — Engine seams + QuoinBridge (pure Swift, runs on macOS/Linux CI today)

**Deliverable:** upstream QuoinCore gains the two portability seams; a new `QuoinBridge` library target exposes the full synchronous facade, tested on macOS and Linux without any Android involvement. TDD per @superpowers:test-driven-development.

### Task 1.1: `FileAccess` seam

**Files:**
- Create: `Sources/QuoinCore/FileAccess.swift`
- Modify: `Sources/QuoinCore/DocumentSession.swift` (read/write/coordination call sites)
- Modify: `Sources/QuoinCore/FileCoordination.swift`
- Test: `Tests/QuoinCoreTests/FileAccessTests.swift`

Protocol shape (settled in design; refine at implementation):

```swift
// ABOUTME: Injectable file I/O seam so DocumentSession works over any byte
// ABOUTME: transport: POSIX paths (Darwin/Linux) or Android SAF streams.
public protocol FileAccess: Sendable {
    func read(_ target: FileTarget) throws -> Data
    func write(_ data: Data, to target: FileTarget) throws   // atomic where the transport allows
    func exists(_ target: FileTarget) -> Bool
    func contentStamp(_ target: FileTarget) throws -> FileStamp  // mtime+size or hash — drives change detection
}
```

Steps (TDD): failing test that a `DocumentSession` opened with an in-memory `FileAccess` round-trips open→edit→save byte-losslessly → implement `DarwinFileAccess` (wrapping today's `FileCoordination` behavior, default — **zero behavior change for macOS**) and thread the seam through the session → run full `swift test` (all 600+ green) → verify Linux container build → commit. The in-memory `FileAccess` also becomes a test utility for the whole suite.

### Task 1.2: Poll-based watcher backend

**Files:**
- Create: `Sources/QuoinCore/PollingFileWatcher.swift`
- Modify: `Sources/QuoinCore/FileWatcher.swift` (extract the existing interface; kqueue impl stays Darwin-guarded)
- Test: `Tests/QuoinCoreTests/PollingFileWatcherTests.swift`

Steps: failing test — polling watcher detects an external write via `contentStamp` change on explicit `checkNow()` (deterministic; no timers in tests) → implement (foreground cadence owned by the caller; watcher only compares stamps and fires the same callback kqueue does) → full suite + Linux → commit.

### Task 1.3: `QuoinBridge` target — session facade

**Files:**
- Modify: `Package.swift` (add `QuoinBridge` library target + test target, Swift 6 mode)
- Create: `Sources/QuoinBridge/QuoinBridge.swift`, `SyncActorBridge.swift`
- Test: `Tests/QuoinBridgeTests/BridgeSessionTests.swift`

The facade owns sessions keyed by handle (Int64), all calls synchronous, all results flat value types (no engine types leak — swift-java marshals only primitives/String/simple structs/arrays):

```swift
public struct QuoinBridge {
    public static func openDocument(source: String, docKey: String) -> Int64        // handle
    public static func snapshot(handle: Int64) -> DocumentSnapshotDTO               // blocks as flat DTOs
    public static func applyEdit(handle: Int64, revision: Int64,
                                 byteOffset: Int64, byteLength: Int64,
                                 replacement: String) -> EditResultDTO              // .applied(newRevision)/.staleBase/.invalidRange
    public static func save(handle: Int64) -> String                                // current source out; host writes via SAF
    public static func reloadFromHost(handle: Int64, source: String) -> DocumentSnapshotDTO
    public static func undo(handle: Int64) -> EditResultDTO
    public static func redo(handle: Int64) -> EditResultDTO
    public static func close(handle: Int64)
}
```

Note the inversion that falls out of SAF: **the Kotlin side owns bytes-on-disk** (reads/writes content:// streams) and the bridge owns the session/undo/review machinery over source strings. `DarwinFileAccess` remains for Mac/Linux/CLI; Android uses `save`/`reloadFromHost` string passing. Document this in the file header.

Steps: failing tests for open→snapshot→applyEdit→undo→redo round-trip, stale-revision refusal, and invalid-UTF-8-boundary refusal → implement with the `SyncActorBridge` semaphore pattern from the spike (one dedicated concurrency domain inside the bridge; JNI threads never see Swift concurrency) → full suite + Linux → commit.

### Task 1.4: Bridge — review, front matter, search, outline, stats, export

**Files:**
- Create: `Sources/QuoinBridge/BridgeReview.swift`, `BridgeQueries.swift`
- Test: `Tests/QuoinBridgeTests/BridgeReviewTests.swift`, `BridgeQueriesTests.swift`

Surface (flat DTOs throughout): `reviewList`, `reviewAccept/Reject/Dismiss(handle:markOffset:markLength:)`, `reviewAcceptAll/RejectAll`, `reviewAddComment/Suggestion/Highlight(selection:)`, `reviewModeTransformKeystroke`, `frontMatterFields`/`applyFrontMatterEdit`, `search(options:)`, `replace`, `outline`, `stats`, `exportHTML/Markdown/PlainText`. Each is a thin adapter over the existing engine types (`SuggestionResolver`, `ReviewAuthoring`, `SuggestTransform`, `FrontMatterEditing`, `DocumentSearch`, `Exporters`).

Steps: TDD each group against `Fixtures/` documents (the review fixtures already exist); assert drift-refusal surfaces as a typed status, never a throw across JNI → full suite + Linux → commit per group.

### Task 1.5: Bridge — scene IR for math and diagrams

**Files:**
- Create: `Sources/QuoinBridge/BridgeScenes.swift`, `SceneDTO.swift`
- Test: `Tests/QuoinBridgeTests/BridgeScenesTests.swift`

`mathScene(latex:displayStyle:themeParams:)` and `diagramScene(source:themeParams:)` run VinculumLayout/MermaidLayout with an **injected text measurer callback** (function-pointer/interface style that wrap-java can bridge; Kotlin implements it with `TextPaint`). Output: flat draw-list DTO (arrays of text runs / paths / fills / strokes with transforms). Include a `sceneToSVG` passthrough of the engines' SVG writers as the debugging/fallback path.

Steps: TDD with a stub measurer (fixed metrics) — assert draw-list geometry matches the engines' own layout tests for 3 math fixtures + 3 diagram fixtures; unsupported constructs yield the labelled-fallback DTO → full suite + Linux → commit.

### Task 1.6: Milestone gate

Full `swift test` on macOS, Linux container build+test, cross-compile `QuoinBridge` for both Android ABIs (build only). Present a delta summary to Dylan. Then **re-plan M2 in detail** (superpowers:writing-plans) using spike REPORT.md.

---

## Milestone 2 — `App/Android` skeleton + build pipeline *(re-plan when reached)*

Scope: real Gradle project at `App/Android` (Compose, min/target SDK per spike); Gradle ⇄ `swift build --swift-sdk` integration per ABI; binding generation as a build step; `.so` packaging; `scripts/check-android-dependency-policy.sh`; CI job (build + unit tests + emulator smoke test) added to `.github/workflows/ci.yml`; app icon/name; fixture assets for tests. Exit: CI-green empty app that opens a bundled fixture through the bridge and shows raw block text.

## Milestone 3 — Read-only rendering *(re-plan when reached)*

Scope: `QuoinDroidRender` module — block composables for all 26 block kinds; inline AST → `AnnotatedString` (all 14 inline kinds incl. suggestion mark visuals); code canvas with the 12 syntax themes; callout/quote/table/footnote/front-matter-chip/TOC visuals per `docs/design/handoff.md`'s visual language; scene-IR Kotlin renderer (Canvas) + bundled fonts + `TextPaint` measurer bridge; local images from library assets; labelled source cards for HTML/unsupported; `SelectionContainer`; theming seams (light/dark, Material You mapped onto Quoin theme); **conformance parity tests driven by `Fixtures/`**; screenshot tests. Exit: every fixture renders correctly; side-by-side eyeball against the Mac for the showcase doc.

## Milestone 4 — Library, files, `.md` handler *(re-plan when reached)*

Scope: SAF tree grant flow + persisted grants (multi-library); library browser (tree, breadcrumbs), quick open, recents; create/rename/move/delete; Kotlin-side byte ownership (read/write content streams, encoding detection parity tests, atomic-as-possible writes); polling change detection on resume/foreground wired to `reloadFromHost` → silent reload / conflict banner; optional all-files mode (real paths + inotify via `FileObserver`); intent filters (`ACTION_VIEW`/`EDIT`/`SEND`, `text/markdown` + path patterns) with standalone session + "Add to library"; `quoin://` deep links confined to granted roots; library-wide search. Exit: daily-drivable reader against a Syncthing-synced folder.

## Milestone 5 — Editing *(re-plan when reached)*

Scope: tap-block → in-place `BasicTextField` source editor with reveal styling; commit-on-close via `applyEdit` (revision-guarded, stale → re-sync snackbar); format bar (all engine structural commands, smart pairs, wrap-selection); new-block `+` flow; Return-continues-lists; checkbox tap-through; autosave debounce parity; undo/redo UI; first-H1 rename; embed editing with **adaptive Edit/Preview tabs (compact) / side-by-side (expanded) + live math strip**; focus mode; byte-losslessness instrumented tests through the full SAF path. Exit: full-featured editor, invariants re-asserted on-device.

## Milestone 6 — Review loop *(re-plan when reached)*

Scope: review sheet/panel with cards (accept/reject/dismiss, bulk); tap-card → scroll-and-flash; Review Mode typing via `reviewModeTransformKeystroke`; selection authoring actions; RDFM metadata display (authors, threads, relative time); drift-refusal UX; pull awareness (new-marks badge + local notification on library refresh). Exit: full couch-review loop against files an agent edits on another machine.

## Milestone 7 — Structure, navigation, properties *(re-plan when reached)*

Scope: outline sheet (live tracking, manual collapse), jump history, find & replace (all options), footnote jump/backlink, properties editor (typed front-matter editors), word count / reading time / per-element stats. Exit: Mac feature-matrix parity minus exports.

## Milestone 8 — Ship *(re-plan when reached)*

Scope: exports (HTML/MD/TXT via bridge; PDF via `PdfDocument` over the block layer), share sheet in/out, text zoom + font scale, predictive back, reduce-motion, accessibility pass (TalkBack over blocks and review cards), Play listing + signing, F-Droid-compatible reproducible build, README/docs updates (support matrix, `docs/design/platforms.md` Android section), screenshot automation in CI. Exit: released.

---

## Cross-cutting rules for every milestone

- Engine invariants (`docs/reference/invariants.md`) hold everywhere; any new projection path extends the relevant conformance tests.
- Every task: failing test → minimal implementation → full relevant suite green → commit (see @superpowers:test-driven-development).
- macOS + Linux CI legs stay green on every commit that touches Swift.
- No new Swift-side dependencies without `docs/reference/dependencies.md` justification; Android-side deps gated by the M2 policy script.
- Re-plan checkpoint at each milestone boundary; present a delta summary to Dylan before proceeding.
