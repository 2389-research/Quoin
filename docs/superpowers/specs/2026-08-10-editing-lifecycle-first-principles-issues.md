# First-Principles Issue List — Redoing Quoin's Editing + Document-Lifecycle + Shell

*Synthesis of 34 confirmed/plausible findings across 7 audit lenses (edit-projection, caret-viewport, doc-lifecycle, library-vault, shell-windows, return-keyboard, architecture). Deduplicated to root causes; every issue traces to real code.*

---

## 1. What this portion should BE

The audit and `single-file-first.md` converge on one thesis: **the single `.md` file is the foundation, and everything else composes upward.** A redo commits to these principles:

- **P1 — Layer-0 is a self-contained document.** A platform-free `EditorViewModel` (ADR-0010) owns opening, editing, and byte-lossless saving of ONE file. It imports no SwiftUI, no `Library`, no vault policy; it builds and tests on Linux. The vault (Layer-1) *composes* editors; the dependency arrow points up, never down. Asset-folder policy, naming, and identity are *injected* by the composing layer so a bare file and a file-in-vault run identical code.

- **P2 — Rendered geometry is a pure function of document state, never of caret position.** The line under the caret must not move on screen on any projection change (the viewport invariant). This is only achievable if height depends solely on bytes + mode. The blank line between blocks must be a first-class model entity with its own byte range and caret home — not a synthesized slice papered over with caret-keyed height hacks.

- **P3 — Keystrokes are typed *intents*, resolved once, that survive deferral.** One classifier owns both the `doCommandBy` path and the `shouldChangeTextIn` path. The pending-edit queue carries semantic gestures (paragraph-break, hard-break, indent, gap-delete), never raw characters reconstructed from the OS default action. A deferred keystroke replays with the exact meaning it had when pressed. Ideally the common typing path (char/Return/paste) does not ride a two-actor async round-trip at all — the text view owns storage for plain runs and reconciles to source afterward.

- **P4 — Document identity is an in-memory value, not a file path.** An untitled document is a first-class in-memory buffer that acquires a URL only on save. "Untitled-ness" and "emptiness" are single authoritative properties of the in-memory document, computed one way and consulted by every create/close/persist/GC site. Identity comparison is O(1) with no filesystem stat on the hot path.

- **P5 — The lifecycle is a single-owner state machine with awaitable teardown.** Discard and final-flush are mutually exclusive under one owner. Any filesystem op (move, delete, rename) is sequenced *after* the session that owns the URL is provably fully stopped. No fire-and-forget teardown Task. Vault scanning is incremental (O(changed paths), never O(tree)), cancellable, cycle-safe, and bounded in memory.

---

## 2. Issue list by subsystem

Severity: 🔴 critical · 🟠 high · 🟡 medium · ⚪ low. Ranked within subsystem.

### A. Edit / projection path

**EDIT-1 — The common typing path rides the async-echo round-trip** 🔴
*Lenses: architecture, edit-projection.*
Every keystroke returns `false` from `shouldChangeTextIn` (`ReaderCoordinator.swift:620`), becomes a byte-range `SourceEdit`, goes through `onEdit` → `beginAwaitingEditEcho()` (711) → `ReaderModel.applyAbsolute` (1286) chaining a serialized FIFO Task main→`DocumentSession` actor→main→re-parse→`restoreCaret`→echo. Between send and echo, further input is queued (`pendingCommands` 496), gated on `awaitingEditEcho` (626), backed by a 2s self-firing watchdog (509/531). Complex edits arriving mid-flight with a non-empty queue are refused with `NSSound.beep()` (666–677). The plainest operations depend on the most intricate concurrency machinery in the codebase, and every finding below is downstream of this.
**Invariant the redo must establish:** the common path (char/Return/paste) must never be gated behind a distributed transaction across two actors with a queue and a timeout. Let the text view own storage for plain runs and reconcile to source afterward; projection/reveal layers on top of a reliable substrate.

**EDIT-2 — Return/⇧Return/Tab/gap-delete degrade to raw characters when an echo is in flight** 🟠
*Lenses: edit-projection (3 findings), return-keyboard. Merged.*
Semantic key handlers all guard `!awaitingEditEcho` and return `false` while an echo is in flight: `insertParagraphBreak` (2106), `insertHardLineBreak` (2133), `indentListLines` (2062), `handleGapDeletion` (2158), `continueListOnReturn` (2184), `continueQuoteOnReturn` (2221), `continueTableRowOnReturn` (2249). Returning `false` lets NSTextView run its default `insertNewline:`/`insertTab:`/`deleteBackward:`, which re-enters `shouldChangeTextIn` where the raw `\n`/`\t`/backspace is queued as `.keystroke` (659–665). `PendingEditorCommand` (489) models only raw text, and `flushPendingCommands` replays via `shouldChangeTextIn` directly (583–588), landing on the plain edit path (683) — never back through `handleReturn`. **Failure:** type a char and press Return within the echo window → queued lone `\n` = CommonMark soft break → "Return did nothing"; in a table cell the `\n` splits/terminates the table; a mid-echo Tab inserts a literal tab (can turn prose into an indented code block).
**Invariant:** the queue must be a vocabulary of semantic gestures, not raw text; no handler may "give up" into the OS default action as its deferral mechanism. One classifier owns both paths.

