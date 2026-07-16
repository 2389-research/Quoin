# UI refresh — preparation

*2026-07-10. Clint supplied five reference screenshots ("Prepare to do a
UI refresh") showing a soft, rounded, card-based visual language. This
doc extracts the design tokens from those references, maps them onto
Quoin's theme seams, and lists the decisions that need Clint before
implementation. The reference PNGs should be dropped into
`docs/design/ui-refresh/` (they exist only in the conversation today).*

**Canon note:** this supersedes parts of the Graphite handoff's visual
spec (option 1a). The handoff remains canonical for INTERACTION rules
(reveal model, viewport invariant, keyboard map); its palette/typography
give way to this language once approved.

## The language, extracted from the references

| Token | Reference value (eyeballed) | Quoin today (`Theme.swift`) |
|---|---|---|
| App canvas | soft cool gray `#F2F3F5` | flat white/system |
| Content surface | white floating cards, radius ~14, faint wide shadow | flat, no cards |
| Body type | rounded geometric sans (SF Pro Rounded-adjacent), ~17pt, ~1.5 leading | SF Pro, 15pt-ish |
| H1 | very heavy, ~34pt, tight | headingFont ramp |
| Secondary text | muted slate blue-gray `#8A96A8`-ish (subtitles, done-tasks) | secondaryTextColor (gray) |
| Accent | vivid blue ≈ `systemBlue` `#3478F6` | controlAccentColor ✓ close |
| Sidebar selection | full-width rounded PILL in accent, white label | system list selection |
| Sidebar icons | blue folders, gray doc glyphs, unsupported files dimmed | current tree |
| Inline code | light gray rounded chip `#EEF0F3`, mono, dark ink | inlineCodeFill ✓ shape flatter |
| Highlights | saturated pastel bands, generous padding + rounding; multiple hues coexist (lime, lavender) | Highlight.lime etc., tighter |
| Links | accent blue + small pencil glyph suffix (inline edit affordance!) | accent, no glyph |
| Checkboxes | large rounded-square outline; checked = gray fill-check + muted (not struck) label | ☑/☐ text glyphs, strikethrough |
| Tables | full hairline grid, zebra rows, rounded outer corners, roomy cells | header rule + hairlines, no grid/zebra |
| Callout (Note) | left accent bar + barely-tinted card, icon + bold title | tinted rounded box + border |
| Mermaid nodes | rounded boxes, per-state colored strokes w/ tinted fills, curved gray edges, mono labels | MermaidKit default theme (close!) |
| Window chrome | traffic lights inset on card; floating circular/pill toolbar buttons (B I U pill, panel toggles); filename as plain title | standard toolbar |
| TOC / outline | right slide-over card; rows with hairline underlines, chevrons, depth-dimmed | outline sidebar |
| Doc stats | dedicated panel ("word count, paragraph count, reading time at a glance") | status bar |

## Seam map (where each lands)

- **Palette + type ramp:** `Sources/QuoinRender/Theme.swift` — canvas,
  secondary, fills, highlight hues, `bodyFont()`/`headingFont()` (SF
  Rounded via `NSFont.systemFont(...).withDesign(.rounded)`; no bundled
  font unless Clint wants the exact face — licensing).
- **Block chrome:** `QuoinTextView.draw(_:)` cases — radii to ~12,
  callout → left-bar style, `tableRules` → full grid + zebra + rounded
  clip, checkbox glyphs → drawn SF Symbols (needs a decoration or
  attachment swap, not text glyphs).
- **Highlight/inline styling:** `AttributedRenderer` inline attributes +
  `Theme.Highlight` (padding via expanded background… per-glyph
  backgrounds were a shipped bug — pastel BANDS need decoration-drawn
  rounded runs, same machinery as chips).
- **Cards/canvas:** reader background + content inset in
  `MarkdownReaderView` (canvas color) — the floating-card reading
  surface is a bigger compositional change (document column as a card).
- **Sidebar/toolbar/TOC:** `App/macOS` SwiftUI (`MainWindow`,
  `ReaderScreen`, library list styling, format pill already exists and
  matches the reference's B/I/U pill idea).
- **Mermaid theme:** `Theme.diagramTheme` → MermaidKit `DiagramTheme`
  (already close to the reference look; tune fills/strokes).

## Phasing (proposed)

1. **Tokens:** palette + rounded type + spacing in `Theme` — one commit,
   snapshot/digest regeneration, both appearances.
2. **Block chrome:** radii, callout left-bar, table grid/zebra, drawn
   checkboxes, highlight bands.
3. **Chrome:** canvas + card reading surface, sidebar pill selection +
   icons, toolbar pills, TOC slide-over restyle, stats panel.
4. **Polish:** link edit-glyph affordance (pairs with the embed edit
   grammar), diagram theme tuning, dark-mode derivation.

## Shipped with this doc (2026-07-10, second pass)

- **Focus mode** (⌥⌘F, toolbar, View menu): every block but the caret's
  recedes to 30% ink via TextKit rendering attributes — zero reflow,
  zero re-render, follows the caret across blocks, persists via
  `QuoinFocusMode`.
- **Collapsible outline**: heading subtrees fold with chevrons; leaves
  keep alignment; the current section always stays visible even inside
  a collapsed branch (the "you are here" marker never disappears);
  collapsed parents show a trailing ellipsis.
- **Menu-bar repair**: Edit ▸ Undo/Redo are real items again (they had
  been replaced with an empty group — an Edit menu without Undo);
  Format ▸ Bold/Italic/Highlight/Add Link join Edit Source; File ▸
  Export… (⇧⌘E); View ▸ Toggle Focus Mode. The invisible-button
  shortcuts those items duplicated are removed (double-fire risk).
- **Toolbar**: Focus toggle (state-reflecting icon), Export, Outline.

## Brainstorm — beyond focus + collapsible TOC (ranked, with feasibility)

**Writing experience**
1. *Typewriter scrolling* — caret line pinned at a fixed screen height
   while typing; pairs with focus mode. (Cheap: the caret-pin machinery
   already exists — `pinCaretLine` is literally this. High delight.)
2. *Sentence-level focus* — dim to the SENTENCE, not the block, in
   focus mode (iA Writer's signature). (Moderate: sentence segmentation
   via NLTokenizer on the caret paragraph; same rendering-attribute
   engine.)
3. *Session word-count goal* — set a target in the stats popover; a
   hairline progress tick lives in the status bar. (Cheap; stats
   pipeline exists.)
4. *Smart paste* — pasting a URL over selected text makes a link;
   pasting tabular text makes a table. (Moderate; pure SourceEdit.)

**Navigation**
5. *Outline minimap hover-peek* — hovering an outline row shows a tiny
   rendered thumbnail of that section (the preview-panel machinery
   generalizes). (Moderate.)
6. *Breadcrumb section pill* — the status bar's `§ section` becomes a
   clickable path (H1 › H2 › H3) jumping to any ancestor. (Cheap.)
7. *Back/forward navigation* — ⌘[ / ⌘] through the jump history (TOC
   clicks, anchor links, quick open). (Cheap-moderate: a jump stack on
   ReaderScreen.)
8. *Link hover-preview* — hovering an internal anchor link shows the
   target section in a small card (Wikipedia-style). (Moderate.)

**Blocks**
9. *Drag-reorder blocks* — grab a block's gutter handle to move it;
   pure SourceEdit splice + the flip motion system animates. (Harder;
   flagship-grade.)
10. *Block actions gutter* — hover a block's left gutter for a ⋮⋮ handle
    with Copy/Duplicate/Delete/Turn-into. (Moderate.)
11. *Table quick-add* — the reference mockups' add-row/add-column edge
    controls on hover (specced in the original handoff!). (Moderate.)

**Ambient**
12. *Reading progress hairline* along the window top in reader-ish
    documents. (Cheap.)
13. *Recently edited* section in quick open, weighted by recency ×
    frequency. (Cheap.)
14. *Daily note* — ⌘D opens/creates `Journal/2026-07-10.md`. (Cheap,
    opinionated — needs Clint's blessing.)

Suggested first wave after the token pass: 1 (typewriter), 6
(breadcrumb), 7 (back/forward), 3 (word goal) — all cheap, all felt.

## Open questions for Clint (blocking implementation)

1. **Wholesale or optional?** Replace Graphite as THE look, or ship as a
   second theme (Settings already has appearance plumbing)?
2. **Dark mode:** the references are all light. Derive a dark twin of
   the card language, or keep current dark palette until references
   exist?
3. **Code blocks:** references only show inline code (light chip). Keep
   the signature dark `#1E2430` block canvas, or go light-card?
4. **Type:** SF Pro Rounded (free, native, close) vs licensing the exact
   face from the mockups?
5. **Scope check:** the reference sidebar shows dimmed non-md files
   (images) in the tree — adopt showing non-markdown files?

## Risks

- Pastel highlight bands + rounded padding must pass contrast in both
  appearances (the lavender-on-white is borderline for small text).
- Digest/screenshot goldens churn heavily at the token commit — one
  regeneration with rationale, then stable.
- The handoff document remains referenced by CLAUDE.md as canonical —
  update the hierarchy note when phase 1 lands.
