# Quoin — project conventions

Quoin is a native WYSIWYG markdown editor for macOS (iOS/iPadOS later).
Swift/SwiftUI + TextKit 2, zero JavaScript at runtime, local-only.

## Canonical documents (in priority order)

1. `docs/design/handoff.md` + `docs/design/Markdown Editor Design Doc.dc.html`
   — the visual/interaction spec. High fidelity: colors, type ramp, spacing,
   and states are final. Canonical option choices: 1a Graphite, 1e classic
   tree sidebar, 1h ruled outline, 1k rounded text styling.
2. `docs/archive/TRD.html` — architecture (native engines, session model). Where it
   conflicts with the handoff, the handoff wins; note the conflict.
3. `docs/archive/PRD.html` — original viewer-scoped PRD, superseded by the handoff
   for scope but still valid for performance budgets and privacy stance.
4. `docs/reference/architecture.md` — contributor-level machinery map (data flow,
   editing model, math/diagram engines, invariants). `README.md` carries
   the public support matrix; keep both in sync with real capabilities.

## Non-negotiable architecture rules (from the handoff)

- Source of truth is the markdown string + AST (swift-markdown/cmark-gfm),
  NEVER attributed strings. The editor is a projection; edits mutate the
  source through `DocumentSession` and the renderer re-projects.
- Documents are plain `.md` files on disk. Folders = directories.
- View models are platform-free; only navigation containers differ.
- Never override system shortcuts: ⌘P print, ⌘E use-selection-for-find, ⌘H hide.
- Round-trip (open → edit → save) must be byte-lossless for untouched regions.

## Dependency policy

One code dependency: swift-markdown. Anything new requires written
justification in the TRD first; the default answer is no.

## Layout

- `Sources/QuoinCore` — platform-agnostic engine (parses, sessions, search,
  stats, exporters, math/mermaid parsers + diagram layout geometry). Must
  build and test on Linux.
- `Sources/QuoinRender` — attributed-string projection + TextKit 2
  typesetting and diagram drawing. Shared engine files (guarded
  `canImport(AppKit) || canImport(UIKit)`) sit at the target root; the
  platform view layers are isolated in subfolders — `AppKit/` (the macOS
  `NSTextView` editor: `QuoinTextView`, `ReaderCoordinator`,
  `MarkdownReaderView`) and `UIKit/` (`MarkdownReaderViewIOS`, the
  iOS/iPadOS/visionOS reader). Both paths compile in CI. NOT Mac
  Catalyst-safe: on Catalyst `canImport(AppKit)` is true, so the AppKit
  guards would need `&& !targetEnvironment(macCatalyst)` to route Catalyst to
  the UIKit branch.
- `App/macOS`, `App/iOS` — app shells; projects generated with XcodeGen
  (`project.yml` in each).
- `Tests/QuoinCoreTests` — every core feature gets tests here, including
  performance budgets (PerformanceTests) and pathological inputs
  (TortureTests).
- Screenshot automation: `-QuoinLibraryPath`, `-QuoinShotOpen`,
  `-QuoinShotState`, `-QuoinForceDarkMode` launch arguments preset app
  state; CI publishes PNGs to the `ci-screenshots` branch.

## How the rendering pipeline fits together (map for edits)

- `AttributedRenderer` (QuoinRender) projects a `QuoinDocument` into one
  attributed string. Every block's range is tagged with
  `QuoinAttribute.blockID`; block-level chrome is tagged with
  `QuoinAttribute.blockDecoration` (a `BlockDecoration` value).
- `QuoinTextView` (its own file; the reader view is split across
  `MarkdownReaderView.swift` / `ReaderCoordinator.swift` /
  `QuoinTextView.swift`) is the NSTextView
  subclass that draws those decorations behind the text in
  `drawBackground(in:)`, using TextKit 2 fragment frames so shapes track
  reflow. Code canvases, callout boxes, quote rules, diagram frames, table
  rules, and the front-matter chip are all drawn here — NOT with
  `.backgroundColor` attributes (per-glyph backgrounds render as ugly
  per-line strips; that was a shipped bug once).
- Syntax reveal: the active block re-renders as its literal source via
  `MarkdownSourceStyler`, character-for-character 1:1 with the file (hidden
  delimiters are 1pt clear text, never removed — edit mapping depends on
  this). Span delimiters reveal only when the caret is inside the span;
  structural line prefixes (`>`, `- [ ]`) stay faded-visible. When adding a
  new inline span type, add BOTH a renderer case in `AttributedRenderer`
  and a styler pass in `MarkdownSourceStyler`, and register its delimiter
  in the `claimed`-ranges ordering (`**` before `*`, links before
  emphasis).
