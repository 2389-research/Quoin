# Phase 1 — Read-Only Per-Block View Recycler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render a document as a virtualized, view-recycling `NSTableView` of per-block cells — each drawing ONE block via the existing `AttributedRenderer` + its decorations — behind a feature flag, still fully read-only, with faithful visual parity to today's projection reader. The projection reader stays the default until the flag is flipped.

**Architecture:** A `BlockRenderCell` (`NSView`) owns a small TextKit-2 stack, renders `renderReadFragment(block)`, and draws the block's `BlockDecoration` chrome in cell-local bounds (the decoration-draw algorithm ported from `QuoinTextView`, which this rearchitecture will eventually delete). A `BlockRecyclerReaderView` (`NSViewRepresentable`) hosts a view-based `NSTableView` whose rows are those cells, with deterministic heights from `AttributedRenderer.measuredHeight` (Phase 0). `ReaderScreen` chooses it over `MarkdownReaderView` when `@AppStorage("QuoinEditorRecycler")` is on. Everything new lives in `QuoinEditorKit`.

**Tech Stack:** Swift 5 language mode (QuoinEditorKit), AppKit view-based `NSTableView`, TextKit 2, SwiftUI `@AppStorage` flag, XCTest offscreen-window tests. Spec: `docs/superpowers/specs/2026-08-11-editable-islands-design.md` §3, §10 (Phase 1), §13b.

## Global Constraints

