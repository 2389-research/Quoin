---
title: Audit context — editing + document-lifecycle portion (for the deep bug hunt)
created: 2026-08-10
status: working context (input to a first-principles redo)
---

# What this audit is

Clint's directive: a very deep, fresh-eyes bug hunt across the **editing +
document-lifecycle + shell portion** of Quoin, then a first-principles issue
list for redoing this portion. Grounded in the behaviors/capabilities we now
know we need (surfaced by a long live-testing session, below).

**The portion under audit** (Layer-0 "the document" + Layer-1 "the vault", per
`docs/design/single-file-first.md`):
- The edit/projection path: keystroke → `shouldChangeTextIn` → intent →
  `DocumentSession` → re-parse → async echo → re-projection. The markdown
  string + AST is the source of truth; the NSTextView is a projection.
- Caret + viewport machinery: caret mapping, the clamp/blank-line-height logic,
  viewport settle, decoration geometry.
- Document lifecycle: scratch/untitled creation, `OpenDocumentStore` (one
  session per file, refcounted), autosave (400ms debounce), `ReaderModel`
  start/stop/flush, close/discard, Save-As.
- Library/vault: `LibraryModel.rescan`, `Library.scan`, `SpotlightIndexer`,
  FSEvents watching.
- Shell: `QuoinApp`, `MainWindow` (onAppear ordering, tabs, restoration),
  `WindowGroup`/`handlesExternalEvents`, entry paths.
- Return/keyboard semantics: `ReturnSemantics`, `handleReturn`, paragraph
  break, gap deletion, hard break, key bindings.

# Key files

- Edit path: `Sources/QuoinRender/AppKit/ReaderCoordinator.swift`,
  `Sources/QuoinRender/AppKit/MarkdownReaderView.swift`,
  `Sources/QuoinRender/AppKit/QuoinTextView.swift`
- Projection/caret/clamp: `Sources/QuoinRender/AttributedRenderer.swift`
  (esp. `editableSlice`, `caretMapping`, `clampTrailingNewlinePhantom`,
  `compressInteriorBlankLines`, the reveal fragment assembly,
  `separatorUnchangedAcrossEdit`, `activeBlockEditUpdate`)
- Model/lifecycle: `App/macOS/Sources/ReaderModel.swift`,
  `App/macOS/Sources/OpenDocumentStore.swift`,
  `App/macOS/Sources/ScratchStore.swift`,
  `Sources/QuoinCore/DocumentSession.swift`
- Library: `App/macOS/Sources/LibraryModel.swift`,
  `Sources/QuoinCore/Library.swift`, `App/macOS/Sources/SpotlightIndexer.swift`,
  `App/macOS/Sources/FSEventsWatcher.swift`
- Shell: `App/macOS/Sources/QuoinApp.swift`, `App/macOS/Sources/MainWindow.swift`
- Return: `Sources/QuoinCore/ReturnSemantics.swift`, and the handlers in
  `ReaderCoordinator.swift`
- Design intent: `docs/design/single-file-first.md`,
  `docs/design/principles.md`, `docs/reference/invariants.md`,
  `docs/reference/architecture.md`

# What THIS SESSION already found + FIXED (do NOT re-report as new; DO look for siblings/related)

1. **Return was semantically dead in prose.** A paragraph's byte range excludes
   trailing newlines, so the gap between blocks belongs to no block and the
   caret had no legal home; a lone `\n` is a soft break. Fixed: `ReturnSemantics`
   rule table (BlockKind-keyed) + `editableSlice` absorbs whitespace in EXCESS
   of the canonical `\n\n` + paragraph-break insertion.
2. **`activeBlockKind` never reached the coordinator** — populated by the
   renderer but dropped at ReaderModel's 4 `RenderedDocument(...)` reconstruction
   sites, so `handleReturn` always bailed. Fixed (threaded through all 4). This
   is the "add a field to a compared model → extend EVERY projection site" class.
3. **Caret clamped to the raw block range, not the editable slice** — after
   Return the caret snapped back to the block's content end instead of the new
   blank line, so Return "did nothing" live even though the edit applied. Fixed:
   `AttributedRenderer.caretMapping` bounds the caret by `editableSlice`.
