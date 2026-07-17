# Quoin — features context pack

*Everything someone evaluating Quoin should know. Verified against the code
on 2026-07-13 (pre-1.0, version 0.1.0). Companion pack:
`mermaidkit-features.md`.*

## One paragraph

Quoin is a native macOS WYSIWYG markdown editor. It renders markdown —
including LaTeX math and all 30 Mermaid diagram types — entirely with
TextKit 2, CoreText, and CoreGraphics: **zero JavaScript, zero web views,
zero network at runtime**. Documents are plain `.md` files on disk, folders
are directories, and the open→edit→save round-trip is **byte-lossless** for
every untouched region. The name: a *quoin* is the letterpress wedge that
locks type into the chase.

## The big differentiators

1. **No web engine, anywhere.** Every competitor's "beautiful markdown"
   is a browser in a trench coat (Electron, WKWebView, or a JS bridge for
   MathJax/mermaid.js). Quoin's math typesetter and diagram engines are
   native Swift drawing with CoreText/CoreGraphics. Consequences a buyer
   can feel: instant cold start, native scrolling/selection/a11y, no
   blank-flash re-renders, tiny memory footprint, and diagrams that match
   the app's typography and dark mode exactly.
2. **The source is the document.** The markdown string + AST is the single
   source of truth; the editor is a projection of it. There is no export
   step between "what you see" and "what's in the file" — the file IS the
   truth, and untouched bytes are never rewritten. Move your library to
   any other tool at any time; nothing is held hostage.
3. **Syntax-reveal editing.** Click into rendered text and that block
   re-renders as its literal source, character-for-character 1:1 with the
   file (hidden delimiters become 1pt clear glyphs, never removed — so
   caret math never lies). Escape flips back. Only the span under the
   caret reveals its `**`/`*`/`==` delimiters; structural prefixes stay
   faded-visible.
4. **Live side-by-side diagram/math editing.** Diagrams and equations are
   presentation objects: they open for editing only deliberately (the
   `‹/› edit` chip, ⌘↩, or the context menu — never an accidental click).
   While editing, a live preview panel renders every keystroke; while your
   mid-edit source is momentarily invalid, the last good render holds with
   a quiet "Preview paused" badge instead of flashing away. Motion is
   choreographed (Reduce-Motion-aware flip transitions).
5. **Local-only privacy.** No account, no sync service, no telemetry, no
   crash reporting, no network calls at runtime. Remote images render as
   placeholders *by design*. (Direct distribution will add exactly one
   optional network touch: the update check, user-disableable.)
6. **Data-loss paranoia, tested.** Autosave-in-place with: quit-flush that
   survives ⌘Q mid-keystroke, conflict detection that *halts* autosave
   until the user picks a side, external-rename following via the file's
   inode, revision-stamped edits that refuse to splice against stale
   content, undo stacks cleared on external reloads, unreadable-file opens
   that detach instead of overwriting, and save failures that retry then
   surface a sticky banner. Each guarantee has a regression test.

## Markdown support (rendered natively, all of it)

- **CommonMark core** — headings, emphasis, lists, links, images, code,
  quotes, breaks (via swift-markdown/cmark-gfm).
- **GFM** — tables (per-column alignment, numeric right-align), task lists
  (checkboxes click-toggle and write back to source), strikethrough,
  autolinks.
- **Callouts/alerts** — `> [!NOTE]` etc., 5 semantic types (note, tip,
  important, warning, caution) with tinted cards.
- **Highlights** — `==text==` with palette cycling (`=={pink}…==`, ⇧⌘H).
- **Footnotes** — `[^id]`, gathered at document end, superscript refs.
- **YAML front matter** — compact metadata chip.
- **`[TOC]`** — live table-of-contents block.
- **Code syntax highlighting** — Swift, Python, JS/TS, Go, Rust, Ruby,
  C/C++/ObjC, Java/Kotlin, shell, SQL, YAML/TOML, JSON, HTML/XML/CSS;
  code blocks get a canvas card with a one-click copy button.