- Platforms macOS 14+. New view code is AppKit, guard `#if canImport(AppKit)`. QuoinEditorKit is **Swift 5 language mode** (already set in Phase 0); it links `QuoinCore` + `QuoinRender`.
- **READ-ONLY.** No editing, no caret, no activation in Phase 1. The `.editingFrame` decoration kind is editing-only and is NOT drawn here.
- **Faithful visual parity** with today's projection reader is the acceptance bar: same content width/insets, same decoration geometry, same effective inter-block spacing. Headless geometry tests pin the boxes; final visual confirmation is the user flipping the flag.
- **Flag-gated, default OFF.** `@AppStorage("QuoinEditorRecycler")` (defaults `false`); `-QuoinEditorRecycler YES` at launch flips it (same mechanism as `-QuoinForceDarkMode`, `SettingsView.swift:39`). Flag off ⇒ existing reader, byte-for-byte unchanged behavior.
- Reuse the KEEP renderer: `renderReadFragment(_ block: Block, document: QuoinDocument) -> (fragment: NSAttributedString, hasPendingContent: Bool)` (`AttributedRenderer.swift:479`) per cell; `measuredHeight(of:in:width:)` / `lineTops(of:in:width:)` (`AttributedRenderer+Metrics.swift:9,24`) for row heights.
- Async-height block types (image via `AsyncImageStore`/`FittingImageTextAttachment`, mermaid diagram, math) have provisional heights until content decodes — a row's height MUST be re-queried on re-render / when `hasPendingContent` was true, never cached-once (spec §13b carry-forward #1).
- **Do NOT delete the reveal blank-line clamps** (`compressInteriorBlankLines`/`clampTrailingNewlinePhantom`) this phase. The spec's Phase-1 line "delete inactive-content blank-line clamp hacks" is DEFERRED: those clamps live on the reveal/projection path that the still-default projection reader uses; the recycler consumes `renderReadFragment` (the plain reading render, no clamps) so it needs nothing deleted, and removing them now would break the default reader. They are deleted in Phase 3 when the projection reader is retired.
- No new third-party dependencies. Revert `Package.resolved` before each commit (`git checkout Package.resolved`). Commit + push to `main` after each task with trailers:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_013hf6D4MU3MgzEXSY3qZXEv`.
- Package tests: `swift test` (UNPIPED). The full existing suite must stay green (Phase 1 adds isolated new code + one flag branch; flag OFF changes nothing). App build: `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build`.

## Reference anchors (verified)

- Reader host seam: `App/macOS/Sources/ReaderScreen.swift:205` (the `ZStack` constructing `MarkdownReaderView(rendered: model.rendered, theme: theme, …)`). `model.document.blocks` is the block list; `model.rendered` is `RenderedDocument { attributed; blockRanges: [BlockID: NSRange]; activeBlockID; revision: Int }` (`AttributedRenderer.swift:55`).
- Decoration model: `BlockDecoration` + `BlockDecoration.Kind` (`Sources/QuoinRender/BlockDecoration.swift:19,21`: `.codeCanvas(fill:)`, `.callout(color:)`, `.quoteRule(color:)`, `.diagramFrame(color:)`, `.chip(fill:)`, `.tableRules(width:header:body:)`, `.editingFrame(accent:)`), `BlockDecoration.inset(by:)` (`:58`). The renderer tags char ranges with `QuoinAttribute.blockDecoration`.
- Decoration DRAW to port: `QuoinTextView.measureVisibleRuns()` (`Sources/QuoinRender/AppKit/QuoinTextView.swift:623-699`, incl. the full-width reset at `:677-689` using `container.size.width`) and `draw(_ run:)` (`:731-820`, geometry bleeds `dy:-2/-4/-5`, quote rule at `box.minX - 14`, per-row table rules). `decorationRuns` scan at `:174`.
- Offscreen test pattern: `Tests/QuoinRenderTests/DecorationGeometryTests.swift:15-53` (`makeStack` + borderless `NSWindow` + `ensureLayout`/`layoutViewport` + assert on measured boxes). Async height: `Tests/QuoinRenderTests/AsyncImageRerenderTests.swift`. AX: `BlockAccessibility.swift:23`, `StructureRotor.swift:48`.
- Flag precedent: `@AppStorage` throughout `ReaderScreen.swift:38-45`; launch-arg `UserDefaults` at `SettingsView.swift:39` / `MainWindow.swift:627`.

## File Structure

- `Sources/QuoinEditorKit/BlockRenderCell.swift` — the per-block cell (text + decoration draw), read-only.
- `Sources/QuoinEditorKit/DecorationDraw.swift` — the ported decoration measure/draw, cell-local (kept separate so it's a focused unit).
- `Sources/QuoinEditorKit/BlockRowMetrics.swift` — row height = text height + decoration padding + separator spacing; the height contract.
- `Sources/QuoinEditorKit/BlockRecyclerView.swift` — the view-based `NSTableView` host + data source + recycling + scroll/top-block.
- `Sources/QuoinEditorKit/BlockRecyclerReaderView.swift` — the `NSViewRepresentable` wrapper consumed by `ReaderScreen`.
- `Sources/QuoinEditorKit/BlockRecyclerAccessibility.swift` — per-row AX + table-level rotor.
- `App/macOS/Sources/ReaderScreen.swift` (modify, ~:205) + `App/macOS/project.yml` (add QuoinEditorKit dep) — Task 8 only.
- Tests under `Tests/QuoinEditorKitTests/`.

Task 3 (spanning/bleeding decoration parity) is the single hardest — isolate it; its risk must not leak into the recycler/wiring tasks.

---

### Task 1: `BlockRenderCell` — single-block text render + height (no decorations yet)

**Files:**
- Create: `Sources/QuoinEditorKit/BlockRenderCell.swift`
- Test: `Tests/QuoinEditorKitTests/BlockRenderCellTests.swift`

**Interfaces:**
- Consumes: `AttributedRenderer.renderReadFragment(_:document:)`, `measuredHeight(of:in:width:)`; `Block`, `QuoinDocument` (QuoinCore).
- Produces:
  ```swift
  @MainActor public final class BlockRenderCell: NSView {
      public init()
      // Configure to draw `block` from `document` at content `width`; idempotent, reusable across rows.
      public func configure(block: Block, document: QuoinDocument, renderer: AttributedRenderer, theme: Theme, width: CGFloat)
      public private(set) var blockID: BlockID?      // which block it currently shows (recycling identity)
      public var fittingHeightForConfiguredWidth: CGFloat { get }   // == renderer.measuredHeight(of:in:width:)
  }
  ```
- Phase-1 note: this task draws only the TEXT (the block's rendered attributed string) in a cell-local TextKit-2 stack, sized to `width`. Decorations come in Tasks 2–3; the final row height (with padding) comes in Task 4.

- [ ] **Step 1: Write the failing test** (offscreen, mirror `DecorationGeometryTests.makeStack`)

```swift
#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

