# Launch ledger

*2026-07-10. Four-track pre-launch review (senior Swift, macOS platform/UI,
performance, product). Every entry verified against code at review time.
Status: OPEN / FIXED (commit) / DECISION (needs Clint). Work the BLOCKERs
top-down; nothing ships while a BLOCKER is open.*

## BLOCKERS

- **[FIXED] Open-failure data loss** — a file that exists but can't be read
  (encoding/permissions/cloud placeholder) silently became a BLANK session
  bound to the real URL; first keystroke autosaved ~1 byte over the user's
  document. Now: detached session (no fileURL) + sticky banner. `ReaderModel.start`.
- **[FIXED] Silent autosave failure** — `try? saveNow()` swallowed every save
  error forever (`lastSaveError` had no consumer). Now: retry once, then a
  sticky banner via `setSaveFailureHandler`. `DocumentSession`.
- **[FIXED] ⌘N black hole** — an empty document has no blocks, so every
  keystroke was silently dropped. Now: `onEmptyDocumentInsert` routes typing
  into the session at offset 0. Follow-up polish: dimmed "Start typing…"
  placeholder. `ReaderCoordinator`/`ReaderModel`.
- **[FIXED×2] No termination flush** — ⌘Q inside the 400ms autosave debounce
  dropped the last keystrokes. v1 (MainActor Task in terminateLater) STILL
  lost data — that runloop mode isn't guaranteed to run main-actor tasks;
  Clint hit it live. v2: snapshot sessions on main, flush on a DETACHED
  task, reply on main, 3s watchdog.
- **[FIXED] ⌘N not typeable until click** — no first responder on open;
  one-shot focus claim in updateNSView once the window exists.
- **[FIXED] Welcome/Guide buttons dead** — XcodeGen folder-type resources
  nest under Resources/ in the bundle; lookup now falls back to the
  subdirectory.
- **[FIXED] Menu commands broadcast to every window** — every menu-driven
  observer now guards on `controlActiveState == .key`; with two windows,
  ⌘Z/Export/⌘N act in the key window only. (Trash-tab-close deliberately
  stays broadcast — a dead tab must close everywhere.)
- **[OPEN] App icon does not exist** — generic AppKit icon today; no
  .xcassets anywhere. Commission now (lead time). (PM L6)
- **[DECIDED 2026-07-10: DIRECT distribution]** — consequences: (a) Sparkle
  2.x for updates — written justification SHIPPED
  (docs/reference/dependencies.md); wiring blocked on appcast host +
  EdDSA keys (Clint); (b) notarization pipeline SHIPPED
  (scripts/notarize.sh: archive → Developer ID sign → notarize → staple →
  Gatekeeper-verify) — needs Clint's signing identity + stored notary
  credentials to run; (c) privacy copy amendment pending Sparkle wiring;
  (d) pricing/licensing mechanics are ours to build. (PM L9/L10)

## HIGH — data integrity & correctness (senior review)

- [FIXED] Undo/redo stacks cleared on any non-edit adoption (external
  reload, take-disk, wholesale apply, toggle re-anchor) via
  `DocumentSession.adoptExternal`. #3.