- **Local images** — async decode at display size; drag-and-drop copies
  into `assets/` and inserts the reference.
- **Raw HTML / remote images** — labelled source card / placeholder, by
  design (degrade, never break).

## Math (native TeX-style typesetter via Vinculum — no MathJax/KaTeX)

Math is drawn by **Vinculum** (Quoin's own first-party CoreText/CoreGraphics
math engine, consumed from GitHub like MermaidKit — `github.com/2389-research/
Vinculum`, `from: "1.4.1"`). It now covers **~400 commands** (404 symbol-table
entries + 37 function-name operators), each carrying its correct TeX atom class
so inter-atom spacing is real. Delimiters `$…$`, `$$…$$`, `\(…\)`, `\[…\]`.
Core: Greek/operators/relations/arrows, fractions, `\sqrt[n]{}`,
sub/superscripts, big operators with stacked limits (`\sum` `\int` `\prod`,
integrals correctly keeping side-scripts), `\left…\right` auto-sized fences,
all matrix environments (`matrix`/`pmatrix`/`bmatrix`/`Bmatrix`/`vmatrix`/
`Vmatrix`/`smallmatrix`), `cases`, `aligned`/`align`/`alignat`/`gather`/
`gathered`/`split`/`multline`, `\text{}` `\mathbf{}`. Plus a deep KaTeX/amsmath
layer:

- **Math alphabets** to real Unicode glyphs: `\mathbb` `\mathcal` `\mathscr`
  `\mathfrak` `\mathsf` `\mathtt` `\boldsymbol`/`\bm` `\pmb` (ℝ 𝒜 𝔤 𝖷 𝚡).
- **Accents**: `\hat \vec \bar \dot \ddot \tilde \check \breve \acute
  \grave \mathring`, stretchy `\widehat`/`\widetilde`/`\widecheck`, and
  `\overline`/`\underline` (accents hug the glyph's ink top, not the font
  ascent).
- **Fractions & stacks**: `\frac` `\dfrac` `\tfrac` `\binom` `\dbinom`
  `\tbinom`, true full-size `\cfrac`, custom `\genfrac`, `\overset`
  `\underset` `\stackrel`, `\overbrace`/`\underbrace` with labels,
  `\substack`.
- **Over/under constructs**: `\overbracket`/`\underbracket`,
  `\overparen`/`\underparen`, and vector arrows
  `\overrightarrow`/`\overleftarrow`/`\overleftrightarrow` (and the `\under…`
  forms).
- **Stretchy arrows** `\xrightarrow`/`\xleftarrow` with over/under labels
  (the hook/harpoon/mapsto `\x…` variants are accepted and stretched but
  approximate a plain shaft).
- **Delimiters**: `\middle` interior fences, manual sizing
  `\big`/`\Big`/`\bigg`/`\Bigg` (+`l`/`r`/`m`), standalone `\langle \lceil
  \lfloor …`, and MATH-table size-variant glyphs for tall `( ) [ ] { }`.
- **Atom-class overrides**: `\mathbin \mathrel \mathop \mathord \mathopen
  \mathclose \mathpunct` force a subexpression's spacing class.
- **Decorations & boxes**: `\boxed`/`\fbox`, `\colorbox`/`\fcolorbox`,
  `\rule`, `\raisebox`, `\cancel`/`\bcancel`/`\xcancel`/`\cancelto`, `\not`,
  `\phantom`/`\hphantom`/`\vphantom`/`\smash`, `\mathrlap`/`\mathllap`/
  `\mathclap`.
- **Color**: `\color`/`\textcolor` (named palette + `#hex`), both the braced
  two-argument form and the **stateful** `\color{name}` form.
- **Equation tags**: `\tag{…}`/`\tag*{…}` render inline (`\notag`/`\nonumber`
  are no-ops); true flush-right placement is a host concern.
- **Operator names**: `\operatorname`/`\operatorname*` (the starred form
  stacks its limits), `\pmod`/`\bmod`/`\pod`, spacing commands (`\,` `\;`
  `\quad` `\hspace` `\mkern` …).