**EDIT-3 — Type-to-activate replays its first keystroke without engaging the echo gate → fast second keystroke splices at a stale offset** 🟠
*Lens: edit-projection (race).*
Typing on a rendered (inactive) block routes to `onActivateBlock` (`ReaderCoordinator.swift:733`), which does NOT call `beginAwaitingEditEcho` (only the edit/format/return/tab paths do). `ReaderModel.activateBlock` publishes the flip synchronously (625/669) then `replayPendingInsertion` queues the first char async (628→637→`applyAbsolute` 1269). Because `awaitingEditEcho` is still `false`, a second keystroke arriving before the replay echoes skips the queue and is mapped against the PRE-insertion `activeSourceText`. **Failure:** rendered `hello`, type `a` then `b` fast → both map at offset 5 against `hello` → result `helloba` (user typed `ab`); the generation guard (1297) also skips `a`'s `restoreCaret`.
**Invariant:** exactly ONE echo gate covers EVERY source mutation, including model-internal replays. Offsets are computed against, and validated against, the exact revision they will be applied to.

**EDIT-4 — Return in an empty document accumulates invisible leading blank lines** ⚪
*Lens: return-keyboard.*
In a blockless document, `handleReturn` bails (no active block), the default `insertNewline` reaches `onEmptyDocumentInsert` → `insertIntoEmptyDocument` (`ReaderModel.swift:938`) which appends at `document.source.utf8.count` regardless of caret. cmark parses `\n`-only source as zero blocks, so the guard stays satisfied and each Return appends another `\n`, autosaved to disk. **Failure:** fresh ⌘N, Return ×3, type `x` → source `\n\n\nx`.
**Invariant:** an empty document has one canonical representation; a gesture producing no structural change is a no-op, not an accumulating mutation.

### B. Caret / viewport invariant

**CARET-1 — Blank-line rendered height is a function of caret position (three coupled clamps over a synthesized coordinate space)** 🔴
*Lenses: caret-viewport, return-keyboard, architecture. Merged — this is STILL-OPEN item A.*
Markdown has no empty-paragraph node, so `editableSlice` extends a prose block's editable text through trailing/excess whitespace belonging to no block (`AttributedRenderer.swift:1198`), and `caretMapping` bounds the caret by that synthetic slice, not `block.range` (1184/1192). The visual consequence is then papered over by three independent caret-keyed height predicates: `clampTrailingNewlinePhantom` early-returns leaving full height when `caretOffset >= text.length` (1081); `compressInteriorBlankLines` skips compression when the caret is on the line (1116); the separator clamp is a third rule (1146). **Failure:** `Hello\n`, click in (caret 5 < len 6) → trailing `\n` clamped to 2pt. Press Return (caret 7 == len 7) → both blanks render full height → gap opens, content below jumps down. Type one char → block re-splits, clamps re-engage, gap collapses, content jumps back up. The page heaves on Return, un-heaves on first keystroke. A leftover `DIAGNOSTIC (temporary)` log fires on every `\n`-terminated render (1076–1080).
**Invariant:** the blank line between blocks is a first-class model entity with its own byte range and caret home; rendered height is a pure function of document state; editability of the gap comes from hit-testing/caret geometry, not from growing the line. Remove the diagnostic log.

**CARET-2 — Pin/settle anchors the caret fragment's TOP and assumes its height is stable; the keystroke path is not pinned at all** 🟠
*Lens: caret-viewport.*
`pinCaretLine`/`caretLineScreenY` anchor the caret fragment's `minY` (`ReaderCoordinator.swift:3128`, `QuoinTextView.swift:401`); pinning the top preserves the viewport only if that fragment's own height is unchanged. Worse, `caretLineAnchorY` is captured only on a flip (`MarkdownReaderView.swift:559–564`), so an ordinary keystroke has `caretLineAnchorY == nil` and takes `scrollCaretIntoViewIfNeeded` (762) — a no-op while the caret is visible (3178–3183). **Failure:** after the CARET-1 Return, typing `x` collapses the gap; not a flip → no pin → no scroll compensation → every line below jumps up. Even when pinned, a change in the caret fragment's own height shifts everything below it.
**Invariant:** viewport preservation anchors a STABLE reference (a line whose height cannot change, or a below-caret content anchor), and runs on the keystroke path, not only on flips. (Largely dissolved by fixing CARET-1.)

