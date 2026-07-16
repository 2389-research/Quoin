# Code hygiene ledger

A standing, prioritized list of decomposition, duplication, and clarity work —
the kind a taste-driven Apple engineer would flag on a read-through. Compiled
2026‑07‑15 from a focused review of the eight largest source files (the render
layer, the AppKit view/coordinator layer, and the core parse/session layer).

**Overall verdict.** This is unusually disciplined, invariant-obsessed code.
Comments genuinely earn their keep — most cite the specific shipped bug the
current shape prevents — and the pure-function extractions and invariant-encoding
types (`BlockRangeIndex`, `CaretHint`, `EditingChrome`, `RevealStylerConfig`,
the self-calibrating fast paths) are exemplary. There is **no** rot in the
fundamentals: zero TODO/FIXME, zero `try!`, zero `print`, 13 force-unwraps and
3 `fatalError` across 17k LOC. The debt is almost entirely **scale and
duplication**: a handful of files have grown into god-objects, and a few
grammars are recognized by two hand-rolled walkers that CLAUDE.md warns *will*
diverge. None of this is urgent; all of it is worth chipping at.

Severity: **H** = structural/risk, **M** = principled cleanup, **L** = polish.

---

## Status (updated 2026‑07‑15)

**Shipped** (each behind `swift test` — 645 green — and a separate commit):

- All dead code (§4): `plainParagraphInlines`, the unreachable
  `renderFrontMatter(editable:false)` branch, the unused `intersectsCard`.
- All comment rot (§3): the two misleading type docs, the spliced
  typedForm/stringScalar and RenderSpliceHint/RenderedDocument docs, the stale
  RevealedFragment parenthetical, the forbidden-set comment.
- All error-handling (§5): audible+traced keystroke-drop instead of silent
  return; guarded `samePosition`; bound `-->`/`panel` instead of force-unwrap;
  documented the memcmp `baseAddress!` invariant.
- Several dedups: `byteDelta`/`makeBlock`-hash (§2), the `caretHint`
  activation helper (4 sites), `YAMLScalar.unescapeDoubleQuotedBody` (§2), the
  `renderSuggestion` extraction (§1 secondary).
- Idiom fixes: `LastFrameReport` enum for the `CGRect??` tri-state; consistent
  private `onConflict`/`onSaveFailure`; the "Fallback" → native-path renames;
  the 11 reveal regexes hoisted to compile-once statics (§6).

**Remaining — the structural tier** (each its own careful commit, guarded by
RevealFidelity / CaretLineAnchor / ProjectorEquivalence):

- §1 god-objects: `updateNSView` (358 lines), `ReaderCoordinator` (5
  subsystems), `AttributedRenderer` (4-way), `Builder`.
- §1 secondary: `convertParagraph`, `toggleTask`, `measureVisibleRuns`,
  `styleLinks`, `spliceChanges` prefix/suffix.
- §2: `rebuild()` fast-path dedup, `forEachYAMLLine` tokenizer, the
  renderer/scanner grammar-agreement test, `styleContainerBody` dedup.
- §6: callback config structs, a real `SeparatorPolicy` type, typed `@objc`
  payloads, `SegmentCursor`, the `isCode` marker attribute, draw magic numbers.

---

## 1. Structural decomposition — the giants (H)

The dominant theme. Four units have absorbed too many responsibilities; each has
clean, already-latent seams to split along.

| Unit | Size | Split along |
| --- | --- | --- |
| `MarkdownReaderView.updateNSView` | **358 lines**, ~18 jobs | (a) `Coordinator.applyProjection(rendered:in:)` for the whole revision-apply block; (b) one `applyX` per generation-fired command (scroll target, search, format, focus, annotation, flash…), driven from an ordered list. |
| `ReaderCoordinator` (`Coordinator`) | **2,691 lines**, ~35 props, 8 subsystems | Extract collaborators it owns and delegates to: `FocusDimmer`, `SearchHighlighter`, `LinkHoverController`, `AnnotationController`, `PreviewPanelManager`. Each already has private state that moves cleanly. |
| `AttributedRenderer` | **2,379 lines**, ~6 jobs | Four-way split: `BlockRenderer`, `InlineRenderer`, `RevealProjector` (reveal + preview-panel + HeldPreview), `IncrementalPatchPlanner`; keep `AttributedRenderer` as the thin composing facade. |
| `MarkdownConverter.Builder` | **~600 lines**, god-object | Extract `FootnoteCollector`, `InlineAssembler` (`assembleInlines`/`assembleCriticInlines`/`spliceInlineMath`), and a stats accumulator; leave `Builder` as the tree walk only. |