- **Document-scoped macros**: `\newcommand`/`\renewcommand`/`\def` are
  collected across the whole document and expanded everywhere — define a
  shorthand once, use it in any equation (even before its definition).
- **Directly-typed Unicode** (`∫ ∑ ≤ α`) is classed like its `\command`
  spelling, so a raw `∫` gets stacked limits and correct spacing.

Vinculum is verified by its own golden-image harness and a coverage ledger in
**Vinculum's** CI (not Quoin's) — the exhaustive, code-checked support matrix
lives in Vinculum's `docs/COVERAGE.md` / `docs/COMMANDS.md`. Vinculum never
throws and never half-renders: an unknown command becomes an `.unsupported`
leaf, so Quoin shows a source card whose caption NAMES the offending command
(via `MathParser.unsupportedCommands`). Genuinely-unsupported constructs that
still fall back today: `\DeclareMathOperator`, `\sideset`, `\mathchoice`,
harpoon accents, `\begin{CD}`, and out-of-scope packages (mhchem `\ce`,
siunitx, `\href`). Note: `\tag` and `array` column rules/`\hline` now render
natively.

## Diagrams

All **30 Mermaid diagram types** render natively via MermaidKit (see the
companion pack for the full list and per-type details). Inside Quoin:
diagrams participate in syntax-reveal editing with the live preview panel,
match the document theme (including dark mode) via the `DiagramTheme`
seam, and unsupported/broken sources degrade to a labelled source card
with copy button.

## The app around the editor

- **Library** — a folder you choose; the sidebar is the real directory
  tree. Move/rename/trash/new-folder from context menus; drags from
  outside COPY in, internal drags move (⌘Z undoes); FSEvents keeps the
  tree live when Finder or sync tools change things.
- **Tabs** — real document tabs (⌘1–9, ⌘W), persisted across relaunch,
  with rename-stable identity (an H1 rename never interrupts typing).
- **Quick Open (⇧⌘O)** — fuzzy title + full-text results, arrow-key
  navigation, empty query shows recents.
- **Library search (⇧⌘F)** — persistent sidebar search with snippets.
- **Outline panel (⌥⌘0)** — ruled tree, live section tracking, collapsible
  subtrees, hover-peek preview card of any section.
- **Navigation** — jump history (⌘[/⌘] Back/Forward), breadcrumb menu in
  the status bar, reading-progress hairline, `quoin-anchor://` heading
  links.
- **Focus modes** — Focus Mode (⌥⌘F) dims all but the current paragraph;
  Sentence Focus narrows to the sentence; Typewriter Scrolling (⌥⌘T) holds
  the caret line steady.
- **Writing stats** — word/char counts, reading time, per-element counts,
  task progress, optional word-count goal with status-bar progress.
- **Daily note (⌘D)** — `Journal/YYYY-MM-DD.md`, created on first visit.
- **Find (⌘F/⌘G/⇧⌘G)** — debounced, match cycling without rescans.
- **Export (⇧⌘E)** — PDF (paginated, light/dark/system theme), HTML
  (standalone, styles inlined), Markdown (normalized), RTF, TXT; plus
  system Print (⌘P). Footnotes toggleable.
- **A real menu bar** — File/Edit/View/Go/Format menus where every item
  works, disables when it can't act, and checkmarks tell the truth;
  key-window routing (multi-window safe); Open Recent + Dock-menu recents;
  titlebar proxy icon (drag the file, ⌘-click the path).
- **First-run** — "Create a Starter Library" seeds a Welcome document and
  an editable Markdown Guide (the guide doubles as a CI conformance
  fixture: the build fails if the app stops supporting anything the guide
  teaches). Help menu: Guide, Welcome, Report an Issue.
- **Appearance** — system/light/dark; the code canvas stays a constant
  ink surface across appearances (design spec).
- **Accessibility** — VoiceOver labels on images/diagrams/equations,
  editing announcements; the chrome scales with Dynamic Type ("Larger text")
  while preserving the design's type ramp; Reduce Motion and Reduce
  Transparency honored throughout.