**CARET-3 — `compressInteriorBlankLines` off-by-one: caret at start of the following line inflates the blank above** 🟡
*Lens: caret-viewport.*
The membership test is `caretOffset >= line.location && caretOffset <= NSMaxRange(line)` (1116); for a blank line `[n, n+1)`, `NSMaxRange` is `n+1` — the first caret position of the *next* content line. **Failure:** loose list `- a\n\n- b\n`; caret at start of `- b` (offset 5 == `NSMaxRange` of blank `[4,5)`) leaves the inter-item gap at full ~33pt; press Right → collapses to 2pt, list jumps up — a viewport jump from a pure caret move.
**Invariant:** caret-to-line assignment is a partition using half-open ranges `[location, NSMaxRange)`; and per CARET-1, height is caret-independent anyway.

**CARET-4 — ProjectorEquivalence never places the caret on a blank line** 🟠
*Lens: caret-viewport (test-coverage).*
The corpus always uses `caret = min(3, slice.utf16.count)` and passes the *same* caret to both patch and full-render paths (`ProjectorEquivalenceTests.swift:111,117,125,169,183`); scripted `\n`/`\n\n` edits keep caret at 3, never on the new blank line. The caret-keyed clamp branches (CARET-1) are structurally invisible to this test. **Failure:** a future change to `clampTrailingNewlinePhantom`'s guard corrupts the fast-path projection while the test stays green.
**Invariant:** equivalence corpora sweep the caret across every clamp-relevant position (start, interior blank, end/trailing blank), and feed the two paths different carets where production can. (Moot once CARET-1 removes caret-sensitive height.)

**CARET-5 — CaretLineAnchorTests exercises only flips, never a keystroke that changes blank-line height** 🟡
*Lens: caret-viewport (test-coverage).*
Every case drives an activation flip, a width reflow, or a no-op scroll assertion (`CaretLineAnchorTests.swift:86…`); none drives Return-then-type with the caret on the resulting blank line, asserting a below-caret line's screen Y holds across both edits — exactly where CARET-1/CARET-2 live.
**Invariant:** the viewport guard must assert stability across the keystroke projection path, not only flips/reflows. Add a Return-then-type regression measuring a below-caret line's screen Y.

### C. Document lifecycle (data integrity)

**LIFE-1 — `stop()`'s unconditional async `saveNow()` resurrects a just-discarded scratch file** 🟠
*Lens: doc-lifecycle.*
`close()` computes `isEmptyScratch`, calls `store.release()` → `stop()` (which schedules a *detached, un-awaited* `Task { await pendingEdits; saveNow(); stopWatching() }`, `ReaderModel.swift:294–298`), then synchronously `removeItem()`s the file (`MainWindow.swift:904,909`). The detached Task can't run until the synchronous body yields, so `removeItem` runs first, then `saveNow` — which has NO `isDirty` gate (`DocumentSession.swift:849–878`) — re-writes the deleted file. **Failure:** ⌘N with no library → Untitled.md; immediate ⌘W → deleted → detached Task re-writes `""` to it → next ⌘N sees it → `Untitled 2.md`. The `ReaderModel:305` comment claiming `saveNow` no-ops when clean is contradicted by the code.
**Invariant:** teardown must not be able to un-discard. Discard and final-flush are mutually exclusive under one owner; `stop()` takes an explicit `discarding` flag; `saveNow()` gates on `isDirty`.

**LIFE-2 — Type-then-⌘W: discard reads pre-edit `document.source`, then `stop()` flushes the typed text back** 🟠
*Lens: doc-lifecycle.*
`isEffectivelyEmpty` reads `document.source` (`ReaderModel.swift:66`), but `document` is reassigned only in `restoreCaret` (1457), *inside* `editPipelineTask` after the async round-trip. Until then it holds pre-edit content. `close()` computes `isEmptyScratch` from this lagging value and deletes the file; `stop()`'s Task then drains `pendingEdits` (applying the keystroke) and `saveNow()`s the typed content to the deleted path. **Failure:** scratch doc, type `hello`, ⌘W before the round-trip lands → Untitled.md deleted → typed `hello` written back → reappears next launch.
**Invariant:** the discard decision must be made against the same authority the flush will write — await the drained pipeline first, or expose a synchronous pipeline-inclusive "pending source." A lifecycle decision from a snapshot a concurrent async path can still advance is unsound.

