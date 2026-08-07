# First-Run Excellence: the Return Key and the First Window — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Return work everywhere in prose, and make the first window someone
sees a document they can type in rather than a filing-system decision.

**Architecture:** Two independent workstreams. (A) A single `BlockKind`-keyed
Return rule table in QuoinCore, plus "the editable slice absorbs only the
whitespace in excess of the canonical `\n\n` separator" in the renderer, so the
caret has a legal home on a blank line. (B) The macOS shell opens an autosaved
untitled document when nothing else claimed the window, and every entry path
(Finder, Dock, ⌘O, drops) routes into one window.

**Tech Stack:** Swift 6 (QuoinCore, macOS app) / Swift 5 (QuoinRender), SwiftUI +
AppKit `NSTextView`, TextKit 2, swift-markdown / cmark-gfm, XCTest.

**Design spec:** `docs/superpowers/specs/2026-08-07-first-run-and-return-design.md`
— read it before starting. This plan implements it exactly.

## Global Constraints

- **Source of truth is the markdown string + AST, never attributed strings.** Edits
  mutate the source through `DocumentSession`; the renderer re-projects.
- **Round-trip must stay byte-lossless** for untouched regions.
- **Viewport invariant:** on ANY projection change the line the caret is on must not
  move on screen. Enforced by `RevealFidelityTests` and `CaretLineAnchorTests` —
  extend BOTH when adding a projection path. Patch-vs-full-render equivalence is
  enforced by `ProjectorEquivalenceTests` — extend its interaction script when
  touching any projection path. Full rules: `docs/reference/invariants.md`.
- **No new dependencies.** Adding one requires written justification in
  `docs/reference/dependencies.md` first; the default answer is no.
- **`QuoinCore` must build and test on Linux** — no AppKit/UIKit imports there.
- **`QuoinCore` and the macOS app target are Swift 6 strict-concurrency**; keep them
  warning-clean. `QuoinRender` is Swift 5.
- **CRLF:** Swift treats `\r\n` as ONE grapheme cluster. `dropLast(2)` on Characters
  is WRONG for line endings. Every newline computation in this plan operates on
  UTF-8 **bytes**, never Characters.
- **Never override system shortcuts:** ⌘P print, ⌘E use-selection-for-find, ⌘H hide.
- **Commit after every task** and push to `main` (user directive).
- Package tests: `swift test` at repo root. App build:
  `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build`.

---

## File Structure

**Created:**
- `Sources/QuoinCore/ReturnSemantics.swift` — THE rule table: `BlockKind` → what
  Return means. Pure, platform-free, Linux-testable. One exhaustive switch.
- `Tests/QuoinCoreTests/ReturnSemanticsTests.swift` — rule-table coverage.
- `Tests/QuoinRenderTests/ExcessWhitespaceSliceTests.swift` — absorption rule.
- `Tests/QuoinRenderTests/GapDeletionTests.swift` — Backspace/Delete symmetry.
- `Tests/QuoinRenderTests/QuoteAndTableReturnTests.swift` — quote + table Return.
- `App/macOS/Sources/FirstRunBanner.swift` — the dismissible untitled-note banner.
- `Tests/QuoinCoreTests/BlankLineTidyTests.swift` — the Tidy command's pure seam.

**Modified:**
- `Sources/QuoinRender/AttributedRenderer.swift` — `editableSlice` absorption
  (~line 1137); `separatorUnchangedAcrossEdit` symmetry fix (~line 633);
  `activeBlockKind` added to `RenderedDocument` (~line 55).
- `Sources/QuoinRender/AppKit/ReaderCoordinator.swift` — Return dispatch through the
  rule table (~line 1992, 2071–2135); ⇧Return; quote/table Return; gap deletion.
- `Tests/QuoinRenderTests/ProjectorEquivalenceTests.swift` — harness must use
  `editableSlice` (line 108) + mid-document Return in the script.
- `Tests/QuoinRenderTests/EndOfDocumentReturnTests.swift` — extend, don't replace.
- `App/macOS/Sources/MainWindow.swift` — first-run gate (line 95), auto-untitled in
  `onAppear` (line 327), folder drop, session-persist guard.
- `App/macOS/Sources/QuoinApp.swift` — entry-path routing, `FileCommands` additions.
- `App/macOS/Sources/ScratchStore.swift` — launch-time GC of empty scratch files.

---

## Phase A — the Return contract

### Task 1: Thread the active block's kind into `RenderedDocument`

`RenderedDocument` carries `activeSourceText` and `revealStyler` but **not** the
active block's `BlockKind`. The Return rule table must key on kind, and the only
kind-ish thing the coordinator can currently see is `EditingFlavor`, which
classifies tables as `.prose` — the exact confusion the spec forbids. This task
adds the seam so Task 2 has something correct to read.

**Files:**
- Modify: `Sources/QuoinRender/AttributedRenderer.swift` (`RenderedDocument`, ~55–150; render loop ~256–330; `ActiveBlockEditUpdate` ~506–611; `ActivationFlipUpdate` ~645–791)
- Test: `Tests/QuoinRenderTests/ActiveBlockKindTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `RenderedDocument.activeBlockKind: BlockKind?` — nil when no block is
  revealed; otherwise the active block's kind. Populated identically by the full
  render, the per-keystroke patch, and the activation flip.

- [ ] **Step 1: Write the failing test**

```swift
#if canImport(AppKit)
import XCTest
import QuoinCore
@testable import QuoinRender

/// The active block's KIND must reach the coordinator. Return semantics key on
/// kind (a blank line terminates a table, so a table must never be mistaken for
/// a paragraph); EditingFlavor is NOT a substitute — it calls tables .prose.
final class ActiveBlockKindTests: XCTestCase {

    func testFullRenderPublishesActiveBlockKind() {
        let doc = MarkdownConverter.parse("Para\n\n| a | b |\n| - | - |\n| 1 | 2 |\n")
        let table = doc.blocks[1]
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        var held: AttributedRenderer.HeldPreview?
        let rendered = renderer.render(
            doc, activeBlockID: table.id, activeCaret: 0, cache: &cache, heldPreview: &held)
        XCTAssertEqual(rendered.activeBlockKind, table.kind,
                       "the revealed block's kind must reach the host")
    }

    func testReadingRenderHasNoActiveBlockKind() {
        let doc = MarkdownConverter.parse("Para\n")
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        var held: AttributedRenderer.HeldPreview?
        let rendered = renderer.render(
            doc, activeBlockID: nil, activeCaret: nil, cache: &cache, heldPreview: &held)
        XCTAssertNil(rendered.activeBlockKind)
    }
}
#endif
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter ActiveBlockKindTests`
Expected: FAIL — `value of type 'RenderedDocument' has no member 'activeBlockKind'`.

- [ ] **Step 3: Add the property**

In `RenderedDocument` (next to `activeSourceText`, ~line 62):

```swift
    /// The revealed block's kind. Return semantics key on this — NOT on
    /// EditingFlavor, which classifies tables as .prose (a blank line
    /// terminates a table, so the two must never be conflated).
    public let activeBlockKind: BlockKind?