@MainActor
final class BlockRenderCellTests: XCTestCase {
    func testCellShowsBlockTextAndHeightMatchesMetric() {
        let doc = MarkdownConverter.parse("# A heading\n\nA body paragraph that is reasonably long.")
        let renderer = AttributedRenderer()
        let theme = Theme.graphite     // confirm the real default Theme value/name in Theme.swift
        let width: CGFloat = 600
        let cell = BlockRenderCell()
        cell.configure(block: doc.blocks[0], document: doc, renderer: renderer, theme: theme, width: width)
        XCTAssertEqual(cell.blockID, doc.blocks[0].id)
        XCTAssertEqual(cell.fittingHeightForConfiguredWidth,
                       renderer.measuredHeight(of: doc.blocks[0], in: doc, width: width), accuracy: 0.5)
        // Reconfiguring for a different block updates identity (recycling).
        cell.configure(block: doc.blocks[1], document: doc, renderer: renderer, theme: theme, width: width)
        XCTAssertEqual(cell.blockID, doc.blocks[1].id)
    }
}
#endif
```

- [ ] **Step 2: Run — verify it fails.** `swift test --filter BlockRenderCellTests` → `BlockRenderCell` undefined.

- [ ] **Step 3: Implement** — a layer-backed `NSView` holding an `NSTextContentStorage`/`NSTextLayoutManager`/`NSTextContainer` (container width = configured `width`). `configure` sets the storage to `renderer.renderReadFragment(block, document: document).fragment`, records `blockID`, `ensureLayout`, and draws the text in `draw(_:)` (via the layout manager's text-layout-fragment enumeration, or an `NSTextView` subview — prefer the raw layout-manager draw for control, following how the renderer's own measurement lays out). `fittingHeightForConfiguredWidth` returns `renderer.measuredHeight(...)` (single source of truth — do NOT recompute a second way). Keep decoration drawing OUT of this task.

  NOTE: confirm the real default `Theme` symbol (the test uses `Theme.graphite` — check `Sources/QuoinRender/Theme.swift` for the actual default constructor/name and use it verbatim). `renderReadFragment` and `measuredHeight` are `public`.

- [ ] **Step 4: Run — verify it passes.** `swift test --filter BlockRenderCellTests` → PASS.

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/BlockRenderCell.swift Tests/QuoinEditorKitTests/BlockRenderCellTests.swift
git commit -m "Phase 1: BlockRenderCell — single-block text render + metric-matched height"
git push origin main
```

---

### Task 2: Decoration parity — per-block kinds (code canvas, diagram frame, chip, table rules)

**Files:**
- Create: `Sources/QuoinEditorKit/DecorationDraw.swift`
- Modify: `Sources/QuoinEditorKit/BlockRenderCell.swift` (call the decoration draw in `draw(_:)`)
- Test: `Tests/QuoinEditorKitTests/DecorationParityTests.swift`