**LIFE-3 — Save-As move races the async session teardown, duplicating the file at the old scratch path** 🟠
*Lens: doc-lifecycle.*
`saveActiveDocument()` awaits `store.flush()`, calls `close(tab)` (whose `release()→stop()` only *schedules* a detached Task), then with NO await between synchronously `moveItem(tab.url → destination)` (`MainWindow.swift:830,835`). `moveItem` runs before the detached `stop()`; `stop()`'s `saveNow()` writes to `session.fileURL`, which still points at the vacated scratch URL (`relocate` is never called on this path) → recreates the scratch file with the moved content. Two files result; the resurrected scratch survives GC and reopens next launch. `stopWatching()` also hasn't run, so the watcher may see the move as a delete.
**Invariant:** a file move is sequenced AFTER the owning session is provably fully stopped (flushed + unwatched + no pending save). Teardown returns an awaitable completion; the mover awaits it.

**LIFE-4 — Save-As on a whitespace-only scratch doc deletes the file before the move, losing it** 🟡
*Lens: shell-windows.*
`saveActiveDocument` flushes → `close(tab)` → `moveItem` (`MainWindow.swift:830,835`). `close()` independently GCs when `isEmptyScratch` (900–901 → 908–910). A whitespace-only doc is `isEffectivelyEmpty`, so `close()` deletes it before `moveItem`, which then fails and beeps (836–838). **Failure:** scratch doc, type only spaces, ⌘S, pick a destination → no file at the chosen location.
**Invariant:** Save-As must preserve — move/copy first, then release/GC the orphaned source, and only if the move succeeded. Never route Save-As through an operation that may delete. (Same root as LIFE-3: close-coupled-to-GC.)

**LIFE-5 — `close()` deletes the scratch file without gating on the store refcount** 🟡
*Lens: doc-lifecycle (plausible).*
`close()` does `store.release(tab.url)` then unconditionally `if isEmptyScratch { removeItem }` (`MainWindow.swift:908`). `release()` only tears down the model at refs 0 (`OpenDocumentStore.swift:95`); the `removeItem` is not conditioned on last-ref. **Failure (if a scratch URL is held by ≥2 refs):** closing one tab deletes the file while another live session keeps autosaving it.
**Invariant:** only the refcount owner may delete the backing file — `release()` returns whether it was the last reference (or performs the discard itself); `close()` gates on that.

**LIFE-6 — H1 auto-rename can run concurrently with Save-As/close, moving the same file twice** 🟡
*Lens: doc-lifecycle (race). Related: ARCH-2.*
`performH1Rename` (`ReaderModel.swift:1376`) checks `Task.isCancelled` only once before starting (1371), never inside its body, and suspends at `saveNow`/`relocate` awaits. `stop()`'s cancel (288) is cooperative and honored only during the sleep. A concurrent `saveActiveDocument` (suspending at `store.flush`) can interleave, so two `moveItem`s target the same source URL. **Failure:** type `# My Note`, ~800ms later rename runs; during its suspension ⌘S runs → rename completes first (`Untitled.md → My Note.md`); Save-As `moveItem` then throws (source gone) → beep, no save → orphaned `My Note.md`.
**Invariant:** file-identity changes and any other lifecycle op on that file are serialized through one owner with real (not cooperative-flag) mutual exclusion; in-flight rename cancellation is honored at each suspension point.

### D. Library / vault

**VAULT-1 — The vault rebuilds its entire in-memory tree on every FSEvent; unbounded, uncancellable, cycle-unsafe, full-content-reading** 🟠
*Lenses: library-vault (5 findings), architecture. Merged umbrella — STILL-OPEN item C.*
This is one architectural defect with five faces:
- **Full rescan per FSEvent.** The FSEvents callback discards paths (`FSEventsWatcher.swift:31`) and calls bare `onChange()` → `rescan()` → full `Library.scan` from root + Spotlight reconcile (`LibraryModel.swift:220–274`). The app's own 400ms-debounced autosave lands inside the watched tree, so ordinary editing continuously self-triggers full-tree rescans.
- **Symlink cycles / exponential blowup.** `scanChildren` classifies by `.isDirectoryKey` (`Library.swift:67`), which resolves symlinks, and recurses (73) with no `.isSymbolicLinkKey` check and no visited-set. A `current -> .` link is re-walked to depth 12, each level re-enumerating the subtree.
- **Unbounded, uncancellable scan.** `Library.scan` has no node-count/memory ceiling and no `Task.isCancelled` checks; `scanTask` is never `.cancel()`ed anywhere (adopt/deinit cancel other tasks but not this one, `LibraryModel.swift:137,209–210`).
- **Spotlight holds every changed doc in one array.** `plan()` reads each changed `.md` fully via `String(contentsOf:)` uncapped (`SpotlightIndexer.swift:114`) and appends to one `items` array shipped in a single `indexSearchableItems` (63); first index treats every doc as changed. O(library) memory.
- **O(N) reconcile per tick.** `reconcile` stats every doc's mod-date on every rescan (107); the just-saved doc is always re-read+re-parsed.
**Failure:** point at `~/Documents` (the real launch-hang, 99% CPU / 1.4GB); or a synced Dropbox tree where every daemon write fires a full re-walk + Spotlight read for the whole editing session; or a symlink loop that explodes the path set.
**Invariant:** external-change work is O(changed paths), never O(tree). The scanner is incremental (apply FSEvent deltas), cancellable (cooperative `isCancelled` inside the walk, cancelled by adopt/deinit), cycle-safe (skip symlinks or dedupe by inode with a visited set), bounded in node-count/memory, per-file read-capped, and the app's own writes are suppressed from re-triggering. Indexing streams in bounded batches (peak memory O(batch)).

