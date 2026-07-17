# Quoin for Android — design

**Date:** 2026-07-17 · **Status:** approved design, pre-implementation
**Home:** `App/Android` in this repo, alongside `App/macOS` and `App/iOS`.

## What we're building

A full-featured Quoin for Android — every macOS capability re-expressed in a
mobile-first interaction grammar, not a reader-first MVP. The defining
features carry over whole: the in-file review loop (CriticMarkup + RDFM),
byte-lossless editing on plain `.md` files, native math and diagrams, zero
JavaScript, local-only, no telemetry. Same doctrine, new lens.

## Decisions and rationale

| Decision | Choice | Why |
| :--- | :--- | :--- |
| Engine | **Compile the real QuoinCore for Android** (Swift 6.3 Android SDK, official since 2026-03) | Zero engine drift; 600+ tests, review machinery, and both layout engines come along free. QuoinCore + MermaidLayout + VinculumLayout are already proven platform-free by the Linux CI leg. Honors "port the lens, never rebuild the document." Rust/UniFFI rewrite was considered and rejected: ~9K LOC of invariant-laden reimplementation plus no Rust equivalent of Vinculum/MermaidKit. |
| Kotlin interop | **swift-java `wrap-java`** JNI facade | Official tooling. Pre-1.0 risk accepted; mitigated by keeping the facade thin and synchronous. |
| Editing UX | **Block-focused editor** — tap a block, it flips to an in-place source editor; commit is one `SourceEdit` through the session | Maps 1:1 onto invariant 10 (one block edits at a time, one caret). Confines IME autocorrect/gesture-typing composing chaos to a single block; only committed text becomes a byte splice. Mobile-native, not a shrunken Mac. Single-canvas WYSIWYG rejected as a bespoke-text-editor-vs-every-IME fight. |
| Storage | **SAF folder grant first, optional "All files access" upgrade** | Works with any synced folder (Syncthing/Drive/local), Play-safe by default. All-files grant (user opt-in, in settings) unlocks real paths + inotify. |
| Repo | **Monorepo: `App/Android` here** | Tightest engine coupling, no version skew; matches `App/iOS` precedent. |
| Doctrine | **Inherited wholesale** | Local-only, zero JS/WebView, no telemetry, MIT, files are the only truth, no sync service. |

## Architecture

Four layers, matching Quoin's own gradient:

```
┌────────────────────────────────────────────────┐
│ App shell — Kotlin + Jetpack Compose           │  all-new
│ library · editor · review · search · settings  │
├────────────────────────────────────────────────┤
│ QuoinDroidRender — Kotlin                      │  all-new (port of
│ block composables · block source editor ·      │  QuoinRender concepts,
│ decorations · scene-IR renderer (math/mermaid) │  not code)
├────────────────────────────────────────────────┤
│ QuoinBridge — Swift, swift-java wrap-java      │  new, thin
│ synchronous JNI facade over DocumentSession    │
├────────────────────────────────────────────────┤
│ QuoinCore + MermaidLayout + VinculumLayout     │  existing, unchanged
│ compiled per-ABI (.so: arm64-v8a, x86_64)      │  except portability seams
└────────────────────────────────────────────────┘
```

### QuoinBridge

A flat, synchronous, JNI-friendly Swift target. Concurrency stays on the
Swift side (actor-internal); Kotlin sees blocking calls wrapped in coroutines
on `Dispatchers.IO` (async across JNI is the known rough edge — avoided by
construction). Exposes: open/parse/snapshot, `applyEdit` (revision-guarded),
review ops (list/add/accept/reject/bulk/reply), front-matter ops,
search/replace, outline, stats, exporters, and scene-IR fetch for math and
diagram blocks (serialized as flat draw lists).

### Engine seams added upstream in QuoinCore

- **File I/O seam** — `DocumentSession` reads/writes through an injectable
  `FileAccess` provider so SAF `content://` streams work; the Darwin path
  keeps `NSFileCoordinator`. Also unlocks the Linux CLI direction.
- **Watcher backend** — behind the existing platform-guarded `FileWatcher`
  interface: poll-on-foreground + hash compare for SAF; inotify when
  all-files access is granted. External-change flows (silent reload when
  clean, conflict banner when dirty) are unchanged.