```

Add `activeBlockKind: BlockKind? = nil` to the memberwise `init` (defaulted, so the
~30 existing construction sites keep compiling) and assign it. In the render loop,
where `activeSourceText = slice` is set (~line 278), also set a local
`activeBlockKind = block.kind`, and pass it into the returned `RenderedDocument`
(~line 325). Do the same in `ActiveBlockEditUpdate` (carry
`newDocument.blocks[newIndex].kind`) and `ActivationFlipUpdate`.

- [ ] **Step 4: Run the test**

Run: `swift test --filter ActiveBlockKindTests`
Expected: PASS (both).

- [ ] **Step 5: Run the guard suites — nothing may regress**

Run: `swift test --filter ProjectorEquivalenceTests && swift test --filter RevealFidelityTests && swift test --filter CaretLineAnchorTests`
Expected: PASS. This task is additive, so all three must be green with no edits.

- [ ] **Step 6: Commit**

```bash
git add Sources/QuoinRender/AttributedRenderer.swift Tests/QuoinRenderTests/ActiveBlockKindTests.swift
git commit -m "Publish the active block's kind on RenderedDocument (Return rule seam)"
git push origin main
```

---

### Task 2: The Return rule table

**Files:**
- Create: `Sources/QuoinCore/ReturnSemantics.swift`
- Test: `Tests/QuoinCoreTests/ReturnSemanticsTests.swift`

**Interfaces:**
- Consumes: `BlockKind` (QuoinCore `Model.swift:174`).
- Produces: `ReturnSemantics.mode(for: BlockKind) -> ReturnSemantics.Mode`, where
  `Mode` is `.paragraphBreak | .listAware | .quoteAware | .tableRow | .verbatim`.
  Tasks 4, 7, 8 dispatch on this.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuoinCore

/// THE Return rule table. One switch, exhaustive, so adding a BlockKind forces
/// a deliberate decision instead of silently inheriting paragraph behavior.
final class ReturnSemanticsTests: XCTestCase {

    func testProseGetsAParagraphBreak() {
        XCTAssertEqual(ReturnSemantics.mode(for: .paragraph(inlines: [])), .paragraphBreak)
        XCTAssertEqual(
            ReturnSemantics.mode(for: .heading(level: 1, inlines: [], slug: "h")),
            .paragraphBreak)
    }

    /// The load-bearing case: a blank line TERMINATES a markdown table, so a
    /// paragraph break here would destroy the user's table.
    func testTableNeverGetsAParagraphBreak() {
        let table = BlockKind.table(header: [], rows: [], alignments: [])
        XCTAssertEqual(ReturnSemantics.mode(for: table), .tableRow)
        XCTAssertNotEqual(ReturnSemantics.mode(for: table), .paragraphBreak)
    }

    func testVerbatimKindsGetAPlainNewline() {
        XCTAssertEqual(ReturnSemantics.mode(for: .codeBlock(language: nil, code: "")), .verbatim)
        XCTAssertEqual(ReturnSemantics.mode(for: .mathBlock(latex: "")), .verbatim)
        XCTAssertEqual(ReturnSemantics.mode(for: .htmlBlock("")), .verbatim)
        XCTAssertEqual(ReturnSemantics.mode(for: .frontMatter(yaml: "")), .verbatim)
        XCTAssertEqual(ReturnSemantics.mode(for: .reviewEndmatter(yaml: "")), .verbatim)
    }

    func testListAndQuoteContinue() {
        XCTAssertEqual(
            ReturnSemantics.mode(for: .list(items: [], ordered: false, start: 1)), .listAware)
        XCTAssertEqual(ReturnSemantics.mode(for: .blockQuote(children: [])), .quoteAware)
        XCTAssertEqual(
            ReturnSemantics.mode(for: .callout(kind: .note, children: [])), .quoteAware,
            "a callout is a '> [!NOTE]' quote — it continues like one")
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter ReturnSemanticsTests`
Expected: FAIL — `cannot find 'ReturnSemantics' in scope`.

- [ ] **Step 3: Write the rule table**

```swift
/// THE Return rule table: what the Return key MEANS in each kind of block.
///
/// Markdown has no empty-paragraph representation, so a lone `\n` inside a
/// paragraph is a SOFT BREAK — it re-parses to the same block and renders as a
/// space. That is why "type a line, press Enter, nothing happens": Return was
/// semantically dead, not flaky. Prose therefore needs a real paragraph break
/// (`\n\n`) — but a blank line TERMINATES a table, so this cannot be a blanket
/// rule.
///
/// Keyed on `BlockKind`, deliberately NOT on `EditingFlavor`: flavor answers
/// "how does this block reveal" and calls tables `.prose`. Two recognizers for
/// one grammar diverge (CLAUDE.md); this is the only recognizer.
///
/// The switch is exhaustive with no `default:` — adding a BlockKind must FAIL
/// TO COMPILE until someone decides what Return does there.
public enum ReturnSemantics {

    public enum Mode: Equatable, Sendable {
        /// Insert `\n\n` — a real new paragraph.
        case paragraphBreak
        /// Continue the list marker; an empty item ends the list.
        case listAware
        /// Continue the `> ` prefix; an empty quoted line exits the quote.
        case quoteAware
        /// Insert `\n` plus an empty pipe row. NEVER a blank line.
        case tableRow
        /// Raw source: a newline is a newline.
        case verbatim
    }

    public static func mode(for kind: BlockKind) -> Mode {
        switch kind {
        case .paragraph, .heading:
            return .paragraphBreak
        case .list:
            return .listAware
        case .blockQuote, .callout:
            return .quoteAware
        case .table:
            return .tableRow
        case .codeBlock, .diagram, .mathBlock, .htmlBlock,
             .frontMatter, .reviewEndmatter:
            return .verbatim
        case .tableOfContents, .thematicBreak:
            // Generated/atomic blocks: nothing sensible to split. A plain
            // newline is the least surprising no-op-ish behavior.
            return .verbatim
        }
    }
}
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter ReturnSemanticsTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuoinCore/ReturnSemantics.swift Tests/QuoinCoreTests/ReturnSemanticsTests.swift
git commit -m "The Return rule table: BlockKind → what Return means"
git push origin main
```

---

### Task 3: Excess-whitespace absorption in `editableSlice`

This is the highest-risk task in the plan. Read the spec's "Where the caret lives"
section before starting.

**Files:**
- Modify: `Sources/QuoinRender/AttributedRenderer.swift:1137` (`editableSlice`), `:633` (`separatorUnchangedAcrossEdit`)
- Modify: `Tests/QuoinRenderTests/ProjectorEquivalenceTests.swift:108`
- Test: `Tests/QuoinRenderTests/ExcessWhitespaceSliceTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `AttributedRenderer.editableSlice(for:at:in:)` — unchanged signature,
  generalized behavior. Tasks 4 and 5 depend on mid-document prose slices being
  able to end in `\n`.

- [ ] **Step 1: Write the failing test**

```swift
#if canImport(AppKit)
import XCTest
import QuoinCore
@testable import QuoinRender

/// A prose block's editable slice absorbs ONLY the whitespace in excess of the
/// canonical "\n\n" separator — never the whole gap. Absorbing the whole gap
/// would give every paragraph in every existing document a caret-occupiable
/// blank line; absorbing only the excess leaves untouched files bit-identical.
final class ExcessWhitespaceSliceTests: XCTestCase {

    private func slice(_ source: String, block index: Int) -> String? {
        let d = MarkdownConverter.parse(source)
        return AttributedRenderer.editableSlice(for: d.blocks[index], at: index, in: d)
    }

    /// THE regression guard: an ordinary document must not change at all.
    func testCanonicalGapAbsorbsNothing() {
        XCTAssertEqual(slice("A\n\nB", block: 0), "A")
    }

    func testOneExtraNewlineIsAbsorbed() {
        XCTAssertEqual(slice("A\n\n\nB", block: 0), "A\n",
                       "one Return pressed → one occupiable blank line")
    }

    func testTwoExtraNewlinesAreAbsorbed() {
        XCTAssertEqual(slice("A\n\n\n\nB", block: 0), "A\n\n")
    }

    /// A tight construction has a gap SHORTER than "\n\n" — absorb nothing.
    func testTightGapAbsorbsNothing() {
        XCTAssertEqual(slice("# H\nA", block: 0), "# H")
    }

    /// Whitespace-only lines are left strictly alone: the gap does not END with
    /// "\n\n", so it is not canonical-plus-excess.
    func testWhitespaceGapAbsorbsNothing() {
        XCTAssertEqual(slice("A\n   \nB", block: 0), "A")
    }

    /// Non-prose keeps its exact range even with an oversized gap.
    func testTableKeepsExactRangeDespiteExcessGap() {
        let source = "| a |\n| - |\n\n\nB"
        let d = MarkdownConverter.parse(source)
        let table = AttributedRenderer.editableSlice(for: d.blocks[0], at: 0, in: d)
        XCTAssertFalse(table?.hasSuffix("\n\n") ?? true,
                       "a table must never absorb a blank line — it would terminate the table")
    }