**VAULT-2 — Library-switch publishes the stale tree and reconciles the wrong root transiently** 🟡
*Lens: library-vault (state-desync).*
The coalescing guard makes a rescan during an in-flight scan set a flag and return (`LibraryModel.swift:245`); `adopt()` sets the new `rootURL` (216) then calls `rescan()`. The in-flight Task captured the OLD `rootURL` local (258) and on completion does `self.root = tree` (261) + `reconcile(root: tree, rootURL: <old>)` (267) before the queued rescan re-runs for the new root. **Failure:** switch from large library A (scanning) to B → sidebar shows A while `rootURL` is B for seconds; Spotlight reconciles A obsoletely.
**Invariant:** results are tagged with the root they belong to and dropped if the root changed on completion; only the current root's scan may mutate `root`/reconcile. (Dissolved by making VAULT-1 cancellable.)

**VAULT-3 — In-flight scan and Spotlight tasks leak past teardown** ⚪
*Lens: library-vault (resource-leak).*
`deinit` cancels `librarySearchTask`/`quickOpenTask` but not `scanTask` (`LibraryModel.swift:137`); `SpotlightIndexer` has no deinit and cancels `reconcileTask` only at the start of the next call (49); neither walker honors cancellation. **Failure:** close the window mid-first-index of a big vault → detached scan + reconcile keep reading/parsing against a dead model.
**Invariant:** every long-running detached task owned by a model is cancelled in deinit (or scoped to structured concurrency that dies with the owner), and walkers honor cancellation. (Same root as VAULT-1.)

### E. Shell / windows

**SHELL-1 — Opens arriving while the app is alive but window-less are stranded** 🟠
*Lens: shell-windows.*
Every external entry (`application(_:open:)`, dock recents, deep links, Services) only enqueues onto a slot and posts a NotificationCenter signal; draining happens only inside a `MainWindow` (`QuoinApp.swift:210–212,411`). With `.handlesExternalEvents(matching: [])` (41) SwiftUI spawns no scene per open, and there is no `applicationShouldHandleReopen`/`applicationOpenUntitledFile`/`openWindow`-on-open. **Failure:** close all windows (process survives), dock right-click → Recent Documents → pick a file → URL sits in `pendingOpenSlot`, nothing opens. Same for Services / `quoin://` delivered windowless.
**Invariant:** draining pending external opens is owned by an app/scene-level authority that guarantees a window exists — not delegated exclusively to a `MainWindow` that may not exist.

**SHELL-2 — Auto-untitled guard ignores `hasLibrary` — library users get a scratch Untitled on every empty launch** 🟠
*Lens: shell-windows. Related: LIFE-cluster / STILL-OPEN item B.*
`shouldCreateUntitled` takes `hasLibrary` but never references it (`FirstRunDecision.swift:5–12`); `MainWindow` passes `library.hasLibrary` (435) yet it is dead. A window WITH a connected library but zero tabs still creates a scratch `Untitled.md` in the app container (439) instead of the library empty state or a library document — contradicting the ⌘N handler which prefers `library.createDocument()` (244).
**Invariant:** empty-window materialization branches on library presence (library window → library empty state / in-library doc; single-file window → scratch); the decision seam must not accept parameters it ignores.