Secondary function-level decomposition:
- **M** `AttributedRenderer.renderInline` `.suggestion` case (~60 lines, nested 5-way switch) → extract `renderSuggestion(kind:markRange:attributes:)`.
- **M** `MarkdownConverter.convertParagraph` fans out five responsibilities (TOC, footnote-def, critic, math, plain) → three ordered `[Block]?` helpers.
- **M** `DocumentSession.toggleTask` (~60 lines) → extract the disk re-anchor as `rebasedToggleTarget(...)`.
- **M** `QuoinTextView.measureVisibleRuns` → extract `fullWidthBox(for:in:)` and a `visibleRange(layoutManager:)` helper.
- **M** `MarkdownSourceStyler.styleLinks` (~160 lines, six constructs) → one `applySpanPass(pattern:in:claimed:body:)` owning the compile+guard boilerplate.
- **M** `ReaderCoordinator.spliceChanges` → extract named `commonPrefixLength`/`commonSuffixLength`.

## 2. Duplication & divergence risk (H / M)

The "two recognizers for one grammar WILL diverge" hazard from CLAUDE.md — real
and, in one case, tripled.

- **H** `MarkdownConverter`: `fencedBlockFastPath` and `plainParagraphFastPath` are ~80% identical (block lookup, self-calibrating reparse, hash-uniqueness gate, outline-shift map, stats diff, `QuoinDocument` construction). → Hoist a shared `rebuild(previous:blockIndex:newKind:byteDelta:…)`; each path keeps only its eligibility check.
- **H** `ReviewEndmatter`: three hand-rolled walkers over the same tiny YAML subset in `parse`, `maintenanceEdit`, `resolutionRecordEdit`. → One `forEachYAMLLine` tokenizer driving all three.
- **M** Reveal-vs-parser grammar duplication is currently guarded only by hopeful "must agree with CriticScanner" comments: `AttributedRenderer` re-encodes the CriticMarkup grammar as regexes (205, 217–236), and `MarkdownSourceStyler` re-derives links/images/entities/emphasis by regex parallel to the AST. → Drive off `CriticScanner.scan`/`MathScanner` where possible; otherwise add golden tests pinning byte-for-byte agreement with the parser's inline ranges. **This is the highest-risk latent bug in the review.**
- **M** `unquoteScalar` grammar hand-rolled 3× (`FrontMatterEditing.unquoted`/`quotedItemContent`, `ReviewEndmatter.keyValue`). → Factor one `unquoteScalar(_:)`.
- **M** `ReaderCoordinator`: the activation caret-hint idiom (`embedCaretHint … .map { .source } ?? blockRanges[id].map { .rendered }`) is copy-pasted at 4 sites → `caretHint(forActivationAt:blockID:)`.
- **M** `AttributedRenderer.renderCallout`/`renderBlockQuote` re-implement identical card-range collection + gap partitioning → `styleContainerBody(cardRanges:gapStyling:inset:)`.
- **M** `DocumentSession`: atomic-write-and-bookkeep (`Data.write(.atomic)` → set `selfWriteHash` → clear/set `lastSaveError`) copy-pasted in `saveNow` and `toggleTask` → `writeToDisk(_:)`.
- **L** `MarkdownConverter`: `sliceByteDelta` and `byteDelta` are the same expression computed twice; `contentHash(for:)` and `Builder.makeBlock` reimplement the same identity hash.

## 3. Comment rot — actively misleading (some done)

- ✅ **DONE** `MarkdownReaderView` type doc claimed "the view is read-only and selectable" — it is an editable projection (`isEditable = onEditIntent != nil`). Rewritten.
- ✅ **DONE** `AttributedRenderer` struct doc claimed math/mermaid "render as styled source … QuoinMath/QuoinDiagram can replace them in M2a/M2b" — they typeset natively now (Vinculum/MermaidKit). Rewritten.
- **M** `FrontMatterEditing` 513–528: doc block is spliced — the "typed form parses CLEANLY" lines document `typedForm` (which now has no doc) but sit above `stringScalar`. → Move them down.
- **L** `AttributedRenderer` 643–651: "editable source sits INSIDE the block's fragment (offset … when a preview leads it)" contradicts the `RevealedFragment` invariant (location ALWAYS 0). → Delete the stale parenthetical.
- **L** `AttributedRenderer` 17–25: doc describing `RenderedDocument` sits on `RenderSpliceHint`. → Move it down.
- **L** `MarkdownConverter` (the `forbidden` set): comment justifies only `{`/`}` but the set bans 15 chars. → Rewrite to cover the whole set.

## 4. Dead code (done)

- ✅ **DONE** `MarkdownConverter.plainParagraphInlines` — defined, never called (the abandoned hand-rolled inline synthesis). Deleted.
- ✅ **DONE** `AttributedRenderer.renderFrontMatter(editable:)` — the only caller used the `true` default, so the entire `editable == false` branch (condensed "·"-soup + "Open Review" chip) was unreachable. Collapsed to a direct `renderFrontMatterFields` call; wrapper + param deleted.
- **L** `AttributedRenderer`: `intersectsCard` is defined inside `renderCallout` but only `renderBlockQuote`'s copy is used → remove (subsumed by the §2 dedup).