    /// CRLF is ONE grapheme in Swift; absorption is byte-wise, so a CRLF gap
    /// must not be mangled.
    func testCRLFGapIsNotMangled() {
        let d = MarkdownConverter.parse("A\r\n\r\nB")
        let s = AttributedRenderer.editableSlice(for: d.blocks[0], at: 0, in: d)
        XCTAssertEqual(s, "A", "a canonical CRLF gap absorbs nothing")
    }
}
#endif
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter ExcessWhitespaceSliceTests`
Expected: FAIL on `testOneExtraNewlineIsAbsorbed` and `testTwoExtraNewlinesAreAbsorbed`
(they return `"A"` — mid-document blocks currently always return the raw range).
The other five should already pass; that is the point — they are the guards.

- [ ] **Step 3: Generalize `editableSlice`**

Replace the body at `AttributedRenderer.swift:1137`. Note the **byte-wise** gap
test — `dropLast(2)` on Characters is wrong for CRLF (CLAUDE.md pitfall).

```swift
    public static func editableSlice(
        for block: Block, at index: Int, in document: QuoinDocument
    ) -> String? {
        guard let base = document.source.substring(in: block.range) else { return nil }
        switch block.kind {
        case .paragraph, .heading: break
        default: return base   // code/table/diagram/… keep their exact range
        }
        let contentEnd = block.range.offset + block.range.length

        // LAST block: absorb everything to EOF (unchanged behavior).
        guard index < document.blocks.count - 1 else {
            let total = document.source.utf8.count
            guard total > contentEnd,
                  let tail = document.source.substring(
                    in: ByteRange(offset: contentEnd, length: total - contentEnd))
            else { return base }
            return base + tail
        }

        // MID-DOCUMENT: absorb only the whitespace in EXCESS of the canonical
        // "\n\n" separator. The final "\n\n" always stays the separator, so an
        // ordinary document (gap == "\n\n") absorbs NOTHING and is untouched.
        // Byte-wise on purpose: "\r\n" is one Character in Swift, so dropLast(2)
        // would mangle CRLF files.
        let nextStart = document.blocks[index + 1].range.offset
        guard nextStart > contentEnd,
              let gap = document.source.substring(
                in: ByteRange(offset: contentEnd, length: nextStart - contentEnd))
        else { return base }
        let bytes = Array(gap.utf8)
        guard bytes.count > 2,
              bytes[bytes.count - 1] == 0x0A, bytes[bytes.count - 2] == 0x0A,
              let absorbed = document.source.substring(
                in: ByteRange(offset: contentEnd, length: bytes.count - 2))
        else { return base }
        return base + absorbed
    }
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter ExcessWhitespaceSliceTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Fix the `separatorUnchangedAcrossEdit` asymmetry**

At `AttributedRenderer.swift:633`, the OLD separator is derived from the raw block
range while the NEW one comes from the extended slice. That was inert while only
the last block extended (line 632 short-circuits on last-block); now that
mid-document slices extend, the two derivations disagree and the per-keystroke
patch path bails to a full re-render on every keystroke near a block end.

Replace line 633:

```swift
        let oldSlice = Self.editableSlice(
            for: oldDocument.blocks[oldIndex], at: oldIndex, in: oldDocument) ?? ""
```

- [ ] **Step 6: Fix the equivalence harness to use the same slice**

`ProjectorEquivalenceTests.swift:108` builds its active state from
`document.source.substring(in: block.range)` — the raw range. After Step 3 that no
longer matches what the renderer actually reveals, so the harness would test a
fiction. Change it to:

```swift
                guard let slice = AttributedRenderer.editableSlice(
                        for: block, at: index, in: document),
                      !slice.isEmpty else { continue }
```

where `index` is the block's index (the loop is over `document.blocks.prefix(6)`;
use `enumerated()` to get it).

- [ ] **Step 7: Add mid-document Return to the equivalence script**

In the `edits` array (~line 139), add the case this whole plan exists for:

```swift
                    slice + "\n",        // existing: clamp-flip case
                    slice + "\n\n",      // NEW: a mid-document Return
```

- [ ] **Step 8: Run every guard suite**

Run: `swift test --filter ProjectorEquivalenceTests && swift test --filter RevealFidelityTests && swift test --filter CaretLineAnchorTests && swift test --filter EndOfDocumentReturnTests`
Expected: PASS.

If `ProjectorEquivalenceTests` fails on separator geometry, this is the expected
iteration point named in the spec: `revealNeedsClampedSeparator` clamps only the
FIRST separator newline, and N absorbed newlines need the clamping arithmetic to
balance or the gap renders twice. Fix by making the clamp count match the number
of absorbed newlines — do NOT weaken the assertion.

- [ ] **Step 9: Prove the patch path is still TAKEN, not just still correct**

The separator fix in Step 5 is invisible to equivalence tests: a patch that bails to
a full render is still *correct*, just slow, so `ProjectorEquivalenceTests` passes
either way. Assert the patch actually happens. Append to
`ExcessWhitespaceSliceTests.swift`:

```swift
    /// The separatorUnchangedAcrossEdit fix, guarded. Typing at the end of a
    /// mid-document paragraph must stay on the per-keystroke PATCH path; a
    /// silent fall back to full re-render is a performance regression that no
    /// equivalence test can see.
    func testTypingAtAMidDocumentParagraphEndStaysOnThePatchPath() {
        let source = "A\n\n\nB\n\nC"      // block 0 has one absorbed newline
        let document = MarkdownConverter.parse(source)
        let block = document.blocks[0]
        let slice = AttributedRenderer.editableSlice(for: block, at: 0, in: document)!
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        var held: AttributedRenderer.HeldPreview?
        let active = renderer.render(
            document, activeBlockID: block.id, activeCaret: 1, cache: &cache, heldPreview: &held)
        let rendered = RenderedDocument(
            attributed: active.attributed, blockRanges: active.blockRanges,
            activeBlockID: block.id, activeEditableRange: active.activeEditableRange,
            activeSourceText: slice)

        let newSource = "Ax\n\n\nB\n\nC"
        let newDocument = MarkdownConverter.parse(newSource)
        var editHeld = held
        let update = renderer.activeBlockEditUpdate(
            oldDocument: document, oldRendered: rendered, oldActiveBlockID: block.id,
            newDocument: newDocument, newActiveBlockID: newDocument.blocks[0].id,
            caret: 2, heldPreview: &editHeld)
        XCTAssertNotNil(update, "typing near a block end must not bail to a full render")
    }
```

Run: `swift test --filter ExcessWhitespaceSliceTests`
Expected: PASS. If it fails, Step 5's fix is incomplete — do not work around it by
deleting the assertion.

- [ ] **Step 10: Run the whole suite**

Run: `swift test`
Expected: PASS. Do not proceed with failures.

- [ ] **Step 11: Commit**

```bash
git add Sources/QuoinRender/AttributedRenderer.swift Tests/QuoinRenderTests/
git commit -m "Editable slice absorbs whitespace in EXCESS of the canonical separator"
git push origin main
```

---

### Task 4: Return in prose inserts a paragraph break

**Files:**
- Modify: `Sources/QuoinRender/AppKit/ReaderCoordinator.swift:2071` (`continueListOnReturn`), `:2102` (`newParagraphAtDocumentEnd`), `:2129` (`endOfDocumentParagraphInsertion`)
- Test: `Tests/QuoinRenderTests/EndOfDocumentReturnTests.swift` (extend)

**Interfaces:**
- Consumes: `ReturnSemantics.mode(for:)` (Task 2), `RenderedDocument.activeBlockKind`
  (Task 1), mid-document extended slices (Task 3).
- Produces: `ReaderCoordinator.Coordinator.paragraphBreakInsertion(sourceText:relCaret:atDocumentEnd:) -> String?`
  — the pure decision, unit-tested without a live text view. Generalizes and
  replaces `endOfDocumentParagraphInsertion`.

- [ ] **Step 1: Write the failing test**

Append to `EndOfDocumentReturnTests.swift` (keep every existing test — they are the
end-of-document guards):

```swift
    // MARK: mid-document Return — the general case

    typealias C = ReaderCoordinator.Coordinator

    func testReturnAtEndOfMidDocumentParagraphInsertsAParagraphBreak() {
        // Caret at the end of "A" in "A\n\nB"; the slice is "A" (canonical gap).
        XCTAssertEqual(
            C.paragraphBreakInsertion(sourceText: "A", relCaret: 1, atDocumentEnd: false),
            "\n\n")
    }

    func testReturnOnAnAbsorbedBlankLineAddsOneMoreLine() {
        // A Return already happened: the slice is "A\n", caret on the blank line.
        XCTAssertEqual(
            C.paragraphBreakInsertion(sourceText: "A\n", relCaret: 2, atDocumentEnd: false),
            "\n")
    }

    func testReturnMidParagraphSplitsIt() {
        // Caret between "He" and "llo" — a paragraph break splits into two blocks.
        XCTAssertEqual(
            C.paragraphBreakInsertion(sourceText: "Hello", relCaret: 2, atDocumentEnd: false),
            "\n\n")
    }

    func testEndOfDocumentBehaviorIsUnchanged() {
        XCTAssertEqual(
            C.paragraphBreakInsertion(sourceText: "Hello", relCaret: 5, atDocumentEnd: true),
            "\n\n")
        XCTAssertEqual(
            C.paragraphBreakInsertion(sourceText: "Hello\n", relCaret: 6, atDocumentEnd: true),
            "\n")
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter EndOfDocumentReturnTests`
Expected: FAIL — `type 'Coordinator' has no member 'paragraphBreakInsertion'`.