## Performance (measured, enforced)

CI budgets (PerformanceTests + RenderPathLatencyTests, 25ms convention):
parse 1MB to interactive < 1s; small-edit re-parse < 100ms; focus-dim,
attribute-sync, block-lookup paths each < 25ms. Local release baseline on
Moby Dick (1.2MB, 2,701 blocks): initial parse **345ms**, cold render
**98ms**, apply-edit **0.8ms**, incremental re-parse after a middle insert
**8.9ms**. A keystroke re-renders ONE block and splices one span into the
live text storage; TextKit 2 lays out only the viewport, so 70k-char
stress documents scroll at full frame rate.

## Trust & engineering signals

- Test suite: 642 tests in the package suite (QuoinCore + QuoinRender)
  including torture tests (10k-deep nesting, unclosed everything),
  byte-lossless round-trip suites, viewport-invariant tests (the caret line
  may not move on ANY projection change), math/diagram native-vs-fallback
  classification, latency budgets, and data-integrity regression tests for
  every fixed loss bug. (Golden-image math rendering lives in Vinculum's own
  CI; diagram rendering in MermaidKit's.)
- Dependency policy: ONE third-party dependency (Apple's swift-markdown,
  Apache 2.0, attributed in About ▸ Acknowledgements). MermaidKit (diagrams)
  and Vinculum (math) are Quoin's own first-party packages, consumed from
  GitHub. Everything else is Apple frameworks.
- QuoinCore (parse/session/search/stats/export engines) is platform-free
  and builds on Linux; an iOS/iPadOS reader target exists (editor later).
- Sandboxed, hardened runtime; notarization pipeline in
  `scripts/notarize.sh`.

## Screenshots & demo assets

Repo (`docs/images/`): `hero.png` (flagship document render),
`gallery-math.png`, `gallery-diagrams.png`, `gallery-blocks.png`,
`architecture-overview[-dark].png`, and `data-flow[-dark].png`. (Per-type
Mermaid renders are owned by the MermaidKit repo, not vendored here.) Fresh
full-app captures are
regenerated by CI on the `ci-screenshots` branch (16 shots — adds the
code-block editing state (20/21) — library,
document, native engines, structure diagrams, dark mode ×2, syntax
reveal, find bar, export sheet, quick open, library search, three
galleries). Screenshot automation is deterministic
(`-QuoinShotOpen`/`-QuoinShotState`/`-QuoinForceDarkMode` launch args).
The recommended marketing centerpiece (planned): an 8-second screen
recording of live diagram editing with the side-by-side preview.

## Try-it examples

Paste into any document (or open the bundled Markdown Guide):

    > [!TIP]
    > Callouts, ==highlights==, footnotes[^1], and `[TOC]` all render live.

    $$ \int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi} $$

    ```mermaid
    flowchart LR
      Edit[Keystroke] --> Session --> AST --> Project[One block re-renders]
      Project --> Edit
    ```

    [^1]: Gathered at the document end automatically.

## Requirements, price, status

macOS 14+ (Apple silicon & Intel). Direct distribution (no App Store),
Developer ID signed + notarized. Pricing: TBD (mechanics being built).
Status: pre-1.0 under active development; launch gate list lives in
`docs/history/launch-ledger.md` (all data-loss BLOCKERs fixed; remaining: app
icon, Sparkle update wiring, deep-perf items, visual token refresh).

## Honest limitations (as of today)

- macOS-only editor today (iOS reader target exists, unshipped).
- No sync/collaboration — files are files; use your own sync.
- Raw HTML doesn't execute (by design); remote images placeholder-only.
- Remaining math gaps (named-source-card fallback): `\DeclareMathOperator`,
  `\sideset`, `\mathchoice`, harpoon accents, `\begin{CD}`, and out-of-scope
  packages (mhchem `\ce`, siunitx, `\href`). (`\tag` and `array` column
  rules + `\hline` now render natively.) Some Mermaid diagram sub-features
  remain engine gaps, tracked in MermaidKit.
- No plugin system; no Vim mode.