**SHELL-3 — Every New Window (⇧⌘N) creates a scratch Untitled that lingers when a file is opened into it** 🟡
*Lens: shell-windows.*
A ⇧⌘N window is blank and library-less; `onAppear` reaches `FirstRunDecision` and materializes a scratch Untitled (`MainWindow.swift:433,439). `open()` dedupes only an exact same-file URL and otherwise appends (686–693); it never replaces an untouched auto-untitled. **Failure:** ⇧⌘N then ⌘O `notes.md` → two tabs (empty Untitled + notes); repeated, `Untitled*.md` accumulate.
**Invariant:** an auto-materialized untitled is a REPLACEABLE placeholder — opening/creating a real document into a window whose only tab is an untouched auto-untitled replaces it, not appends.

**SHELL-4 — Multi-window launch restoration: durable-session single-claim leaves extra blank untitled windows** 🟡
*Lens: shell-windows (plausible).*
The durable-session mirror and scratch reopen are each claimed by exactly one window (`QuoinApp.swift:814–822,828–832`), but `FirstRunDecision` is evaluated per window (`MainWindow.swift:433`). Additional restored windows with empty `@SceneStorage` blobs find `durableSession()==nil`, zero tabs → each spawns its own blank Untitled.
**Invariant:** launch restoration is planned as a single app-level allocation across ALL restored windows — assign each recovered session/scratch set to a specific window and decide untitled creation once, globally, not as per-window races over single-claim shared state.

### F. Return / keyboard semantics

**KEY-1 — CRLF files break list/quote/table Return recognizers** 🟠
*Lens: return-keyboard.*
`DocumentSession` never LF-normalizes on load and `editableSlice` preserves CRLF byte-wise (`AttributedRenderer.swift:1221–1234`), so `activeSourceText` can contain `\r\n`. Recognizers use `hasSuffix("\n")`, false for the single `\r\n` grapheme (the documented pitfall); `trimmingCharacters(in:.whitespaces)` doesn't strip `\r`/`\n`. **Failure:** open a Windows-authored `.md`; Return on an empty list item duplicates the marker forever (empty-item check sees `\r\n` as non-empty, `ReaderCoordinator.swift:2379/2385`); Return at end of a table row → `tableRowInsertion` guard never matches (2436/2438) → plain `\n` splits the table.
**Invariant:** line-ending handling is established once at the boundary (LF-normalize on load with save-time restore, or one CRLF-aware `lineBody()` helper shared by every recognizer). Ad-hoc `hasSuffix("\n")` per recognizer guarantees recurrence.

**KEY-2 — Selection + Return inserts a soft break, not a paragraph break (heading vs paragraph diverge)** 🟡
*Lens: return-keyboard.*
Every Return handler guards `selection.length == 0` and returns `false` otherwise (2110/2137/2190/2226/2254/2162); the default `insertNewline` replaces the selection with a lone `\n`. **Failure:** select a word mid-paragraph, Return → word replaced by a space, no new paragraph; same in a heading → splits into two blocks. Identical gesture, opposite outcome by block kind.
**Invariant:** the Return semantics table is defined over `(blockKind, selectionState)`; a non-empty selection means "replace selection, then apply the block's Return rule at the collapsed caret" — never fall through to the system's soft-break insertion.

**KEY-3 — `paragraphBreakInsertion`'s `atDocumentEnd` parameter is dead / misleading** ⚪
*Lens: return-keyboard (maintainability).*
`paragraphBreakInsertion(...atDocumentEnd:)` never references `atDocumentEnd` (`ReaderCoordinator.swift:2296–2308`); the decision is made purely from the trailing-newline count. Two callers thread it through; the real end-of-doc guard lives only in `endOfDocumentParagraphInsertion` (2352). A contributor editing this shared recognizer can silently alter end-of-document behavior.
**Invariant:** recognizer functions are pure over exactly the inputs they use; drop the dead parameter.

*(EDIT-4, the empty-doc blank-line accumulation, also lives in this subsystem — filed under Edit/projection above.)*

### G. Cross-cutting architecture

**ARCH-1 — Layer-0 (the editor) is not extracted and depends UP on Layer-1 (the vault)** 🟠
*Lens: architecture.*
`ReaderModel` — the would-be Layer-0 `EditorViewModel` — lives in `App/macOS/Sources`, imports SwiftUI, is `@MainActor`, and embeds vault filesystem policy: `insertImage` → `Library.uniqueURL` (1528), `ensureAssetsFolder` writes `assets/` beside the file regardless of library (1583), `insertAssetReference` splices a relative path (1603), `performH1Rename` → `Library.rename` (1383). The document cannot be instantiated without the app shell and cannot build/test on Linux. **Failure:** a bare file opened via ⌘O with no library still gets an `assets/` sibling and library-style collision naming on image paste — inheriting vault behavior it never opted into.
**Invariant (P1):** extract a platform-free `EditorViewModel` (ADR-0010) with no dependency on `Library`/vault/SwiftUI; asset-folder policy is injected by the composing layer, so bare and in-vault documents run identical code and the layer tests on Linux.

**ARCH-2 — The document layer renames its own backing file as a side effect of typing an H1** 🟠
*Lens: architecture. Related: LIFE-6.*
`scheduleH1Rename` fires whenever the filename has prefix `Untitled` (`ReaderModel.swift:1362`) — a filename convention, not a scratch/uncommitted state — and after 800ms `saveNow()`s, calls `Library.rename`, mutates `fileURL`, fires `onFileRenamed` → global rekey/rescan broadcast (`MainWindow.swift:379–391`). It is invoked on every edit with no scratch guard. **Failure:** a user's real committed `Untitled thoughts.md`, type `# Meeting notes` → 800ms later Quoin renames it to `Meeting notes.md`, dangling any handle against the old URL.
**Invariant (P4):** auto-rename keys on document STATE (an uncommitted/scratch flag), never a filename convention; committed files never mutate their on-disk identity as a side effect of editing.

**ARCH-3 — File path IS document identity — there is no in-memory untitled document** 🟠
*Lens: architecture. Upstream root of the scratch/untitled/rename cluster.*
There is no first-class in-memory document: ⌘N always writes a real file (`ScratchStore.createUntitled`, 31–35), and identity/dedup/restoration/session-ownership all key on the URL (`OpenDocumentStore.key(for:)` 37). This is the upstream cause of scratch-GC, the H1 self-rename, and the scattered emptiness predicates — they exist only because a document cannot exist without a file. `key(for:)` also does a filesystem stat (`volumeSupportsCaseSensitiveNamesKey`, 45) on EVERY call, and `sameFile` calls it twice per comparison (53–54), invoked in hot loops like the per-tab rename scan (`MainWindow.swift:383`). **Failure:** the app must continually create, name, reap, and re-key files just to represent a draft (→ SHELL-2/3/4 accumulation); an H1 rename broadcast runs two filesystem stats per open tab on the main actor.
**Invariant (P4):** documents have a stable in-memory identity (a session/document ID) independent of any path; an untitled document is a first-class in-memory buffer that acquires a URL only on save; identity comparison is an O(1) value compare with no filesystem stat on the hot path.

**ARCH-4 — Untitled/scratch lifecycle is spread across ~6 sites with divergent emptiness predicates and filename-prefix identity** 🟠
*Lens: architecture. STILL-OPEN item B, root form.*
"Untitled" is a filename convention checked by path/prefix in multiple places, not a state on the document: `isScratch` = path prefix (`ScratchStore.swift:40–43`); `scheduleH1Rename` = name prefix (`ReaderModel.swift:1362`). Discardability is decided three ways: `close()` reads in-memory `isEffectivelyEmpty` (`MainWindow.swift:900–901`); `purgeEmptyUntitled` reads the file from disk (`ScratchStore.swift:69–70`); `persistSession` does its own inline disk read + trim (`MainWindow.swift:537–540`). Because disk lags the 400ms autosave, memory and disk predicates disagree; with identity keyed by filename, nothing reconciles "how many untitled documents should exist," so each path independently creates or spares one and `Untitled 2.md` piles up. Creation is scattered across ⌘N (244), the New Document button (971), `FirstRunDecision` (433), scratch reopen (425), and seeded `createDocument` (778).
**Invariant (P4):** untitled-ness and emptiness are a single authoritative property of the in-memory document, computed one way and consulted by every create/close/persist/GC site; scratch identity is never a filename prefix subject to divergent disk-vs-memory reads. (Subsumes ARCH-3 downstream and the whole SHELL untitled cluster.)

---

## 3. Root causes

Four architectural decisions generate nearly every issue above.

**RC-1 — The common typing path rides an async-echo round-trip across two actors.**
The floor of the app depends on its hardest code. *Spawns:* EDIT-1 (direct), EDIT-2 (handlers bail on `awaitingEditEcho` and degrade to raw chars), EDIT-3 (the gate doesn't cover model-internal replays), EDIT-4 (empty-doc insert path), CARET-2 (keystroke path is unpinned), CARET-4/CARET-5 (tests only cover flips, not the keystroke round-trip), and KEY-1's exposure via `editableSlice`. The redo's escape (P3): resolve keystrokes to typed intents and stop routing plain runs through the round-trip.

**RC-2 — There is no empty-paragraph model node; blank-line height is caret-keyed to paper over the gap.**
Rendered geometry is a function of caret position, which is exactly what the viewport invariant forbids. *Spawns:* CARET-1 (three coupled clamps), CARET-3 (off-by-one membership), CARET-4/CARET-5 (uncovered branches), STILL-OPEN item A. The redo's escape (P2): make the gap a first-class node so height is a pure function of document state.

**RC-3 — File path is document identity; there is no in-memory untitled buffer.**
The app must create/name/reap/rekey files just to represent drafts, and "untitled" becomes a filename convention with divergent emptiness predicates. *Spawns:* ARCH-3, ARCH-4, ARCH-2 (filename-prefix rename), SHELL-2/3/4 (untitled accumulation), and the hot-path filesystem stats. The redo's escape (P4): stable in-memory identity; URL acquired only on save.

**RC-4 — Lifecycle uses async fire-and-forget teardown, and destructive filesystem ops are not sequenced after it.**
Discard and final-flush race; moves/deletes race the un-awaited `stop()` Task. *Spawns:* LIFE-1 (resurrection), LIFE-2 (stale-source flush-back), LIFE-3 (Save-As duplicate), LIFE-4 (Save-As delete-then-fail), LIFE-5 (delete ignoring refcount), LIFE-6 (concurrent double-move). The redo's escape (P5): a single-owner lifecycle state machine with awaitable teardown; discard and flush mutually exclusive; every FS op sequenced after the session is provably stopped.

*Library/vault (VAULT-1/2/3) is a fifth, more contained root: **scanning is O(tree) and eager instead of O(changed-paths) and incremental**, unbounded/uncancellable/cycle-unsafe. It is architecturally independent of RC-1..4 and can be redone in parallel.*

---

## 4. Recommended sequencing for the redo

Ordered so each step establishes a contract the next depends on. Each step lists its exit criterion.

1. **Establish the Layer-0 document contract (the model + identity core).**
   Extract a platform-free `EditorViewModel` (ADR-0010) with an in-memory document identity (session ID), an authoritative in-memory emptiness/untitled property, and injected asset/naming policy. Resolves RC-3 foundations.
   *Exit:* `EditorViewModel` builds and tests on Linux; an untitled document exists with no file on disk; identity comparison does zero filesystem I/O; every emptiness/untitled check reads one property. (Neutralizes ARCH-1, ARCH-3, ARCH-4, ARCH-2's filename trigger.)

2. **Define the blank-line / gap as a first-class model entity.**
   Add an explicit empty-paragraph/gap node with its own byte range and caret home; delete `clampTrailingNewlinePhantom`, `compressInteriorBlankLines`, and the separator clamp caret exemptions; remove the diagnostic log. Resolves RC-2.
   *Exit:* rendered height is provably independent of caret position (a property test sweeping the caret across a blank line asserts constant fragment heights); `ProjectorEquivalenceTests` and `CaretLineAnchorTests` are extended to Return-then-type with caret on the blank line and stay green. (Closes CARET-1/3, STILL-OPEN A; makes CARET-4/5 assert the right thing.)

3. **Define the keystroke intent grammar and simplify the common path.**
   One classifier owns both `doCommandBy` and `shouldChangeTextIn`; the pending queue carries typed intents (paragraph-break, hard-break, indent, gap-delete, insert), never raw characters; establish one CRLF-aware `lineBody()` shared by all recognizers; define Return semantics over `(blockKind, selectionState)`. Decide RC-1's crux: text view owns plain-run storage, reconcile to source afterward (or coalesced synchronous simple inserts). Resolves RC-1.
   *Exit:* Return/⇧Return/Tab/gap-delete survive an in-flight echo with identical semantics (regression: paste-then-Return, type-then-Tab within the echo window); CRLF list/table Return tests pass; selection+Return produces a paragraph break in both prose and headings; the type-to-activate race cannot splice at a stale offset (one gate covers all mutations). (Closes EDIT-1/2/3/4, KEY-1/2/3, CARET-2.)

4. **Define the document-lifecycle state machine with awaitable teardown.**
   One owner sequences create → edit → (discard | flush) → move/rename/delete; `stop()` returns an awaitable completion and takes a `discarding` flag; `saveNow()` gates on `isDirty`; Save-As moves first and GCs the orphan only on success; H1 rename keys on the uncommitted-state flag and is serialized with all other FS ops. Resolves RC-4.
   *Exit:* the discard/flush and Save-As/rename race tests pass (type-then-⌘W keeps the file discarded; Save-As leaves exactly one file at the destination; a committed `Untitled*.md` is never auto-renamed); no fire-and-forget teardown Task remains. (Closes LIFE-1..6.)

5. **Re-layer the shell as document-first, vault-composed.**
   A window is a document first, optionally inside a vault; `FirstRunDecision` branches on library presence; auto-untitled is a replaceable placeholder; launch restoration is a single app-level allocation across all windows; an app/scene-level authority drains pending external opens and guarantees a window exists.
   *Exit:* library window with zero tabs shows the library empty state (no stray scratch); ⇧⌘N-then-⌘O replaces the placeholder; multi-window restore produces no extra blank windows; a windowless dock-recent/Services/deep-link open spawns a window and opens the file. (Closes SHELL-1..4, ARCH-1 fully.)

6. **Redo the vault scanner as incremental, cancellable, bounded, cycle-safe (parallelizable with 1–5).**
   Apply FSEvent path deltas instead of re-walking; suppress the app's own writes; cancellable walks (`isCancelled` honored, cancelled by adopt/deinit); skip symlinks or dedupe by inode; bound node-count/memory; per-file read caps; streamed bounded-batch indexing; tag scan results with their root.
   *Exit:* editing a file in a large vault triggers no full re-walk (O(changed-paths) verified); a symlink-cycle root does not blow up; pointing at `~/Documents` does not melt the app; switching libraries never publishes the stale root; deinit leaves no detached work running. (Closes VAULT-1/2/3, STILL-OPEN C.)