- [ ] **Step 3: Generalize the insertion decision**

Replace `endOfDocumentParagraphInsertion` (line 2129) with a version that no longer
requires the caret to be at the document's end. A paragraph break is `\n\n`; when the
caret already sits on an absorbed blank line (the slice's remainder from the caret
is only newlines), one more `\n` steps down a line.

```swift
        /// The text a Return inserts in PROSE, or nil when the gesture doesn't
        /// apply. From content → a paragraph break (`\n\n`); already sitting on
        /// a blank line → one more line (`\n`). Pure, so the decision is
        /// unit-tested without a live text view.
        static func paragraphBreakInsertion(
            sourceText: String, relCaret: Int, atDocumentEnd: Bool
        ) -> String? {
            let ns = sourceText as NSString
            guard relCaret >= 0, relCaret <= ns.length else { return nil }
            // Everything from the caret to the slice's end: only newlines means
            // the caret is on (or before) absorbed blank lines.
            let rest = ns.substring(from: relCaret)
            guard rest.allSatisfy({ $0 == "\n" }) else { return "\n\n" }
            let before = ns.substring(to: relCaret)
            let trailing = before.reversed().prefix(while: { $0 == "\n" }).count
            return trailing == 0 ? "\n\n" : "\n"
        }
```

Keep `endOfDocumentParagraphInsertion` as a thin deprecated forwarder ONLY if other
call sites need it; otherwise delete it and update its callers.

- [ ] **Step 4: Run the test**

Run: `swift test --filter EndOfDocumentReturnTests`
Expected: PASS (existing + 4 new).

- [ ] **Step 5: Dispatch Return through the rule table**

In `textView(_:doCommandBy:)` at line 1992, replace the direct call to
`continueListOnReturn` with a rule-table dispatch:

```swift
            if commandSelector == #selector(NSTextView.insertNewline(_:)) {
                return handleReturn(in: textView)
            }
```

Add `handleReturn`, which reads the kind from Task 1's seam and dispatches. Tasks 7
and 8 fill in `.quoteAware` and `.tableRow`; until then they fall through to the
existing plain-newline behavior by returning `false`.

```swift
        /// Return, routed through THE rule table (ReturnSemantics) so every
        /// block kind's behavior is decided in exactly one place.
        private func handleReturn(in textView: NSTextView) -> Bool {
            guard let kind = parent.rendered.activeBlockKind else { return false }
            switch ReturnSemantics.mode(for: kind) {
            case .listAware:
                return continueListOnReturn(in: textView)
            case .paragraphBreak:
                return insertParagraphBreak(in: textView)
            case .quoteAware:
                return false   // Task 7
            case .tableRow:
                return false   // Task 8
            case .verbatim:
                return false   // plain \n — the system's own insertion
            }
        }
```

`continueListOnReturn` keeps its existing fallthrough to the paragraph path for
non-list lines inside a list block. `insertParagraphBreak` mirrors
`newParagraphAtDocumentEnd` (line 2110) but drops the `atDocumentEnd` guard, uses
`paragraphBreakInsertion`, and computes the byte range at the caret rather than at
the slice's end:

```swift
        private func insertParagraphBreak(in textView: NSTextView) -> Bool {
            guard let onEdit = parent.onEditIntent,
                  !awaitingEditEcho,
                  let active = parent.rendered.activeEditableRange,
                  let sourceText = parent.rendered.activeSourceText else { return false }
            let selection = textView.selectedRange()
            guard selection.length == 0,
                  selection.location >= active.location,
                  NSMaxRange(selection) <= NSMaxRange(active) else { return false }
            let relCaret = selection.location - active.location
            let atEnd = NSMaxRange(active) == (textView.string as NSString).length
            guard let insertion = Self.paragraphBreakInsertion(
                sourceText: sourceText, relCaret: relCaret, atDocumentEnd: atEnd),
                let byteOffset = EditMapping.utf8Offset(inText: sourceText, utf16Offset: relCaret)
            else { return false }
            onEdit(ByteRange(offset: byteOffset, length: 0), insertion, nil)
            beginAwaitingEditEcho()
            return true
        }
```

Note: `onEdit` takes a byte range **relative to the active block's source**, matching
how `listContinuationEdit.byteEdit` already computes it.

- [ ] **Step 6: Run the guard suites**

Run: `swift test --filter ProjectorEquivalenceTests && swift test --filter RevealFidelityTests && swift test --filter CaretLineAnchorTests && swift test`
Expected: PASS.

- [ ] **Step 7: Verify in the real app — this is the bug the user reported**

```bash
cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build
pkill -x Quoin; .../Build/Products/Debug/Quoin.app/Contents/MacOS/Quoin > /tmp/quoin.log 2>&1 &
```

Manually: open a document with several paragraphs. Click at the end of a
**middle** paragraph. Press Return. Expected: the caret drops to a new blank line
and typing there creates a new paragraph. Press Return four times: the caret
descends four lines. This is the acceptance test — do not mark the task done on
unit tests alone.

- [ ] **Step 8: Commit**

```bash
git add Sources/QuoinRender/AppKit/ReaderCoordinator.swift Tests/QuoinRenderTests/EndOfDocumentReturnTests.swift
git commit -m "Return in prose inserts a paragraph break, mid-document included"
git push origin main
```

---

### Task 5: Backspace and Delete symmetry in the gap

**Files:**
- Modify: `Sources/QuoinRender/AppKit/ReaderCoordinator.swift` (`doCommandBy`, ~1992)
- Test: `Tests/QuoinRenderTests/GapDeletionTests.swift` (create)

**Interfaces:**
- Consumes: `paragraphBreakInsertion` (Task 4), extended slices (Task 3).
- Produces: `ReaderCoordinator.Coordinator.gapDeletion(sourceText:relCaret:forward:) -> (utf16Range: Range<Int>, caretUTF16: Int)?`

- [ ] **Step 1: Write the failing test**

```swift
#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Deletion must undo exactly what Return did: one blank line per Backspace,
/// and the last one merges the caret back to the end of the paragraph.
final class GapDeletionTests: XCTestCase {

    typealias C = ReaderCoordinator.Coordinator

    func testBackspaceOnABlankLineRemovesOneNewline() {
        // Slice "A\n\n" (two Returns pressed), caret on the second blank line.
        let d = C.gapDeletion(sourceText: "A\n\n", relCaret: 3, forward: false)
        XCTAssertEqual(d?.utf16Range, 2..<3)
        XCTAssertEqual(d?.caretUTF16, 2)
    }

    func testBackspaceOnTheLastBlankLineReturnsToTheParagraph() {
        let d = C.gapDeletion(sourceText: "A\n", relCaret: 2, forward: false)
        XCTAssertEqual(d?.utf16Range, 1..<2)
        XCTAssertEqual(d?.caretUTF16, 1, "caret lands at the end of 'A'")
    }

    func testBackspaceInsideContentIsNotOurs() {
        XCTAssertNil(C.gapDeletion(sourceText: "Hello", relCaret: 3, forward: false),
                     "ordinary deletion must fall through to the system")
    }

    func testForwardDeleteOnABlankLineIsSymmetric() {
        let d = C.gapDeletion(sourceText: "A\n\n", relCaret: 1, forward: true)
        XCTAssertEqual(d?.utf16Range, 1..<2)
        XCTAssertEqual(d?.caretUTF16, 1)
    }
}
#endif
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter GapDeletionTests`
Expected: FAIL — no member `gapDeletion`.

- [ ] **Step 3: Implement the pure decision**