## 5. Error handling — silent failures (M / L)

- **M** `ReaderCoordinator` ~640: a failed `EditMapping.utf8Range` returns `false`, silently dropping the user's keystroke with no beep or log — the "input vanished" class treated as the worst editor error elsewhere. → `NSSound.beep()` + trace on the nil-mapping path.
- **M** `ReviewEndmatter` 95: `…samePosition(in: source.utf8)!` force-unwrap on the hot detection path, unjustified. → `guard let … else { return nil }` (detection is already nil-tolerant).
- **L** Justify-or-guard the remaining force-unwraps: `ReaderCoordinator` `baseAddress!` (99), `panel!.image` (2210); `AttributedRenderer` `trimmed.range(of: "-->")!` (1232, bind the `if let`).
- **L** `MarkdownSourceStyler`: seven `try? NSRegularExpression(...)` recompile constant patterns **every keystroke** and silently swallow a compile failure. → Hoist to `static let` (compiled once); also a small perf win on the reveal path.

## 6. Type design & idioms (M / L)

- **M** `MarkdownReaderView`: ~45 stored members + a 40-argument positional `init` — call sites are unreadable and grow combinatorially. → Group callbacks into small `Sendable` config structs (`EditingCallbacks`, `ReviewCallbacks`, `FlashConfig`).
- **M** `AttributedRenderer`: separator logic is five scattered methods asserting "THE single SeparatorPolicy derivation" that isn't a type. → Extract a real `SeparatorPolicy` value type (characters + clamp styling + length).
- **M** `AttributedRenderer`: `renderMermaidFallback`/`renderMathBlockFallback` are the PRIMARY native paths — "Fallback" names the exception. → Rename to `renderMermaid`/`renderMathBlock`; reserve "fallback" for the source-card branch.
- **M** `ReaderCoordinator`: `@objc` menu handlers smuggle payloads through `representedObject as? [Any]` positional arrays. → Box each in a tiny typed `@objc` reference type.
- **M** `MarkdownConverter.Builder` rebinds mutable cursor state (`lineIndex`, `baseOffset`) mid-walk, so `absoluteRange` silently depends on call order. → Thread a small `SegmentCursor` value instead.
- **L** `QuoinTextView`: `lastReportedEditingFrame: CGRect??` tri-state → explicit `enum LastFrameReport { case none, some(CGRect?) }`.
- **L** `MarkdownSourceStyler.isCode` infers "inside a code span" by comparing font identity → tag code spans with a marker attribute during the backtick pass.
- **L** `DocumentSession`: `onConflict` is public-settable with a setter while sibling `onSaveFailure` is private-with-setter — inconsistent. → Make both consistent.
- **L** `QuoinTextView.draw(_:)`: per-kind magic numbers (radius 8, dy −5, alpha 0.05…) inline in a 90-line switch → move to `BlockDecoration`/a style table so draw and hit-geometry can't drift.

## 7. Cross-cutting hygiene

- **M** No `SwiftLint` / `swift-format` config exists. The code is already clean enough that a linter would mostly ratify it, but a checked-in config (line length, force-unwrap warnings, file-length soft cap) would catch the god-file growth in §1 automatically and make the discipline enforced rather than cultural.
- **Note** Literate-comment quality is a genuine strength, not a gap — the review repeatedly found comments that explain *why* with measured evidence. The action items in §3 are the few that rotted, not a systemic problem.

---

## Exemplary — do NOT "fix" these

Patterns worth copying, called out so a future cleanup doesn't flatten them:

- **`BlockRangeIndex`** (ReaderCoordinator) — encapsulates a sorted-entries +
  non-decreasing `prefixMaxEnd` invariant, turning two O(blocks) scans into
  binary searches with the tie-break rule enforced in one place.
- **`CaretHint` / `EditingChrome` / `RevealStylerConfig`** — each encodes an
  invariant into a type: rendered-vs-source coordinate space can't be confused;
  border/chip/tooltip/panel/AX geometry derives from one box so they can't
  disagree; one pure derivation feeds both the reveal render and the view-side
  restyle so the old two-bool drift can't recur.
- **The self-calibrating fast paths** (`MarkdownConverter`) — re-parsing the
  edited slice with the *real* parser and rejecting on any structural surprise,
  instead of hand-imitating cmark.
- **`DocumentSession`'s data-integrity discipline** — every dangerous path
  (detached / conflict / stale `contentRevision`) is guarded and annotated with
  the specific bug it prevents.
- **The pure static helpers** (`ProjectionApplication`, `changedOldRange`,
  `collapsedSelection`, `listIndentEdit`, `shiftAndReassignIDs`) — side-effect
  free, testable, lifted cleanly out of stateful types.