**Interfaces:**
- Consumes: `BlockDecoration` / `QuoinAttribute.blockDecoration` (QuoinRender — CONFIRM these are `public`; if `BlockDecoration` or the `QuoinAttribute.blockDecoration` key is `internal`, make it `public` in QuoinRender as part of this task, smallest change, and note it — the cell must read the renderer's decoration output).
- Produces:
  ```swift
  // Pure geometry: scan the cell's laid-out fragments for blockDecoration runs and
  // return the boxes to draw (cell-local coords; full-width kinds use `contentWidth`).
  @MainActor public enum DecorationDraw {
      public struct Box { public let kind: BlockDecoration.Kind; public let rect: CGRect; public let rowFrames: [CGRect] }
      public static func boxes(in layoutManager: NSTextLayoutManager, contentStorage: NSTextContentStorage,
                               contentWidth: CGFloat, leadingInset: CGFloat) -> [Box]
      public static func draw(_ boxes: [Box], in ctx: CGContext, theme: Theme)   // per-kind CoreGraphics
  }
  ```
- This task ports the PER-BLOCK-LOCAL kinds only: `.codeCanvas`, `.diagramFrame`, `.chip`, `.tableRules`. `.callout`, `.quoteRule`, and the negative-inset bleed vs separators are Task 3.

- [ ] **Step 1: Write the failing test** — geometry parity per kind, mirroring `DecorationGeometryTests`. For a fenced code block, assert exactly one `.codeCanvas` box whose rect spans the cell content width (minus leading inset) and covers the code fragments' vertical extent; for a table, assert `.tableRules` rowFrames count == the table's row count. Use a cell configured at a fixed width; read `DecorationDraw.boxes(...)`.

```swift
#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

@MainActor
final class DecorationParityTests: XCTestCase {
    private func boxes(for source: String, width: CGFloat = 600) -> [DecorationDraw.Box] {
        let doc = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        let cell = BlockRenderCell()
        cell.configure(block: doc.blocks[0], document: doc, renderer: renderer, theme: Theme.graphite, width: width)
        return cell.decorationBoxesForTest()   // test hook exposing DecorationDraw.boxes(...) for the configured cell
    }
    func testCodeBlockHasOneFullWidthCanvas() {
        let bs = boxes(for: "```swift\nlet x = 1\nlet y = 2\n```")
        let canvases = bs.filter { if case .codeCanvas = $0.kind { return true }; return false }
        XCTAssertEqual(canvases.count, 1)
        XCTAssertGreaterThan(canvases[0].rect.width, 400)     // spans the content column, not one glyph
        XCTAssertGreaterThan(canvases[0].rect.height, 20)     // covers both code lines
    }
    func testTableHasPerRowRules() {
        let bs = boxes(for: "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |")
        let rules = bs.filter { if case .tableRules = $0.kind { return true }; return false }
        XCTAssertEqual(rules.count, 1)
        XCTAssertGreaterThanOrEqual(rules[0].rowFrames.count, 3)   // header + 2 body rows
    }
}
#endif
```

- [ ] **Step 2: Run — verify it fails.** `swift test --filter DecorationParityTests` → undefined `DecorationDraw` / `decorationBoxesForTest`.

- [ ] **Step 3: Implement** — port the run-measuring logic from `QuoinTextView.measureVisibleRuns()` (`QuoinTextView.swift:623-699`): scan `QuoinAttribute.blockDecoration` runs in the cell's storage, enumerate each run's text-layout-fragment frames, build the union box, and for full-width kinds reset `origin.x = leadingInset`, `width = contentWidth - leadingInset` (mirroring `:677-689`, with `contentWidth` = the cell's configured width). Port the per-kind CoreGraphics from `draw(_ run:)` (`:731-820`) for the FOUR local kinds; keep `.callout`/`.quoteRule`/`.editingFrame` as no-ops here (Task 3 / not-in-Phase-1). Wire `BlockRenderCell.draw(_:)` to call `DecorationDraw.draw(DecorationDraw.boxes(...), …)` BEHIND the text (draw decorations first, then text). Add `decorationBoxesForTest()` as an `#if DEBUG`/internal test hook.

  NOTE: `Theme` supplies the decoration colors/line widths today via `BlockDecoration` payloads (the kinds already carry `fill:`/`color:`/`width:`), so the draw reads them off the kind, not off Theme globals — confirm against `draw(_ run:)`.

- [ ] **Step 4: Run — verify it passes.** `swift test --filter DecorationParityTests` → PASS. Also `swift test --filter BlockRenderCellTests` still green.

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/DecorationDraw.swift Sources/QuoinEditorKit/BlockRenderCell.swift Tests/QuoinEditorKitTests/DecorationParityTests.swift
# plus any QuoinRender visibility change if BlockDecoration/QuoinAttribute needed making public
git commit -m "Phase 1: per-block decoration parity (code canvas, diagram frame, chip, table rules)"
git push origin main
```

---

### Task 3: ⚠ Decoration parity — spanning/bleeding chrome (callout, quote gutter, bleed vs separators)

**Files:**
- Modify: `Sources/QuoinEditorKit/DecorationDraw.swift`, `Sources/QuoinEditorKit/BlockRenderCell.swift`
- Test: `Tests/QuoinEditorKitTests/DecorationBleedTests.swift`

**Interfaces:**
- Consumes/Produces: extends `DecorationDraw` to handle `.callout(color:)` (MULTIPLE runs in one cell + nested `BlockDecoration.inset(by:)`), `.quoteRule(color:)` (drawn at `box.minX - 14`, in a left gutter the cell must reserve/not-clip), and the negative-inset vertical bleed (`dy:-2/-4/-5`) that today draws into the inter-block separator gap.

- THE HARD PART, stated: NSTableView cells **clip to bounds**. Today `QuoinTextView.draw(_ run:)` deliberately draws OUTSIDE a block's fragment box: code canvas `insetBy(dy:-2)`, callout `dy:-5`, diagram `dy:-4` (bleed into the gap), and quote rule at `minX - 14` (into the left gutter). Two coordinated fixes: (a) the cell reserves symmetric vertical padding (so the bleed has room inside bounds) and a left gutter (so the quote rule is inside bounds) — this padding is part of the Task-4 row-height contract; (b) `BlockRenderCell` sets `clipsToBounds = false` OR insets its text draw so chrome stays visible. Callout: scan ALL blockDecoration runs in the cell (a callout applies decoration to its non-card gap ranges + nested child cards at `inset(by: 12)`), not just the first.

- [ ] **Step 1: Write the failing tests**

```swift
#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

@MainActor
final class DecorationBleedTests: XCTestCase {
    private func boxes(_ src: String, width: CGFloat = 600) -> [DecorationDraw.Box] {
        let doc = MarkdownConverter.parse(src)
        let cell = BlockRenderCell()
        cell.configure(block: doc.blocks[0], document: doc, renderer: AttributedRenderer(), theme: Theme.graphite, width: width)
        return cell.decorationBoxesForTest()
    }
    func testQuoteRuleIsInLeftGutter() {
        let bs = boxes("> a quoted line\n> second line")
        let rules = bs.filter { if case .quoteRule = $0.kind { return true }; return false }
        XCTAssertEqual(rules.count, 1)
        // The rule sits in the reserved left gutter (x near the leading inset, a thin 3pt bar), not at the text column.
        XCTAssertLessThan(rules[0].rect.width, 6)
    }
    func testCalloutHasBoxAndSurvivesInCellBounds() {
        // Callout syntax per Quoin (confirm the real callout markup in the parser/tests).
        let bs = boxes("> [!note]\n> callout body")
        let callouts = bs.filter { if case .callout = $0.kind { return true }; return false }
        XCTAssertGreaterThanOrEqual(callouts.count, 1)
        // The callout box top must be >= 0 within the padded cell (bleed fits inside bounds, not clipped negative).
        XCTAssertGreaterThanOrEqual(callouts[0].rect.minY, 0)
    }
    func testCellDoesNotClipDecorationBleed() {
        let doc = MarkdownConverter.parse("```\ncode\n```")
        let cell = BlockRenderCell()
        cell.configure(block: doc.blocks[0], document: doc, renderer: AttributedRenderer(), theme: Theme.graphite, width: 600)
        XCTAssertFalse(cell.clipsDecorationForTest, "cell must not clip the negative-inset decoration bleed")
    }
}
#endif
```

- [ ] **Step 2: Run — verify it fails.** `swift test --filter DecorationBleedTests` → the callout/quote branches are no-ops from Task 2, and the clip flag isn't set.

- [ ] **Step 3: Implement** — port `.callout` (multi-run + `inset(by:)`) and `.quoteRule` (`minX - 14` gutter) from `draw(_ run:)` (`:751`, `:766`); reserve a left gutter + symmetric vertical padding in the cell content geometry (the exact padding constants become the Task-4 height contract — define them as named constants here, e.g. `DecorationDraw.verticalBleed` / `.leftGutter`, and Task 4 consumes them); set `BlockRenderCell` to not clip the bleed (`clipsToBounds = false` on the draw layer, or draw into an oversized layer) and expose `clipsDecorationForTest`. Verify the union-box math handles multiple runs per cell.

- [ ] **Step 4: Run — verify it passes.** `swift test --filter DecorationBleedTests` and the Task-2 `DecorationParityTests` and `BlockRenderCellTests` all green.

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/DecorationDraw.swift Sources/QuoinEditorKit/BlockRenderCell.swift Tests/QuoinEditorKitTests/DecorationBleedTests.swift
git commit -m "Phase 1: spanning decoration parity (callout, quote gutter, bleed vs cell clipping)"
git push origin main
```

---

### Task 4: Row-height contract (text + decoration padding + separator spacing)

**Files:**
- Create: `Sources/QuoinEditorKit/BlockRowMetrics.swift`
- Test: `Tests/QuoinEditorKitTests/BlockRowMetricsTests.swift`

**Interfaces:**
- Consumes: `measuredHeight`, `DecorationDraw.verticalBleed`/`.leftGutter`, `separator` spacing.
- Produces:
  ```swift
  @MainActor public enum BlockRowMetrics {
      // Deterministic row height a cell will draw at: text height + decoration vertical padding + the
      // inter-block spacing this block contributes (kind-pair dependent, from the renderer's separator).
      public static func rowHeight(for block: Block, at index: Int, in document: QuoinDocument,
                                   renderer: AttributedRenderer, theme: Theme, width: CGFloat) -> CGFloat
  }
  ```
- WHY: `measuredHeight` is text-fragment height ONLY (spec §13b #1). Row height must add the decoration bleed padding (Task 3 constants) and the inter-block spacing that the monolith expressed as `blockSeparator(after:before:)` (`AttributedRenderer.swift:830`) so the recycler's total document height ≈ the projection reader's.

- [ ] **Step 1: Write the failing test**

```swift
#if canImport(AppKit)
import XCTest
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

@MainActor
final class BlockRowMetricsTests: XCTestCase {
    func testRowHeightExceedsBareTextHeight() {
        let doc = MarkdownConverter.parse("```\ncode\n```\n\nplain paragraph")
        let r = AttributedRenderer()
        let text = r.measuredHeight(of: doc.blocks[0], in: doc, width: 600)
        let row = BlockRowMetrics.rowHeight(for: doc.blocks[0], at: 0, in: doc, renderer: r, theme: Theme.graphite, width: 600)
        XCTAssertGreaterThanOrEqual(row, text, "row includes decoration padding + separator spacing")
    }
    func testSumOfRowHeightsApproxDocumentHeight() {
        let doc = MarkdownConverter.parse("# H\n\nOne.\n\nTwo.\n\nThree.")
        let r = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let full = r.render(doc, cache: &cache)                 // the monolith projection
        let docHeight = measureAttributedHeight(full.attributed, width: 600)   // reuse the RevealFidelity measure pattern
        let sum = doc.blocks.enumerated().reduce(CGFloat.zero) { acc, e in
            acc + BlockRowMetrics.rowHeight(for: e.element, at: e.offset, in: doc, renderer: r, theme: Theme.graphite, width: 600)
        }
        XCTAssertEqual(sum, docHeight, accuracy: max(8, docHeight * 0.05))   // within ~5% / 8pt
    }
    // helper: copy the TextKit-2 measure from RevealFidelityTests.measureHeight
    private func measureAttributedHeight(_ a: NSAttributedString, width: CGFloat) -> CGFloat { /* per brief */ 0 }
}
#endif
```

- [ ] **Step 2: Run — verify it fails.** Undefined `BlockRowMetrics`; the sum-vs-doc test fails until spacing is modeled.

- [ ] **Step 3: Implement** — `rowHeight = measuredHeight + 2*DecorationDraw.verticalBleed(for: block.kind) + separatorContribution(after: block.kind, before: nextKind)`. Derive `separatorContribution` from the existing `separator(after:before:revealedSlice: nil)` / `blockSeparator` height (measure it once via the same TextKit pass, or read its known paragraphSpacing). Fill in `measureAttributedHeight` by copying `RevealFidelityTests.measureHeight`. Tune constants until `testSumOfRowHeightsApproxDocumentHeight` passes within tolerance.

- [ ] **Step 4: Run — verify it passes.** `swift test --filter BlockRowMetricsTests` → PASS.

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/BlockRowMetrics.swift Tests/QuoinEditorKitTests/BlockRowMetricsTests.swift
git commit -m "Phase 1: row-height contract (text + decoration padding + separator spacing)"
git push origin main
```

---

### Task 5: Async / dynamic-height rows (images, diagrams, math)

**Files:**
- Modify: `Sources/QuoinEditorKit/BlockRenderCell.swift`, `Sources/QuoinEditorKit/BlockRowMetrics.swift`
- Test: `Tests/QuoinEditorKitTests/AsyncRowHeightTests.swift`

**Interfaces:**
- Consumes: `renderReadFragment(...).hasPendingContent` (`AttributedRenderer.swift:479`), the async re-render signal used by `ReaderModel.rerenderAsync` (`ReaderModel.swift:504`) / `AsyncImageStore.onReady`.
- Produces: `BlockRenderCell.hasPendingContent: Bool` (surfaced from configure); a way for the recycler (Task 6) to learn a row needs its height re-queried once content decodes — via a callback `var onContentSettled: ((BlockID) -> Void)?` fired when a previously-pending cell's content becomes available.

- [ ] **Step 1: Write the failing test** — mirror `AsyncImageRerenderTests`: configure a cell for an image/diagram block; assert `hasPendingContent == true` initially and that `rowHeight` for such a block is treated as provisional (a documented sentinel or the current placeholder height), and that when the underlying store reports ready, `onContentSettled(blockID)` fires. (Use the existing async fixtures; if driving real async decode is heavy, assert the pending flag + the callback wiring deterministically.)

- [ ] **Step 2: Run — verify it fails.**

- [ ] **Step 3: Implement** — surface `hasPendingContent`; wire the cell to observe the same readiness signal the monolith uses (`AsyncImageStore.image(at:onReady:)` / the re-render path) and fire `onContentSettled`. `BlockRowMetrics.rowHeight` returns the current (possibly placeholder) height for pending blocks and is re-queried by the recycler on settle (Task 6 invalidates the row). Do NOT cache a pending height as final.

- [ ] **Step 4: Run — verify it passes.**

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/BlockRenderCell.swift Sources/QuoinEditorKit/BlockRowMetrics.swift Tests/QuoinEditorKitTests/AsyncRowHeightTests.swift
git commit -m "Phase 1: async/dynamic-height rows (images, diagrams, math) — provisional height + settle callback"
git push origin main
```

---

### Task 6: `BlockRecyclerView` — the view-based NSTableView host

**Files:**
- Create: `Sources/QuoinEditorKit/BlockRecyclerView.swift`
- Test: `Tests/QuoinEditorKitTests/BlockRecyclerViewTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor public final class BlockRecyclerView: NSView {
      public init(renderer: AttributedRenderer, theme: Theme)
      public func setDocument(_ document: QuoinDocument, contentWidth: CGFloat)   // reloads rows
      public var onTopBlockChange: ((BlockID) -> Void)?    // report the top-most visible block (for the outline sync)
      public func scroll(to blockID: BlockID)              // outline-click target
      public var visibleCellCount: Int { get }             // for the recycling test
  }
  ```
  Internally: an `NSScrollView` + view-based `NSTableView` (one column), `numberOfRows == document.blocks.count`, `heightOfRow` from `BlockRowMetrics`, `viewFor` dequeues + `configure`s a reused `BlockRenderCell`, and Task-5's `onContentSettled` triggers `noteHeightOfRows(withIndexesChanged:)` for that row.

- [ ] **Step 1: Write the failing test** (offscreen window, `DecorationGeometryTests` recipe)

```swift
#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

@MainActor
final class BlockRecyclerViewTests: XCTestCase {
    func testRowCountAndBoundedRecycling() {
        // 400 short blocks so many rows scroll through a small viewport.
        let src = (0..<400).map { "Paragraph number \($0)." }.joined(separator: "\n\n")
        let doc = MarkdownConverter.parse(src)
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme.graphite)
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:640,height:480), styleMask:[.borderless], backing:.buffered, defer:false)
        window.contentView = v; window.makeKeyAndOrderFront(nil)
        v.frame = NSRect(x:0,y:0,width:640,height:480)
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()
        XCTAssertEqual(v.numberOfRowsForTest, 400)
        // Scroll to the bottom; live cell count stays bounded (visible + reuse buffer), NOT 400.
        v.scroll(to: doc.blocks[399].id); v.layoutSubtreeIfNeeded()
        XCTAssertLessThan(v.visibleCellCount, 60, "recycling must keep live cells bounded, not one-per-block")
    }
    func testTopBlockReported() {
        let doc = MarkdownConverter.parse((0..<50).map { "P\($0)." }.joined(separator: "\n\n"))
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme.graphite)
        var top: BlockID?
        v.onTopBlockChange = { top = $0 }
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:640,height:400), styleMask:[.borderless], backing:.buffered, defer:false)
        window.contentView = v; window.makeKeyAndOrderFront(nil); v.frame = window.contentLayoutRect
        v.setDocument(doc, contentWidth: 600); v.layoutSubtreeIfNeeded()
        v.scroll(to: doc.blocks[20].id); v.layoutSubtreeIfNeeded()
        XCTAssertNotNil(top)
    }
}
#endif
```

- [ ] **Step 2: Run — verify it fails.** Undefined `BlockRecyclerView` / test hooks.

- [ ] **Step 3: Implement** — the `NSScrollView` + view-based `NSTableView` with a single column, `numberOfRows`/`heightOfRow`/`viewFor` (dequeue by a reuse identifier + `configure`), `scroll(to:)` via `scrollRowToVisible(row(for: blockID))`, and `onTopBlockChange` from a bounds-change observer mapping the top visible row → its blockID. Wire Task-5 settle → `noteHeightOfRows`. Add `numberOfRowsForTest`/`visibleCellCount` test hooks. Confirm `viewFor` actually recycles (bounded live cells) exactly as the Phase-0.5 spike proved the substrate does.

- [ ] **Step 4: Run — verify it passes.**

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/BlockRecyclerView.swift Tests/QuoinEditorKitTests/BlockRecyclerViewTests.swift
git commit -m "Phase 1: BlockRecyclerView — view-based NSTableView host with bounded recycling + top-block reporting"
git push origin main
```

---

### Task 7: Per-cell accessibility + table-level rotor

**Files:**
- Create: `Sources/QuoinEditorKit/BlockRecyclerAccessibility.swift`
- Modify: `Sources/QuoinEditorKit/BlockRenderCell.swift`, `Sources/QuoinEditorKit/BlockRecyclerView.swift`
- Test: `Tests/QuoinEditorKitTests/BlockRecyclerAccessibilityTests.swift`

**Interfaces:**
- Consumes: `BlockAccessibility` (`BlockAccessibility.swift:23`), `QuoinAttribute.blockAccessibilityLabel`/`headingLevel` (baked into fragments), `StructureRotor.result(…)` (`StructureRotor.swift:48`).
- Produces: each `BlockRenderCell` exposes its block's AX (role/label/heading level) read from its fragment attributes; `BlockRecyclerView` exposes the two structure rotors (headings/blocks) computed at table level over `document.blocks`.

- [ ] **Step 1: Write the failing test** — mirror `BlockAccessibilityTests`/`StructureRotorTests`: assert a heading cell reports its heading level + label via `BlockAccessibility`; assert the recycler's heading rotor lists the document's headings in order. (Read the cell's `accessibilityLabel()`/custom AX; call the recycler's rotor result.)

- [ ] **Step 2: Run — verify it fails.**

- [ ] **Step 3: Implement** — cell reads `blockAccessibilityLabel`/`headingLevel` from its configured fragment and sets AX role/label (heading cells → heading role + level). Recycler builds the rotors from `document.blocks` via `StructureRotor.result`. (The future "Edit" AX action is Phase 2 — do NOT add editing hooks here; a `// Phase 2:` marker where the action will attach is fine.)

- [ ] **Step 4: Run — verify it passes.**

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/BlockRecyclerAccessibility.swift Sources/QuoinEditorKit/BlockRenderCell.swift Sources/QuoinEditorKit/BlockRecyclerView.swift Tests/QuoinEditorKitTests/BlockRecyclerAccessibilityTests.swift
git commit -m "Phase 1: per-cell accessibility + table-level structure rotors"
git push origin main
```

---

### Task 8: App wiring behind `QuoinEditorRecycler` (LAST)

**Files:**
- Create: `Sources/QuoinEditorKit/BlockRecyclerReaderView.swift` (the `NSViewRepresentable`)
- Modify: `App/macOS/project.yml` (add `QuoinEditorKit` product to the app target deps), `App/macOS/Sources/ReaderScreen.swift` (~:205 seam)
- Test: `Tests/QuoinEditorKitTests/BlockRecyclerReaderViewTests.swift` + manual flag verification

**Interfaces:**
- Produces:
  ```swift
  public struct BlockRecyclerReaderView: NSViewRepresentable {
      public init(document: QuoinDocument, rendered: RenderedDocument, theme: Theme,
                  scrollTarget: BlockID?, onTopBlockChange: ((BlockID) -> Void)?, searchQuery: String?)
      // makeNSView → BlockRecyclerView.setDocument(...); updateNSView → re-setDocument on document/revision change + scroll(to: scrollTarget)
  }
  ```

- [ ] **Step 1: Write the failing test** — a lightweight `NSViewRepresentable` smoke test (make coordinator/NSView, feed a document, assert the hosted `BlockRecyclerView` has the right row count). Full app behavior is verified manually via the flag.

- [ ] **Step 2: Run — verify it fails.**

- [ ] **Step 3: Implement** — the representable wrapping `BlockRecyclerView`; add `QuoinEditorKit` to the app target's package products in `App/macOS/project.yml` (alongside `QuoinCore`/`QuoinRender`); in `ReaderScreen.swift` add `@AppStorage("QuoinEditorRecycler") private var useRecycler = false` and branch the `ZStack` at `:205`: `if useRecycler { BlockRecyclerReaderView(document: model.document, rendered: model.rendered, theme: theme, scrollTarget: …, onTopBlockChange: …, searchQuery: …) } else { MarkdownReaderView(...) /* unchanged */ }`. Flag OFF ⇒ existing path untouched.

- [ ] **Step 4: Run — verify it passes + full suite + app build**

Run: `swift test` (UNPIPED, full suite green). Then `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build`.

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/BlockRecyclerReaderView.swift App/macOS/project.yml App/macOS/Sources/ReaderScreen.swift Tests/QuoinEditorKitTests/BlockRecyclerReaderViewTests.swift
git commit -m "Phase 1: wire the block recycler behind -QuoinEditorRecycler (default off)"
git push origin main
```

---

## Final verification

- [ ] `swift test` — full suite green incl. all new `QuoinEditorKitTests`; NO existing test changed; flag OFF ⇒ existing reader behavior unchanged.
- [ ] App builds; launch with `-QuoinEditorRecycler YES` renders the recycler (manual: the user flips the flag and eyeballs **visual parity** — code canvases, callouts, quote rules, tables, headings, spacing match the projection reader; scrolling a large doc is smooth; the outline/top-block sync works). Judge zoomed, not from a downsampled screenshot (CLAUDE.md).
- [ ] `Package.resolved` unchanged (Sparkle pin not committed).
- [ ] Confirm recycling stays bounded on a real large document (the `Quoin UX Test.md` kitchen-sink fixture is a good manual check).

## Notes for the next phase

Phase 2 promotes exactly one cell to a `BlockEditorCell` hosting a real editable `NSTextView` (the island), repoints the Phase-0 `EditorTestHarness` at it, and adds the swap choreography — resolving the spec §13b carry-forwards (decoration chrome at the cell layer is now handled here; the `move()`-ticks-revision decision; the caret-range mapping). The read-only recycler from this phase becomes the substrate the island lives in.