```swift
        /// Backspace/Delete when the caret sits in a block's ABSORBED trailing
        /// newlines: remove exactly one newline, mirroring one Return. Returns
        /// nil for ordinary deletion, which falls through to the system.
        static func gapDeletion(
            sourceText: String, relCaret: Int, forward: Bool
        ) -> (utf16Range: Range<Int>, caretUTF16: Int)? {
            let ns = sourceText as NSString
            guard relCaret >= 0, relCaret <= ns.length else { return nil }
            // Only the run of trailing newlines is ours.
            let trailing = sourceText.reversed().prefix(while: { $0 == "\n" }).count
            let contentEnd = ns.length - trailing
            guard trailing > 0 else { return nil }
            if forward {
                guard relCaret >= contentEnd, relCaret < ns.length else { return nil }
                return (relCaret ..< relCaret + 1, relCaret)
            }
            guard relCaret > contentEnd, relCaret <= ns.length else { return nil }
            return (relCaret - 1 ..< relCaret, relCaret - 1)
        }
```

Wire it in `doCommandBy` for `deleteBackward(_:)` and `deleteForward(_:)`, routing
through `onEditIntent` exactly as `indentListLines` does (line 2046): map the UTF-16
range to bytes with `EditMapping.utf8Range(inText:utf16Range:)`, call `onEdit`, then
`beginAwaitingEditEcho()`. Return `false` when `gapDeletion` returns nil.

- [ ] **Step 4: Run the test**

Run: `swift test --filter GapDeletionTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the guard suites**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Verify in the app**

Press Return three times at the end of a mid-document paragraph, then Backspace
three times. Expected: the caret climbs one line per press and ends at the end of
the paragraph, with the file back to its original bytes.

- [ ] **Step 7: Commit**

```bash
git add Sources/QuoinRender/AppKit/ReaderCoordinator.swift Tests/QuoinRenderTests/GapDeletionTests.swift
git commit -m "Backspace/Delete remove one absorbed blank line, mirroring Return"
git push origin main
```

---

### Task 6: ⇧Return inserts a hard line break

**Files:**
- Modify: `Sources/QuoinRender/AppKit/ReaderCoordinator.swift` (`doCommandBy`)
- Test: `Tests/QuoinRenderTests/EndOfDocumentReturnTests.swift` (extend)

**Interfaces:**
- Consumes: Task 4's dispatch.
- Produces: `ReaderCoordinator.Coordinator.hardBreakInsertion(sourceText:relCaret:) -> String?`

- [ ] **Step 1: Write the failing test**

```swift
    // MARK: ⇧Return — the explicit line break

    func testShiftReturnInsertsACommonMarkHardBreak() {
        XCTAssertEqual(
            C.hardBreakInsertion(sourceText: "Hello", relCaret: 5), "\\\n",
            "a backslash hard break is VISIBLE in source; trailing spaces are not")
    }

    func testShiftReturnDoesNotDoubleTheBackslash() {
        XCTAssertNil(C.hardBreakInsertion(sourceText: "Hello\\", relCaret: 6))
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter EndOfDocumentReturnTests`
Expected: FAIL — no member `hardBreakInsertion`.

- [ ] **Step 3: Implement**

CommonMark has two hard-break spellings: two trailing spaces + `\n`, or `\` + `\n`.
Use the backslash — Quoin reveals literal source, and invisible trailing spaces are
un-seeable and get stripped by other tools.

```swift
        /// ⇧Return: an explicit CommonMark hard line break. Backslash form, not
        /// two-trailing-spaces: the reveal shows literal source, and invisible
        /// trailing spaces are both unseeable and routinely stripped by other
        /// editors. Nil when the caret already follows a backslash.
        static func hardBreakInsertion(sourceText: String, relCaret: Int) -> String? {
            let ns = sourceText as NSString
            guard relCaret > 0, relCaret <= ns.length else { return relCaret == 0 ? "\\\n" : nil }
            guard ns.substring(with: NSRange(location: relCaret - 1, length: 1)) != "\\" else {
                return nil
            }
            return "\\\n"
        }
```

`NSTextView` sends `insertLineBreak(_:)` for ⇧Return. Handle that selector in
`doCommandBy`, gated to `ReturnSemantics.mode(for: kind) == .paragraphBreak`, and
route through `onEditIntent`.

- [ ] **Step 4: Run the test**

Run: `swift test --filter EndOfDocumentReturnTests`
Expected: PASS.

- [ ] **Step 5: Verify in the app**

Type a line, press ⇧Return, type another. Expected: both lines render inside ONE
paragraph, on separate lines.

- [ ] **Step 6: Commit**

```bash
git add Sources/QuoinRender/AppKit/ReaderCoordinator.swift Tests/QuoinRenderTests/EndOfDocumentReturnTests.swift
git commit -m "⇧Return inserts an explicit CommonMark hard line break"
git push origin main
```

---

### Task 7: Return continues a blockquote

**Files:**
- Modify: `Sources/QuoinRender/AppKit/ReaderCoordinator.swift` (`handleReturn` `.quoteAware`)
- Test: `Tests/QuoinRenderTests/QuoteAndTableReturnTests.swift` (create)

**Interfaces:**
- Consumes: `ReturnSemantics.Mode.quoteAware` (Task 2).
- Produces: `ReaderCoordinator.Coordinator.quoteContinuationEdit(sourceText:caretUTF16:) -> ListContinuationEdit?`
  — reuses the existing `ListContinuationEdit` struct (line 2141) so both
  continuations share one edit representation.

- [ ] **Step 1: Write the failing test**

```swift
#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Return inside a quote continues "> "; an empty quoted line exits the quote.
/// Return inside a table adds a ROW — never a blank line, which would terminate
/// the table.
final class QuoteAndTableReturnTests: XCTestCase {

    typealias C = ReaderCoordinator.Coordinator

    func testReturnInAQuoteCarriesThePrefixDown() {
        let e = C.quoteContinuationEdit(sourceText: "> hello", caretUTF16: 7)
        XCTAssertEqual(e?.replacement, "\n> ")
        XCTAssertEqual(e?.utf16Range, 7..<7)
    }

    func testReturnOnAnEmptyQuotedLineExitsTheQuote() {
        // "> a\n> " with the caret after the empty marker.
        let e = C.quoteContinuationEdit(sourceText: "> a\n> ", caretUTF16: 6)
        XCTAssertEqual(e?.replacement, "")
        XCTAssertEqual(e?.utf16Range, 4..<6, "the empty '> ' marker is removed")
    }

    func testNestedQuotePrefixIsPreserved() {
        let e = C.quoteContinuationEdit(sourceText: ">> deep", caretUTF16: 7)
        XCTAssertEqual(e?.replacement, "\n>> ")
    }

    func testNonQuoteLineIsNotOurs() {
        XCTAssertNil(C.quoteContinuationEdit(sourceText: "plain", caretUTF16: 5))
    }
}
#endif
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter QuoteAndTableReturnTests`
Expected: FAIL — no member `quoteContinuationEdit`.

- [ ] **Step 3: Implement**

Reuses `ListContinuationEdit` (line 2141) so both continuations share one edit
representation.

```swift
        /// Return inside a blockquote: carry the "> " prefix onto the new line,
        /// or — on an empty quoted line — delete the marker to exit the quote.
        /// Mirrors listContinuationEdit exactly; nil for non-quote lines.
        static func quoteContinuationEdit(
            sourceText: String, caretUTF16 caret: Int
        ) -> ListContinuationEdit? {
            let ns = sourceText as NSString
            guard caret >= 0, caret <= ns.length else { return nil }
            let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
            let rawLine = ns.substring(with: lineRange)
            let line = Substring(rawLine.hasSuffix("\n") ? String(rawLine.dropLast()) : rawLine)
            // Leading '>' run, then at most one space. All ASCII, so character
            // count == UTF-16 length.
            let markers = line.prefix(while: { $0 == ">" })
            guard !markers.isEmpty else { return nil }
            var prefixCount = markers.count
            if line.dropFirst(prefixCount).first == " " { prefixCount += 1 }
            let contentStart = lineRange.location + prefixCount
            guard caret >= contentStart else { return nil }  // inside the marker
            let content = line.dropFirst(prefixCount)
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                // Empty quoted line + Return: remove the marker, ending the quote.
                return ListContinuationEdit(
                    utf16Range: lineRange.location ..< contentStart,
                    replacement: "", caretUTF16: 0)
            }
            let replacement = "\n" + String(markers) + " "
            return ListContinuationEdit(
                utf16Range: caret ..< caret, replacement: replacement,
                caretUTF16: replacement.utf16.count)
        }