- Interactive runs use link plumbing: `quoin-task://` (checkboxes),
  `quoin-anchor://` (heading jumps), `quoin-copy://` (code-block copy
  button reads `QuoinAttribute.copySource`). Handle new schemes in
  `Coordinator.textView(_:clickedOnLink:at:)`.
- Scroll-to-block commands (outline clicks) use `scrollTarget` +
  `scrollGeneration` — the generation bump is what re-fires a repeat click
  on the same heading; don't compare targets alone.
- Panel toggles (⌘0 sidebar, ⌥⌘0 outline) are View-menu commands in
  `QuoinApp.commands` delivered by NotificationCenter
  (`AppDelegate.toggleSidebarNotification` / `toggleOutlineNotification`).
  System window tabbing is disabled (`allowsAutomaticWindowTabbing =
  false`) because Quoin has its own document tabs.

## Build / run / debug (local macOS sessions)

- Package work: `swift build` and `swift test` at the repo root; that's
  what CI runs. The app: `cd App/macOS && xcodegen && xcodebuild -project
  Quoin.xcodeproj -scheme Quoin -configuration Debug build`. Both targets
  share DerivedData at `Quoin-auvclcixelydkdfodldptdztmdln`.
- Run the dev build directly for log capture:
  `…/Build/Products/Debug/Quoin.app/Contents/MacOS/Quoin > /tmp/quoin.log 2>&1 &`
  — NSLog lands in that file. Kill with `pkill -x Quoin`; only run ONE
  instance (a second one fights over the library).
- Hang forensics without Xcode: `sample Quoin 3` (non-invasive) or
  `lldb -p <pid> --batch -o 'bt all' -o 'detach'` (full symbols).
  Unified log: use `/usr/bin/log` — plain `log` is a zsh builtin that
  errors with "too many arguments".
- The app is sandboxed. `-QuoinLibraryPath` works for folders inside the
  container / test fixtures, but NOT for arbitrary user folders from a
  plain CLI launch — a normal launch restores the saved security-scoped
  bookmark instead. Clint's live library is `~/Documents/ClintNotes`
  (real notes — be gentle; `Quoin UX Test.md` at its root is a
  kitchen-sink fixture exercising every element type).
- SourceKit in-editor diagnostics ("No such module 'QuoinCore'", "Cannot
  find type … in scope" for newly added files) are stale-index noise; the
  compiler is the arbiter. Trust `swift build` / `xcodebuild`.

## UI testing via computer use (driving the real app)

- Bundle id is `ai.2389.Quoin`; request access by bundle id (the display
  name may not resolve). Finder also only resolves as `com.apple.finder`.
- Synthetic Escape keypresses NEVER reach the app (verified with an
  NSEvent local monitor: letters arrive, keyCode 53 doesn't). Do not
  report "Escape doesn't work" bugs from synthetic input — check with a
  real keyboard or instrument with a local event monitor first.
- The first click into an inactive window can be swallowed by window
  activation; a "click did nothing" needs a second attempt before it's a
  finding.
- Layout-sensitive verification (colors, rules, spacing) should be zoomed,
  not judged from the downsampled full screenshot — inline math once
  looked wrong at full-screen scale and was pixel-perfect zoomed.

## Hard-won pitfalls (each of these was a real shipped bug)

- A scrollable `NSTextView` needs `isVerticallyResizable = true` AND
  `maxSize` lifted to `greatestFiniteMagnitude` AND an unlimited-height
  text container. Default `maxSize` is the initial frame — with a zero
  frame the view silently can't grow, so nothing scrolls and
  `scrollRangeToVisible` snaps back.
- Every newline inside a rendered block is a paragraph: paragraph styles
  built from `paragraphStyle()` inherit the 12pt body gap. Code blocks,
  tables, and any multi-line block must zero `paragraphSpacing` explicitly
  or lines render double-spaced.
- Decoration geometry can be queried mid-reflow: after any attribute pass
  that changes fonts (syntax reveal flips 1pt↔full-size delimiters), call
  `invalidateDecorations()` — it schedules a second draw after TextKit
  settles, otherwise boxes lag behind their text.
- `MarkdownSourceStyler.styleLinePrefixes` must advance by
  `NSMaxRange(lineRange)`; the old clamped-location loop pinwheeled
  forever on the last line.
- Flowchart layering must ignore cycle back-edges or layout loops
  (`DiagramLayout`).

## Workflow

- Commit and push after every meaningful unit of work, to `main` (user
  directive).
- CI runs `swift test` on a macOS runner (`.github/workflows/ci.yml`).
  Cloud/Linux sessions have no Swift toolchain — CI is the compile feedback
  loop; keep it green.
- Design assets from the user land in `docs/design/`.
- When a UX/design question comes up, check `docs/design/handoff.md`
  first — it is specific down to point sizes and alpha values, and most
  "what should this look like" questions are already answered there.