- Nothing else changes: the 20 invariants, review machinery, and parser are
  untouched.

### Build & CI

Gradle drives the Android app; a Gradle task invokes
`swift build --swift-sdk <android-target>` per ABI and packs the `.so` plus
generated Kotlin bindings. CI gains an `App/Android` job next to the macOS
and Linux legs. APK-overhead budget for runtime + engine: ≤ 25 MB added.

### Milestone 0 — feasibility spike (the escape hatch)

Before any UI work: cross-compile QuoinCore + layout engines with the Android
SDK, call `parse()` and a review accept from a scratch Kotlin app via
wrap-java, measure APK overhead. If the toolchain fails here, we regroup on
engine strategy before betting further work.

## Rendering and editing

**Rendered document.** A `LazyColumn` of block composables keyed by `BlockID`
(contentHash:occurrence — Compose recomposition scoping gets the fragment
cache's win for free). One composable per block kind: heading, paragraph,
list (tap-to-toggle checkboxes write back through the session), table
(horizontal scroll on narrow screens), code (12 syntax themes via the
engine's `SyntaxHighlighter` ranges), callout, quote, footnotes, front-matter
chip, TOC. Inline AST → `AnnotatedString` spans. Decorations (code canvas,
callout box + rule, quote rule) are per-block Compose backgrounds — no
ink-behind-text-storage trick needed because blocks are real composables.
Cross-block selection via `SelectionContainer`. Suggestion marks render with
the Mac's visual grammar (accent underlay / strike + red tint / dual-tint
substitution / comment chips / highlight pills); tap a mark to open its
review card.

**Block editing.** Tap a block → in-place source editor (`BasicTextField`)
with reveal styling: delimiters at 35% ink in mono, structural prefixes
faded, applied block-wide (no desktop caret precision on touch). Commit on
tap-outside / Done chip / back gesture — one revision-guarded `SourceEdit`,
then re-render. The IME does what it wants inside the field; only committed
text becomes a splice. Autosave keeps the 400 ms debounce contract. Undo/redo
are session-level (source-true).

- **Format bar** above the keyboard: B, I, strikethrough, highlight
  (long-press → palette), link, code, checkbox, heading cycle, list toggles,
  quote, indent/outdent — all engine structural commands. Smart pairs and
  wrap-selection come from the engine.
- **New blocks:** Return continues lists (engine logic); a `+` affordance
  between blocks inserts paragraph/heading/code/table/math/mermaid/callout.
- **First-H1 auto-rename** of Untitled files carries over.

**Opaque embeds (code, math, mermaid, tables) — adaptive preview:**

- **Compact (phone, keyboard up):** segmented **Edit / Preview** tabs.
  Preview is instant and never blank — held last-good render with a
  "preview paused" badge while mid-edit source is broken.
- **Expanded (tablet, landscape, open foldables):** true side-by-side live
  preview, the Mac contract intact.
- **Math exception:** a thin live preview strip docked above the format bar
  even in the Edit tab — math renders in milliseconds and is usually one
  line tall; live feedback is cheapest exactly where it's most valuable.

## Math and diagrams

Layout runs in Swift (VinculumLayout / MermaidLayout — the real engines),
emitting device-independent scene IR across the bridge as flat draw lists
(text runs, paths, fills, strokes, transforms). A Kotlin **scene-IR
renderer** draws them with Compose `Canvas` — native, themable, crisp at any
zoom, zero new dependencies. Both engines accept an injected text measurer:
we bundle the fonts the scenes reference and measure with `TextPaint` via a
JNI callback, so geometry matches the Mac.

*Fallback considered:* the engines' zero-dependency SVG writers + an Android
SVG library — less code, but adds a dependency, runtime SVG parsing, and
theming friction. Kept as the fallback if scene-IR bridging fights us in the
spike.

Unsupported LaTeX/Mermaid constructs degrade to the same labelled source card
as the Mac. Raw HTML → labelled source card (no HTML engine, by doctrine).
Local images decode async from the library folder; remote images stay
placeholders unless enabled per document; paste-image → copied into
`assets/` with an `![](…)` reference.

## Library, files, and sync

- **First run:** pick a folder (SAF tree grant, persisted). Library screen =
  folder tree, `.md` only, folders are directories. Multiple libraries via a
  grant list in settings.
- **Navigation:** quick open (fuzzy filename), recents, library-wide search
  streamed as you type.
- **File ops:** create/rename/move/delete through SAF.
- **Change detection:** snapshot polling on foreground/resume + hash compare
  (inotify under all-files). Silent live reload when clean; non-blocking
  conflict banner (Keep Mine / Take Disk) when dirty. Encoding detected on
  open, preserved on save.
- **Deep links:** `quoin://open?path=…` confined to granted roots.
- **`.md` handler registration:** intent filters for `ACTION_VIEW` /
  `ACTION_EDIT` / `ACTION_SEND` on `text/markdown` plus `.md`/`.markdown`
  path patterns (file managers often serve `text/plain` or
  `application/octet-stream`). An externally opened file gets a persistable
  single-document grant and a standalone editor session, with an **Add to
  library** affordance (copy into a library folder, or keep editing in
  place). Share-into text offers "save into library."

## Review loop (mobile-first)

- **Review surface:** bottom sheet (phone) or side panel (expanded) listing
  every mark as a card — author, relative time, change body — with Accept /
  Reject / Dismiss and Accept All / Reject All. Tap a card →
  scroll-and-flash the mark in context. Resolutions are the engine's atomic
  byte-safe splices; drift refusal surfaces as a "suggestion moved —
  re-syncing" snackbar, never a corrupt splice.
- **Review Mode** toggle: typing in block editors becomes suggestion marks
  via `SuggestTransform` (coalescing included). Selection actions: Add
  Comment / Suggest Replacement / Suggest Deletion / Highlight
  (`ReviewAuthoring`, self-calibrating).
- **Pull awareness:** on app open / library refresh, new marks since last
  visit badge the document and optionally raise a local notification
  ("3 new suggestions in Weekly Notes") — zero network.

## Structure, navigation, properties

Outline sheet with live section tracking and manual collapse; jump history
(back/forward); in-document find & replace (match case, whole word, regex,
in-selection); footnote tap-to-jump with backlink return; Properties editor
for front matter with typed editors (date picker, bool toggle, number,
list-as-CSV, edit-as-text escape hatch).

## Ship

- **Export:** HTML/Markdown/TXT from the engine; **PDF** by rendering the
  block layer into `PdfDocument` (light or dark, 100% scale). **RTF omitted**
  — AppKit-bound on the Mac, near-zero Android demand.
- System share sheet for files and exports. Word count, reading time,
  per-element stats. Focus mode, text zoom, font-scale accessibility.
- Dark mode + Material You dynamic color mapped onto Quoin's theme seams.
  Predictive back. Reduce-motion honored — the block flip animation is
  cosmetic by construction (same watchdog rule as the Mac).

## Testing

1. **Conformance parity:** the same `Fixtures/` corpus drives instrumented
   Android rendering tests — one corpus, two platforms.
2. **Bridge tests:** JNI marshalling round-trips, revision guards,
   edit-refusal paths.
3. **Screenshot tests** per block kind and review surface (Paparazzi or
   emulator), matching Quoin's screenshot-automation culture.
4. **Invariant re-assertion** where Android gives them new teeth:
   byte-lossless through SAF I/O, stale-edit refusal across the bridge,
   one-block-editing.

## Non-goals

- No sync service, no collaboration backend (files sync by syncing files).
- No WebView, no JavaScript, no network at runtime, no telemetry.
- No changes to macOS app behavior; engine changes limited to the named
  portability seams.
- No iOS work in this effort.
- RTF export.

## Risks

| Risk | Mitigation |
| :--- | :--- |
| swift-java pre-1.0 API churn | Thin facade; regenerate bindings per release; pin toolchain versions |
| Async across JNI | Synchronous boundary by construction; concurrency lives on each side separately |
| SAF performance (large libraries) | Snapshot caching; all-files fast path; library index kept app-side |
| Scene-IR bridging friction | SVG-writer fallback path documented above |
| Toolchain fails outright | Milestone 0 spike gates all UI investment |