```

Then set `.quoteAware` in `handleReturn` to call it through `onEditIntent` exactly as
`continueListOnReturn` does (line 2095), falling back to `insertParagraphBreak` when
it returns nil.

- [ ] **Step 4: Run the test**

Run: `swift test --filter QuoteAndTableReturnTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the whole suite and verify in the app**

Run: `swift test`. Then in the app: click into a blockquote, press Return, type.
Expected: the new line stays inside the quote. Press Return on the resulting empty
quoted line: the quote ends.

- [ ] **Step 6: Commit**

```bash
git add Sources/QuoinRender/AppKit/ReaderCoordinator.swift Tests/QuoinRenderTests/QuoteAndTableReturnTests.swift
git commit -m "Return continues a blockquote; an empty quoted line exits it"
git push origin main
```

---

### Task 8: Return adds a table row

**Files:**
- Modify: `Sources/QuoinRender/AppKit/ReaderCoordinator.swift` (`handleReturn` `.tableRow`)
- Test: `Tests/QuoinRenderTests/QuoteAndTableReturnTests.swift` (extend)

**Interfaces:**
- Consumes: `ReturnSemantics.Mode.tableRow` (Task 2).
- Produces: `ReaderCoordinator.Coordinator.tableRowInsertion(sourceText:caretUTF16:) -> String?`

- [ ] **Step 1: Write the failing test**

Append to `QuoteAndTableReturnTests.swift`:

```swift
    func testReturnAtTheEndOfARowAddsAnEmptyRow() {
        let table = "| a | b |\n| - | - |\n| 1 | 2 |"
        XCTAssertEqual(
            C.tableRowInsertion(sourceText: table, caretUTF16: (table as NSString).length),
            "\n|  |  |",
            "a new row must match the header's column count")
    }

    func testReturnMidRowIsAPlainNewline() {
        let table = "| a | b |\n| - | - |\n| 1 | 2 |"
        XCTAssertNil(C.tableRowInsertion(sourceText: table, caretUTF16: 3),
                     "mid-row Return falls through to a plain newline")
    }

    /// The whole reason tables are excluded from .paragraphBreak.
    func testTableInsertionNeverContainsABlankLine() {
        let table = "| a |\n| - |\n| 1 |"
        let out = C.tableRowInsertion(sourceText: table, caretUTF16: (table as NSString).length)
        XCTAssertFalse(out?.contains("\n\n") ?? false,
                       "a blank line would TERMINATE the table")
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter QuoteAndTableReturnTests`
Expected: FAIL — no member `tableRowInsertion`.

- [ ] **Step 3: Implement**

```swift
        /// Return at the end of a table row: a new EMPTY row matching the
        /// header's column count. Never a blank line — that would terminate the
        /// table. Nil anywhere else, so Return falls through to a plain newline.
        static func tableRowInsertion(sourceText: String, caretUTF16 caret: Int) -> String? {
            let ns = sourceText as NSString
            guard caret >= 0, caret <= ns.length else { return nil }
            let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
            let rawLine = ns.substring(with: lineRange)
            let line = rawLine.hasSuffix("\n") ? String(rawLine.dropLast()) : rawLine
            // Only at the END of a row line.
            guard caret == lineRange.location + (line as NSString).length,
                  line.hasPrefix("|") else { return nil }
            // Column count from the HEADER (first line), not this row: a
            // malformed row must not shrink the table.
            let headerRange = ns.lineRange(for: NSRange(location: 0, length: 0))
            let rawHeader = ns.substring(with: headerRange)
            let header = rawHeader.hasSuffix("\n") ? String(rawHeader.dropLast()) : rawHeader
            let columns = header.filter { $0 == "|" }.count - 1
            guard columns > 0 else { return nil }
            return "\n|" + String(repeating: "  |", count: columns)
        }
```

Wire `.tableRow` in `handleReturn` to call it through `onEditIntent`, returning
`false` when it yields nil.

- [ ] **Step 4: Run the test**

Run: `swift test --filter QuoteAndTableReturnTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Verify in the app — the data-loss guard**

Click into a table, put the caret at the end of the last row, press Return. Expected:
a new empty row appears and the table still renders as a table. This is the case
that would have destroyed data under a blanket `\n\n` rule.

- [ ] **Step 6: Commit**

```bash
git add Sources/QuoinRender/AppKit/ReaderCoordinator.swift Tests/QuoinRenderTests/QuoteAndTableReturnTests.swift
git commit -m "Return at the end of a table row adds a row, never a blank line"
git push origin main
```

---

### Task 9: Format ▸ Tidy Blank Lines

Blank lines are preserved exactly; this is the explicit, undoable cleanup.

**Files:**
- Create: `Sources/QuoinCore/BlankLineTidy.swift`
- Create: `Tests/QuoinCoreTests/BlankLineTidyTests.swift`
- Modify: `App/macOS/Sources/QuoinApp.swift` (`MenuBarCommands`), `App/macOS/Sources/ReaderModel.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `BlankLineTidy.tidied(_ source: String) -> String`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuoinCore

/// Explicit, undoable cleanup — never automatic. Quoin is byte-lossless; a save
/// must never move the user's text.
final class BlankLineTidyTests: XCTestCase {

    func testCollapsesRunsOfBlankLinesToOne() {
        XCTAssertEqual(BlankLineTidy.tidied("A\n\n\n\n\nB"), "A\n\nB")
    }

    func testLeavesCanonicalSpacingAlone() {
        XCTAssertEqual(BlankLineTidy.tidied("A\n\nB"), "A\n\nB")
    }

    func testNeverTouchesCodeBlockInteriors() {
        let src = "```\nx\n\n\n\ny\n```\n"
        XCTAssertEqual(BlankLineTidy.tidied(src), src,
                       "blank lines inside a fence are content, not spacing")
    }