4. **⇧Return never reached the hard break** — macOS binds `insertLineBreak:` to
   ⌃Return; Shift+Return has NO binding and falls through to `insertNewline:`.
   Fixed: `QuoinTextView.keyDown` intercepts Shift+Return (prose-gated).
5. **App HANG on launch** — library root was `/Users/clint/Documents`;
   `LibraryModel.rescan` + `SpotlightIndexer.plan` recursively walk it (99% CPU,
   1.4GB). Mitigated by resetting the root; the scanner itself is NOT hardened.
6. **"New Document" button did nothing with no library** — called
   `library.createDocument()` (nil without a library); ⌘N had the scratch
   fallback, the button didn't. Fixed.
7. **Unsaved-doc text resurrected into a new document** — `close()` decided
   discard by reading the debounce-stale on-disk file; `stop()`'s final save is
   async and re-wrote the text onto a reused `Untitled.md`. Fixed: decide from
   the model's in-memory content before release.

# What is STILL OPEN (confirmed, unfixed — characterize + fold into the redo)

A. **The blank-line caret/viewport is wrong.** After Return the caret sits in a
   BIG gap (the literal `\n\n` renders as full-height lines) that COLLAPSES to a
   normal paragraph gap once the first character is typed — a viewport-invariant
   violation. In another state the caret renders as a TINY DOT (the blank line
   clamped to 2pt by `clampTrailingNewlinePhantom`, which only exempts the very
   last caret position). The clamp logic behaves inconsistently by caret
   position. THIS IS THE FRAGILE VIEWPORT LAYER — CLAUDE.md documents repeated
   "verified by one readout" bugs here.
B. **Untitled/scratch documents accumulate** and multiple appear on New
   Document / ⌘N. The auto-untitled guard fires for ANY empty window, and
   leftover scratch/library `Untitled*.md` files pile up.
C. **The library scanner is unbounded/eager** (finding 5) — even with
   depth-12 + hidden-name exclusions, a large root melts the app. No memory
   bound, unclear on-main vs off-main for indexing, likely re-entrant rescans on
   FSEvents.

# Deeper pattern to evaluate (for the first-principles framing)

Every bug above is downstream of two architectural choices:
- **The editor is a projection with an async-echo round-trip**, so the common
  typing path (type/Return/paste) rides the hardest code (queue/watchdog, patch
  vs full-render equivalence, caret re-mapping after re-parse). `single-file-
  first.md` poses the crux: should the common path stop riding the async echo?
- **The shell is library-first; the single file is bolted on.** Scratch docs,
  untitled, first-run, entry paths, and the lifecycle are grafts on a
  library-centric model, and each graft is where a bug lives.

# What the hunt should produce

Concrete, code-cited findings (bugs AND design fragilities), each with:
- file:line evidence and a concrete failure scenario,
- severity, and
- a **first-principles implication**: the invariant or design a redo of this
  portion should establish so this class of bug cannot recur.

Then a synthesized first-principles issue list, organized by subsystem, that
Clint can use to redo this portion — the Layer-0 (document) / Layer-1 (vault)
re-layering, with the edit-path and lifecycle guarantees made explicit.

## Live repro of CARET-1 (Clint, 2026-08-10, on the post-Plan-1 build)

Confirmed the CARET-1 critical is live (expected — the empty-paragraph-node plan is not yet done):
1. Type `# i am a cool developer` (heading).
2. Enter → HUGE newline gap (the `\n\n` renders as full-height lines + H1 spacing; no real empty-paragraph node to size it).
3. Start typing → the gap collapses to the expected paragraph spacing (viewport heaves on Enter, un-heaves on first keystroke — the invariant violation).
4. NEW/sharper symptom (data-touching, add to CARET-1 scope): backspace to the start of the new line, then ONE more backspace DELETES the `e` in "developer" — i.e. backspace across the synthetic gap lands in the HEADING's content instead of cleanly removing the paragraph break / merging the empty line. This is a correctness bug, not just visual.

Implication for the redo (RC-2 / audit step 2): the blank line between blocks must be a first-class model entity with its own byte range and caret home; rendered height a pure function of document state; and Backspace at the start of a materialized paragraph must remove the paragraph break (merge) — never delete a trailing content char of the previous block.