- [FIXED] Conflict latches `hasUnresolvedConflict`: autosave suspended and
  `saveNow` throws `conflictUnresolved` until the user picks a side (even
  the ⌘Q flush can't clobber). #5.
- [FIXED] External rename followed via F_GETPATH on the live inode
  (`FileWatcher.onRelocate`); true vanish detaches the session — no write
  can resurrect the dead path; dirty sessions get the sticky banner;
  restored files re-attach through `reloadFromDisk`. #6.
- [FIXED] Undo/redo join the FIFO edit pipeline; a history splice bumps
  contentRevision so any in-flight edit stamped pre-undo is rejected
  (staleEditBase), never spliced at stale offsets. #7.
- [FIXED] Edit failure now unwedges immediately and REPLAYS the queued
  keystrokes against the fresh truth (recoverFromFailedEdit republishes a
  caret echo); the watchdog replays instead of discarding; failures
  surface as banners, never swallowed. #8.
- [FIXED] Format commands + smart paste join the echo queue
  (PendingEditorCommand): they queue mid-flight, flush against the fresh
  selection, and arm the gate like keystrokes. #9.
- [FIXED] Fence healing on commit-while-broken: FenceHealing appends the
  matching closing fence (```/~~~/$$, opener length + indent) as an
  undoable session edit on deactivation; indented code never heals. #10.
- [FIXED] Dead security-scope bookmark now explains itself: the first-run
  prompt shows what happened (moved/renamed/deleted, documents untouched)
  and how to reconnect (`bookmarkRestoreFailure`). #11.
- [FIXED] Same file opened twice is one session: `OpenDocumentStore` keys a
  single `ReaderModel` by the resolved/standardized URL and ref-counts it
  across every window and tab, so there is exactly one autosaver per file. #12.
- [FIXED] First-H1 rename no longer tears down the live editor: tabs are
  `DocumentTab` (stable UUID identity, mutable url); the editor keys on
  `tab.id`. #13.
- [FIXED] Edits stamped with `contentRevision` (non-edit adoption counter);
  `applyEdit` rejects stale bases (`staleEditBase`); ReaderModel mirrors
  via `revisionedSnapshots()`. iOS still passes nil bases (follow-up). #14.
- [FIXED] Sole-block Delete Block consumes only the block + its own line
  terminator; trailing blank lines/whitespace/reference definitions
  survive. #15.

## HIGH — platform/UI (macOS audit)

- [FIXED] First-run onboarding moved to the detail pane; sidebar stays
  quiet until a library exists. #3.
- [FIXED] Open tabs survive relaunch (@SceneStorage per window; only
  library-scoped files restore — panel one-offs need bookmarks). #4.
- [FIXED] Honest File menu: New Document ⌘N / New Window ⇧⌘N / Open… ⌘O /
  Open Recent / Close Tab ⌘W; system Close retitled Close Window ⇧⌘W via
  delegate menu surgery; hidden buttons deleted. #5.
- [PARTIAL] Undo/Redo disabled without a document. Remaining: sidebar
  move-undo only works with no tab open; ⌘Z still routes to the document
  while a text field (find bar) is focused. #6.
- [FIXED] Format/Export/Print/Find/Go/Close Tab enablement via
  `quoinHasDocument` focused value; format items need an active block. #7.
- [FIXED] File ▸ Change Library Folder…. #8.
- [FIXED] Sidebar file management: Move to Trash (files/folders,
  recoverable, closes tabs everywhere), New Folder, New Document in
  folder, folder rename, empty-area menu. #9.
- [FIXED] Quick open ↑/↓ + scroll-into-view + no-matches/empty-recents
  states. #10/#16.
- [FIXED] Real menus for everything: Go menu (Back/Forward/Quick Open/
  Daily Note), Edit ▸ Find family + Search Library, File ▸ Print…. #12.
- [FIXED] View toggles are checkmarked @AppStorage Toggles (+ Status
  Bar); Sentence Focus disabled without Focus Mode. #13.
- [FIXED] Titlebar document proxy (`navigationDocument`). #14.
- [FIXED] File ▸ Open… + Open Recent (+ Clear); system recents noted on
  every open; Dock menu shows recents. #15.
- [FIXED] Empty-library null state in sidebar. #17.
- [FIXED] Export sheet: DOCX card cut; window-modal save panel; Escape
  monitor suspends while the panel runs. #18.
- [FIXED] System sidebar-toggle duplicate removed (replacing: .sidebar). #19.
- [PARTIAL] a11y labels on new-document button + tab-bar tabs (button
  trait + selected). Full VoiceOver audit still owed. #20.
- [FIXED] Drag-and-drop story complete: external drops COPY (intra-library
  moves with ⌘Z), target folders + root highlight while hovered, failed
  drops beep, .md dropped on the editor opens a tab. #21.
- [FIXED] Tab switches keep the session alive (model owned by
  `OpenDocumentStore`, not the transient view) so undo history survives, and
  the editor stashes its scroll + caret in the model on teardown and restores
  them on return. #22.
- [FIXED] Sidebar keyboard selection opens documents. #23.
- [PARTIAL] Dock menu ✓, CFBundleTypeRole Editor ✓. Remaining: Services,
  progress hairline overlaps find bar. #24.

## HIGH — performance (all currently unbudgeted; entries #1–#16)

- [OPEN] Preview render is synchronous in the per-keystroke projection pass
  (~10–25ms) — go async with generation token via the choreographer. #1.
- [OPEN] The existing preview budget test bypasses the expensive path
  (`block: nil`) — fix the test; it will fail until #1 lands. #2.
- [OPEN] Non-patchable active blocks (LIST/quote/callout/TOC) take 3–4
  stacked O(document) passes per keystroke — the "gets slow on big files"
  configuration. Extend the patch path or budget it in CI. #3.
- [FIXED] Focus dimming repaints O(blocks) rendering attributes per caret
  move (sentence mode defeats the dedupe entirely) — now viewport-culled
  (binary-searched via BlockRangeIndex, extended lazily on scroll), and
  sentence mode dedupes on the caret's resolved sentence: an unchanged
  sentence is a no-op, a sentence move repaints only the current block.
  `ReaderCoordinator.applyFocusDimming`. Budgeted in RenderPathLatencyTests. #4.
- [FIXED] Active search rescans the whole document per keystroke — the
  scan is now debounced (120ms, keyed on query+ordinal+revision so
  unrelated passes can't starve it), ⌘G cycling recolors the two affected
  matches without any rescan, and clearing stays immediate.
  `ReaderCoordinator.applySearch`/`performSearchScan`. #5.
- [OPEN] Whole-document SHA-256 per keystroke in both fast paths. #6.
- [OPEN] Eager whole-doc layout per projection below 200k chars. #7.
- [FIXED-ALT] syncAttributesWhereDifferent walks all runs on every
  fallback splice. Bounding to changed∪active was REJECTED as unsound —
  attribute diffs land outside both (a re-rendered diagram is the same
  U+FFFC with a new attachment; pinned by ActivationNeighborIntegrity-
  Tests). Fixed instead by de-bridging the walk (toll-free CF attributes
  + CFEqual; dictionaries bridge only for runs that differ): ~110ms →
  ~11ms walk on a 66k-char doc, same diff detection. Budgeted in
  RenderPathLatencyTests. #8.
- [FIXED] Flip capture rasterizes viewport+overscan before knowing the plan
  is `.none` (most prose clicks) — `flipCaptureWorthwhile` now gates the
  capture pre-splice: exact skips on the plan's hard inputs (≥200k docs,
  degenerate viewport) plus a conservative height-delta estimate of the
  new fragment (skip only when confidently ≤ the 40pt threshold; anything
  ambiguous captures as before — a wrong skip is cosmetic-only by
  construction). Overscan clamped 600pt → viewport/2 (the max slide
  delta). Capture stays at backing scale: 1x would blur retina overlays. #9.
- [FIXED] Panel geometry callback dispatches per draw pass — now deduped:
  `onEditingFrameGeometry` fires only when the rect actually changed since
  the last report (nil included); panel-content changes behind an
  unchanged frame are re-planned explicitly on projection apply
  (`refreshPreviewPanelForProjectionChange`). `QuoinTextView`. #10.
- [FIXED] blockID()/topVisibleBlockID are O(blocks) linear scans on
  caret/scroll paths (string alloc per key in the scroll path!) — now a
  sorted-ranges `BlockRangeIndex` (built lazily once per projection,
  binary-searched per query); the scroll path resolves id strings through
  a prebuilt map. `ReaderCoordinator`. Budgeted in RenderPathLatencyTests. #11.
- [OPEN] Startup: only the parse half of "<1s to interactive" is budgeted;
  cold diagram rasterization is unmeasured. #13. Memory: AsyncImageStore
  count-limited not cost-limited (~1.5GB worst case). #14.
- [PARTIAL] One new RenderPathLatencyTests file enrolling focus/preview/
  list-typing/search/sync in the 25ms budget convention. #16. SHIPPED:
  Tests/QuoinRenderTests/RenderPathLatencyTests.swift enrolls the
  focus-dim pass (block move + sentence move + no-op dedupe), the
  attribute-sync splice, blockID/topVisibleBlockID lookups, and pins the
  search debounce/⌘G-no-rescan behavior. REMAINING: preview and
  list-typing budgets belong to the #1/#3 architectural pass.

## PRODUCT (PM track) — see agent report for full specs

- [PARTIAL] First-run: starter-library prompt + welcome/guide seeding
  SHIPPED; remaining: Examples/ folder seeds, detail-pane CTA, "What is a
  library?" popover. L1/L2.
- [SHIPPED] Welcome doc + in-app Markdown Guide + Help menu (Guide,
  Welcome, Report an Issue). L3/L5/L14 partial.
- [SHIPPED] Guide as conformance fixture in CI (GuideConformanceTests
  fails CI if the guide's features regress). L5-acceptance.
- [OPEN] Version/bundle: 0.1.0→1.0 story; Viewer→Editor role. L7.
- [DECISION] Crash reporting stance (recommend: none + privacy copy). L8.
- [OPEN] Licenses view in About (Apache attribution REQUIRED for
  swift-markdown; MermaidKit repo needs a LICENSE file). L11.
- [OPEN] Launch screenshots AFTER the visual token pass; 8-second live-
  diagram-edit screen recording is the marketing centerpiece. L12.
- [FIXED] README stale claims (double-click row; 23→30 diagram types). L13.
  (Regressed 23 by the 2026-07-13 docs sweep, which normalized to the stale
  gallery instead of the code; re-fixed 2026-07-14 — 30 is the code truth.)
- [OPEN] "Where is Save?" reassurance: transient Saved whisper in status
  bar. (Delight/confusion analysis.)
- Launch gates from existing ledgers: fence healing (above), venn/C4
  MermaidKit engine session (#9/#10 rendering ledger).
- [SHIPPED 2026-07-11] Math coverage expansion (7 phases): named-command
  fallback captions; Unicode math alphabets (\mathbb/\mathcal/\mathfrak/…)
  + direct-typed Unicode classing; accents + \binom/\cfrac; \overset/
  \underset/\overbrace/\underbrace/\xrightarrow/\substack; \boxed/
  \phantom/\color; document-scoped \newcommand/\def macros; \hline no
  longer degrades arrays. ~35 golden fixtures (promotion ratchet enforces
  honesty), 60+ new parser/macro tests. Remaining named-fallback gaps:
  \tag/equation numbering, \DeclareMathOperator, array rule DRAWING +
  column-spec alignment, mhchem. A real OpenType MATH font (STIX) is the
  future upgrade — all parser work carries over.