    func testNormalizesCRLFRunsWithoutMangling() {
        XCTAssertEqual(BlankLineTidy.tidied("A\r\n\r\n\r\n\r\nB"), "A\r\n\r\nB")
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter BlankLineTidyTests`
Expected: FAIL — `cannot find 'BlankLineTidy' in scope`.

- [ ] **Step 3: Implement**

CLAUDE.md pitfall: `split(separator: "\n")` never splits CRLF (Swift treats `\r\n`
as one grapheme), so walk by UTF-8 bytes and keep each line's own terminator.

```swift
/// Explicit, undoable blank-line cleanup (Format ▸ Tidy Blank Lines). NEVER
/// automatic: Quoin is byte-lossless, so a save must not move the user's text.
/// Runs of 2+ blank lines collapse to one, OUTSIDE fenced code — blank lines
/// inside a fence are content, not spacing.
public enum BlankLineTidy {

    public static func tidied(_ source: String) -> String {
        var out = ""
        var inFence = false
        var pendingBlanks: [String] = []
        for line in physicalLines(of: source) {
            let body = line.hasSuffix("\r\n")
                ? String(line.dropLast(2))
                : (line.hasSuffix("\n") ? String(line.dropLast()) : line)
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, trimmed.isEmpty {
                pendingBlanks.append(line)      // hold; emit at most one
                continue
            }
            if let first = pendingBlanks.first { out += first }
            pendingBlanks.removeAll()
            out += line
        }
        if let first = pendingBlanks.first { out += first }
        return out
    }

    /// Lines WITH their terminators, split on \n but keeping \r\n intact.
    private static func physicalLines(of source: String) -> [String] {
        var lines: [String] = []
        var current = ""
        for scalar in source.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if scalar == "\n" { lines.append(current); current = "" }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter BlankLineTidyTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Wire the menu command**

Add `Format ▸ Tidy Blank Lines` in `MenuBarCommands` posting a new
`AppDelegate.tidyBlankLinesNotification`; `ReaderModel` applies it as ONE edit
through the ordinary pipeline so it is undoable and autosaved. Per CLAUDE.md, the
edit MUST be computed where it is applied (in-actor at apply time, the
`applyResolution` pattern) — not computed against the model's projection and queued.

- [ ] **Step 6: Verify and commit**

Run: `swift test`, then build the app and exercise the menu item + ⌘Z.

```bash
git add Sources/QuoinCore/BlankLineTidy.swift Tests/QuoinCoreTests/BlankLineTidyTests.swift App/macOS/Sources/
git commit -m "Format ▸ Tidy Blank Lines: explicit, undoable blank-line cleanup"
git push origin main
```

---

## Phase B — the shell and the first window

### Task 10: The first window is a document

**Files:**
- Modify: `App/macOS/Sources/MainWindow.swift:95` (first-run gate), `:327` (`onAppear`)
- Create: `Sources/QuoinCore/FirstRunDecision.swift`
- Create: `App/macOS/Sources/FirstRunBanner.swift`
- Test: `Tests/QuoinCoreTests/FirstRunDecisionTests.swift` (create)

**Interfaces:**
- Consumes: `ScratchStore.createUntitled()`.
- Produces: `FirstRunDecision.shouldCreateUntitled(hasOpenTabs:hasLibrary:hasPendingOpens:isLaunchRestoration:reopenedScratchCount:) -> Bool`
  — the pure guard, so the ordering rule is testable without a window.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuoinCore

/// The auto-untitled document must appear ONLY when nothing else claimed the
/// window. A Finder double-click must never race a blank document beside it.
final class FirstRunDecisionTests: XCTestCase {

    func testTrueFirstLaunchGetsAnUntitledDocument() {
        XCTAssertTrue(FirstRunDecision.shouldCreateUntitled(
            hasOpenTabs: false, hasLibrary: false, hasPendingOpens: false,
            isLaunchRestoration: false, reopenedScratchCount: 0))
    }

    func testAPendingFinderOpenSuppressesIt() {
        XCTAssertFalse(FirstRunDecision.shouldCreateUntitled(
            hasOpenTabs: false, hasLibrary: false, hasPendingOpens: true,
            isLaunchRestoration: false, reopenedScratchCount: 0))
    }

    func testARestoredSessionSuppressesIt() {
        XCTAssertFalse(FirstRunDecision.shouldCreateUntitled(
            hasOpenTabs: true, hasLibrary: false, hasPendingOpens: false,
            isLaunchRestoration: true, reopenedScratchCount: 0))
    }

    func testAReopenedScratchDocumentSuppressesIt() {
        XCTAssertFalse(FirstRunDecision.shouldCreateUntitled(
            hasOpenTabs: false, hasLibrary: false, hasPendingOpens: false,
            isLaunchRestoration: true, reopenedScratchCount: 1))
    }

    func testAConnectedLibraryStillGetsAnUntitledDocument() {
        XCTAssertTrue(FirstRunDecision.shouldCreateUntitled(
            hasOpenTabs: false, hasLibrary: true, hasPendingOpens: false,
            isLaunchRestoration: false, reopenedScratchCount: 0),
            "an empty window should be writable regardless of library state")
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter FirstRunDecisionTests`
Expected: FAIL — `cannot find 'FirstRunDecision' in scope`.

- [ ] **Step 3: Implement the guard**

```swift
/// Whether a window with nothing in it should materialize an untitled document.
/// The first window someone sees must be a DOCUMENT, not a filing decision
/// (docs/design/principles.md) — but only when no other entry path claimed it.
public enum FirstRunDecision {
    public static func shouldCreateUntitled(
        hasOpenTabs: Bool, hasLibrary: Bool, hasPendingOpens: Bool,
        isLaunchRestoration: Bool, reopenedScratchCount: Int
    ) -> Bool {
        if hasOpenTabs || hasPendingOpens { return false }
        if isLaunchRestoration && reopenedScratchCount > 0 { return false }
        return true
    }
}
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter FirstRunDecisionTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Wire it into `onAppear`**

At `MainWindow.swift:327`, AFTER every existing drain (`connectLibrary`,
`restoreTabs`, `drainPendingOpenURLs`, `consumePendingDeepLink`,
`claimPendingSelectionSeed`, and the scratch reopen at line 348) and BEFORE
`updateUserActivity()`:

```swift
            // The first window someone sees is a DOCUMENT, not a filing
            // decision (principles.md). Last, so a Finder open / restored
            // session / reopened scratch doc always wins the window.
            if FirstRunDecision.shouldCreateUntitled(
                hasOpenTabs: !openTabs.isEmpty,
                hasLibrary: library.hasLibrary,
                hasPendingOpens: AppDelegate.hasPendingOpenURLs,
                isLaunchRestoration: AppDelegate.isLaunchRestoration,
                reopenedScratchCount: reopenedScratchCount),
               let url = ScratchStore.createUntitled() {
                open(url)
                showFirstRunBanner = true
            }
```

Capture `reopenedScratchCount` from the loop at line 348-350. Add
`AppDelegate.hasPendingOpenURLs` (a read-only peek at the pending slot that does
NOT clear it).

- [ ] **Step 6: Replace the first-run gate**

At line 95, `chooseLibraryPrompt` is no longer the first-run screen. Keep it only as
the recovery surface for `library.bookmarkRestoreFailure` (line 921 — a vanished
library must never masquerade as a fresh install). Otherwise fall through to the
editor.

- [ ] **Step 7: Build the banner**

`FirstRunBanner.swift`: a dismissible card below the caret reading **"Untitled note
— saved automatically."** / "⌘S to give it a home." with `[Open a File…]`
`[Connect a Library…]` and an ×. It fades on first keystroke — observe the model's
content revision. Follow `docs/design/handoff.md` for type sizes and alpha values;
model the styling on `sampleOfferCard` (MainWindow.swift:884).

- [ ] **Step 8: Verify in the app — the acceptance test**

Delete the app's container to simulate a true first run:
`rm -rf ~/Library/Containers/ai.2389.Quoin` (WARNING: this destroys scratch
documents — confirm with the user before running it on their machine).

Launch. Expected: a window with a blank untitled document, caret blinking in it, no
sidebar, banner visible. Type immediately — the characters must appear. Press
Return — a new paragraph.

- [ ] **Step 9: Commit**

```bash
git add App/macOS/Sources/ Sources/QuoinCore/FirstRunDecision.swift Tests/QuoinCoreTests/FirstRunDecisionTests.swift
git commit -m "First run opens a writable untitled document, not a library prompt"
git push origin main
```

---

### Task 11: Every entry path lands in one window (issue #41)

**Files:**
- Modify: `App/macOS/Sources/QuoinApp.swift:870` (`application(_:open:)`), scene declaration `:20`
- Create: `Sources/QuoinCore/PendingOpenSlot.swift`
- Test: `Tests/QuoinCoreTests/EntryPathRoutingTests.swift` (create)

**Interfaces:**
- Consumes: `FirstRunDecision` (Task 10).
- Produces: no new API — a behavior fix plus regression tests on the pure routing
  seam.

- [ ] **Step 1: REPRODUCE the bug before changing anything**

Build and launch. Select three `.md` files in Finder and drag them onto the Quoin
Dock icon. Record: how many windows appear, which have content, and whether the
blank ones close via the red button, ⌘W, and ⇧⌘W. **Write the observed behavior
into the commit message.** The spec names scene auto-spawn as a hypothesis, not a
conclusion — confirm the mechanism before fixing it.

- [ ] **Step 2: Write the failing test for the routing seam**

```swift
import XCTest
@testable import QuoinCore

/// N files dropped on the Dock icon must become N TABS IN ONE WINDOW — never N
/// windows, and never a blank orphan (issue #41).
final class EntryPathRoutingTests: XCTestCase {

    func testMultipleOpensCoalesceIntoOneBatch() {
        var slot = PendingOpenSlot()
        slot.enqueue(URL(fileURLWithPath: "/tmp/a.md"))
        slot.enqueue(URL(fileURLWithPath: "/tmp/b.md"))
        slot.enqueue(URL(fileURLWithPath: "/tmp/c.md"))
        XCTAssertEqual(slot.drain().count, 3, "one drain takes all three")
        XCTAssertTrue(slot.drain().isEmpty, "a second drainer must see nothing")
    }

    func testPeekDoesNotConsume() {
        var slot = PendingOpenSlot()
        slot.enqueue(URL(fileURLWithPath: "/tmp/a.md"))
        XCTAssertTrue(slot.hasPending)
        XCTAssertEqual(slot.drain().count, 1, "peeking must not have consumed it")
    }
}
```

- [ ] **Step 3: Run it and watch it fail**

Run: `swift test --filter EntryPathRoutingTests`
Expected: FAIL — `cannot find 'PendingOpenSlot' in scope`.

- [ ] **Step 4: Extract the pending-open slot**

```swift
/// Files waiting to be opened, batched. N files dropped on the Dock icon must
/// become N tabs in ONE window, so the slot accumulates and exactly one drainer
/// takes the whole batch (issue #41). `hasPending` peeks WITHOUT consuming —
/// the first-run guard needs to know a Finder open is inbound before deciding
/// whether to create an untitled document.
public struct PendingOpenSlot {
    private var urls: [URL] = []

    public init() {}

    public var hasPending: Bool { !urls.isEmpty }

    public mutating func enqueue(_ url: URL) { urls.append(url) }

    /// Takes the whole batch atomically; a second drainer sees nothing.
    public mutating func drain() -> [URL] {
        defer { urls.removeAll() }
        return urls
    }
}
```

`AppDelegate` keeps one instance (guarded on the main actor, as its existing static
slots are) and forwards `requestOpen` / `drainPendingOpenURLs` /
`hasPendingOpenURLs` to it.

- [ ] **Step 5: Run the test**

Run: `swift test --filter EntryPathRoutingTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Stop the scene auto-spawn**

Based on Step 1's findings. If confirmed as SwiftUI spawning a scene per open
request, declare the `WindowGroup` as handling no external events so AppKit owns
document opens entirely:

```swift
        WindowGroup(id: "main", for: String.self) { $rootPath in
            MainWindow(requestedRootPath: rootPath)
                .frame(minWidth: 720, minHeight: 480)
        }
        .handlesExternalEvents(matching: [])
```

If Step 1 showed a different mechanism, fix THAT and record why in the commit.

- [ ] **Step 7: Guarantee an empty window is closable**

Independent of the spawn fix. Verify the red traffic-light button, ⌘W (line 209),
and ⇧⌘W each close a window with no tabs. "Unclosable" is the enraging half of #41
and must not survive even if a blank window slips through.

- [ ] **Step 8: Verify every entry path from the spec's table**

Walk all nine rows in the design spec: cold launch (empty / restored / leftover
scratch), Finder double-click, Open With, 1 file to Dock, N files to Dock, ⌘O
multi-select, drop onto a window. Record each result.

- [ ] **Step 9: Commit**

```bash
git add App/macOS/Sources/QuoinApp.swift Sources/QuoinCore/PendingOpenSlot.swift Tests/QuoinCoreTests/EntryPathRoutingTests.swift
git commit -m "Route every file open into ONE window; kill the blank-window spawn (#41)"
git push origin main
```

---

### Task 12: Demote library setup, keep it discoverable

**Files:**
- Modify: `App/macOS/Sources/QuoinApp.swift` (`FileCommands`), `App/macOS/Sources/MainWindow.swift` (folder drop)

**Interfaces:**
- Consumes: `library.chooseLibraryFolder()`, `library.createStarterLibrary()`.
- Produces: no new API.

- [ ] **Step 1: Add the always-available menu items**

These were reachable ONLY from the first-run screen that Task 10 removed — without
this task the capability is lost outright, so it is not optional.

`FileCommands` (a `Commands` struct) can't reach the window's `LibraryModel`
directly; follow the established pattern and post a notification the key window
observes, exactly as `changeLibraryNotification` already does:

```swift
                Divider()
                Button("Connect a Library…") {
                    post(AppDelegate.connectLibraryNotification)
                }
                Button("New Library…") {
                    post(AppDelegate.newLibraryNotification)
                }
```

Declare both names alongside the others (`QuoinApp.swift:696`), and observe them in
`MainWindow` next to the existing library observers, key-gated like every other
menu action:

```swift
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.connectLibraryNotification)) { _ in
            guard isKeyWindow else { return }
            if library.chooseLibraryFolder() {
                offerSample = library.shouldOfferSampleDocuments
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.newLibraryNotification)) { _ in
            guard isKeyWindow else { return }
            if let welcome = library.createStarterLibrary() { open(welcome) }
        }
```

- [ ] **Step 2: Accept a dropped folder**

Extend the editor's existing `.onDrop` (`ReaderScreen.swift:293`) to recognize a
directory and present a non-modal confirmation — *Connect "Notes" as this window's
library?* `[Connect]` `[Cancel]` — never a silent re-root. Files keep opening as tabs.

- [ ] **Step 3: Verify**

Build. Confirm: both menu items work with no library connected; dropping a folder
prompts rather than silently re-rooting; dropping a file still opens a tab.

- [ ] **Step 4: Commit**

```bash
git add App/macOS/Sources/
git commit -m "Library setup moves to the File menu and a folder-drop gesture"
git push origin main
```

---

### Task 13: Housekeeping — don't let untitled documents become litter

**Files:**
- Modify: `App/macOS/Sources/ScratchStore.swift`, `App/macOS/Sources/MainWindow.swift` (`persistSession`)
- Create: `Sources/QuoinCore/ScratchHousekeeping.swift`
- Test: `Tests/QuoinCoreTests/ScratchHousekeepingTests.swift` (create)

**Interfaces:**
- Consumes: `ScratchStore.existingUntitled()`.
- Produces: `ScratchHousekeeping.shouldPersistSession(tabCount:onlyTabIsEmptyScratch:) -> Bool`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuoinCore

/// A blank auto-created untitled document must not reopen forever.
final class ScratchHousekeepingTests: XCTestCase {

    func testASoleEmptyScratchTabIsNotPersisted() {
        XCTAssertFalse(ScratchHousekeeping.shouldPersistSession(
            tabCount: 1, onlyTabIsEmptyScratch: true))
    }

    func testARealDocumentIsPersisted() {
        XCTAssertTrue(ScratchHousekeeping.shouldPersistSession(
            tabCount: 1, onlyTabIsEmptyScratch: false))
    }

    func testAnEmptyScratchAlongsideRealTabsIsPersisted() {
        XCTAssertTrue(ScratchHousekeeping.shouldPersistSession(
            tabCount: 3, onlyTabIsEmptyScratch: false))
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter ScratchHousekeepingTests`
Expected: FAIL — `cannot find 'ScratchHousekeeping' in scope`.

- [ ] **Step 3: Implement and wire**

```swift
/// Keeps auto-created untitled documents from becoming litter.
public enum ScratchHousekeeping {
    /// A window whose ONLY tab is an untouched untitled document has nothing
    /// worth restoring — persisting it would reopen a blank note forever.
    public static func shouldPersistSession(
        tabCount: Int, onlyTabIsEmptyScratch: Bool
    ) -> Bool {
        !(tabCount == 1 && onlyTabIsEmptyScratch)
    }
}
```

Call it from `persistSession`, computing `onlyTabIsEmptyScratch` with the same test
`close()` already applies at `MainWindow.swift:797` (`ScratchStore.isScratch` plus
whitespace-trimmed-empty contents). Then add a launch-time GC to `ScratchStore`:

```swift
    /// Delete untitled documents that were never typed into. Mirrors the
    /// on-close GC (MainWindow.close) so a crash or a force-quit can't leave a
    /// pile of blank notes to reopen.
    static func purgeEmptyUntitled() {
        for url in existingUntitled() {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
```

Call `purgeEmptyUntitled()` in `applicationDidFinishLaunching` BEFORE any window
reopens scratch documents (`MainWindow.swift:348`), or the purge races the reopen.

- [ ] **Step 4: Run the test**

Run: `swift test --filter ScratchHousekeepingTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Verify the full loop**

Launch (untitled appears), quit without typing, relaunch. Expected: exactly ONE
blank untitled document, not an accumulating pile. Then: launch, type text, quit,
relaunch — the typed document must come back.

- [ ] **Step 6: Run everything and commit**

```bash
swift test
cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build
git add App/macOS/Sources/ Sources/QuoinCore/ScratchHousekeeping.swift Tests/QuoinCoreTests/ScratchHousekeepingTests.swift
git commit -m "Untitled documents don't accumulate: session guard + launch GC"
git push origin main
```

---

## Final verification

- [ ] `swift test` — full suite green.
- [ ] App builds: `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build`.
- [ ] **The reported bug, by hand:** fresh launch → type a line → press Return →
      the caret moves and a new paragraph exists. Mid-document too.
- [ ] **Round-trip:** four Returns, ⌘S, reopen — bytes identical to what was typed.
- [ ] **No table was harmed:** Return at the end of a table row adds a row.
- [ ] **Existing documents untouched:** open `~/Documents/ClintNotes/Quoin UX Test.md`
      (the kitchen-sink fixture), confirm it renders identically to `main` and that
      ⌘S produces a byte-identical file. Be gentle — these are real notes.
- [ ] Update `docs/reference/rendering-ledger.md` and `docs/reference/invariants.md`
      with the absorption rule and the Return rule table.
