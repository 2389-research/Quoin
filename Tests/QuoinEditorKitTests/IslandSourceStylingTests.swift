#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 3: the ACTIVE island renders its raw Markdown source STYLED — per-line
/// type ramp, faded delimiters — instead of uniform mono, so edit mode "keeps
/// the block's vertical skeleton" (handoff §1; CLAUDE.md's per-line style
/// transplant).
///
/// Four properties are load-bearing here, in this order of importance:
///
///  1. **The string is sacred.** Styling is ATTRIBUTES ONLY. `IslandCaretMapping`,
///     Return-split, backspace-merge and the flush/reconcile path all compute
///     offsets against `islandTextView.string`; a styler that inserted, removed
///     or substituted a single character would desynchronize all of them.
///  2. **Per-line type ramp.** A `## Foo` line carries the H2 ramp value the
///     RENDERER uses, not a hardcoded number — the two paths agreeing is the
///     whole point.
///  3. **Delimiter treatment**, exactly as the handoff splits it: structural
///     line prefixes stay faded-visible; an inline span's delimiters appear
///     ONLY while the caret is inside that span.
///  4. **Height agreement** with `BlockRenderCell` for the same block+width, so
///     activating a block does not shove the page.
@MainActor
final class IslandSourceStylingTests: XCTestCase {

    private let theme = Theme()
    private var renderer: AttributedRenderer { AttributedRenderer(theme: theme) }

    /// A cell in a real ordered-in window with the production styler installed —
    /// the SAME closure `BlockRecyclerView.editorView(for:)` installs.
    private func makeCell(_ slice: String, width: CGFloat = 600)
        -> (cell: BlockEditorCell, window: NSWindow)
    {
        let cell = BlockEditorCell()
        let window = OffscreenTestWindow.make(width: width, height: 400)
        window.contentView = cell
        window.makeKeyAndOrderFront(nil)
        let renderer = self.renderer
        cell.sourceStyler = { source, caret in
            renderer.styledIslandSource(source, caretUTF16: caret)
        }
        cell.configure(slice: slice, blockID: BlockID(contentHash: 7, occurrence: 0), width: width)
        window.makeFirstResponder(cell.islandTextView)
        return (cell, window)
    }

    private func font(_ text: NSAttributedString, at index: Int) -> NSFont? {
        text.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    private func color(_ text: NSAttributedString, at index: Int) -> NSColor? {
        text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    // MARK: - 1. String integrity (the most important property)

    /// Every block family: after styling — and again after a keystroke restyles
    /// — the island's text is EXACTLY the source it was seeded with.
    func testStylingNeverChangesTheSourceBytes() {
        let slices = [
            "## Headings and structure lol",
            "A paragraph with **bold**, *em*, `code`, a [link](https://example.com) and a — dash.",
            "- one\n- two\n- [ ] three",
            "> quoted line one\n> quoted line two",
            "```swift\nlet x = 1\n```",
            "| a | b |\n| --- | --- |\n| 1 | 2 |",
        ]
        for slice in slices {
            let (cell, _) = makeCell(slice)
            XCTAssertEqual(cell.islandTextView.string, slice,
                           "styling must not change one byte of the source")
            XCTAssertEqual(cell.styledTextForTest.string, slice,
                           "the attributed string's characters ARE the source")

            // …and it survives a real keystroke + the restyle it triggers.
            cell.islandTextView.setSelectedRange(NSRange(location: (slice as NSString).length, length: 0))
            cell.islandTextView.insertText("Z", replacementRange: cell.islandTextView.selectedRange())
            XCTAssertEqual(cell.islandTextView.string, slice + "Z",
                           "a keystroke + restyle must leave exactly source+keystroke")
            XCTAssertEqual(cell.styledTextForTest.string, slice + "Z")
        }
    }

    /// The 1:1 contract is ENFORCED, not merely respected: a styler that returns
    /// a different string is refused and the source survives unstyled.
    func testAByteChangingStylerIsRefused() {
        let cell = BlockEditorCell()
        let window = OffscreenTestWindow.make(width: 400, height: 100)
        window.contentView = cell
        window.makeKeyAndOrderFront(nil)
        cell.sourceStyler = { source, _ in
            // The classic wrong fix: "hide" the delimiter by deleting it.
            NSAttributedString(string: source.replacingOccurrences(of: "## ", with: ""))
        }
        cell.configure(slice: "## Title", blockID: BlockID(contentHash: 1, occurrence: 0), width: 400)
        XCTAssertEqual(cell.islandTextView.string, "## Title",
                       "a byte-changing styler must be refused outright")
        XCTAssertEqual(cell.restyleCountForTest, 0, "…and must not have been applied")
    }

    // MARK: - 2. Per-line type ramp

    /// `## Foo` gets the H2 ramp; the value is compared against the THEME the
    /// renderer draws from, never a literal.
    func testHeadingLineCarriesTheHeadingRamp() {
        let (cell, _) = makeCell("## Headings and structure lol")
        let styled = cell.styledTextForTest
        // Index 3 is the first character after "## ".
        XCTAssertEqual(font(styled, at: 3), theme.headingFont(level: 2),
                       "the heading BODY must use the H2 face the renderer uses")
        XCTAssertNotEqual(font(styled, at: 3), NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                          "…and must no longer be the Phase-2 mono seed face")
        XCTAssertEqual(color(styled, at: 3), theme.ink, "H1–H3 render in full ink")

        // And the paragraph ramp for prose.
        let (para, _) = makeCell("Just some prose.")
        XCTAssertEqual(font(para.styledTextForTest, at: 0), theme.bodyFont())
    }

    /// The per-line transplant: in a multi-line island, EACH line keeps the
    /// typography of what it renders as. (A list is the cheapest multi-line
    /// case whose lines all render the same; the heading-vs-body contrast is
    /// covered by the height test, which compares whole blocks.)
    func testEveryHeadingLevelUsesItsOwnRamp() {
        for level in 1...4 {
            let hashes = String(repeating: "#", count: level)
            let (cell, _) = makeCell("\(hashes) Title")
            XCTAssertEqual(font(cell.styledTextForTest, at: level + 1),
                           theme.headingFont(level: level),
                           "H\(level) body must carry the H\(level) face")
        }
    }

    // MARK: - 3. Delimiter treatment

    /// The handoff's delimiter treatment — "35% ink in mono" — on the `## `
    /// prefix, sourced from the Theme rather than restated.
    func testStructuralPrefixIsFadedMono() {
        let (cell, _) = makeCell("## Headings and structure lol")
        let styled = cell.styledTextForTest
        for index in 0..<3 {                          // '#', '#', ' '
            XCTAssertEqual(font(styled, at: index), theme.inlineCodeFont(),
                           "the heading marks render in mono (handoff § syntax reveal)")
            XCTAssertEqual(color(styled, at: index), theme.ink.withAlphaComponent(0.35),
                           "…at 35% ink")
        }
    }

    /// A list marker is STRUCTURAL: it stays faded-VISIBLE wherever the caret
    /// is (CLAUDE.md: "structural line prefixes (`>`, `- [ ]`) stay
    /// faded-visible"), unlike an inline span's delimiters.
    func testListAndQuoteMarkersStayVisibleRegardlessOfCaret() {
        let (cell, _) = makeCell("- one\n- two")
        // Caret parked on the FIRST line; the second line's marker must still show.
        cell.islandTextView.setSelectedRange(NSRange(location: 2, length: 0))
        let styled = cell.styledTextForTest
        let secondMarker = 6                          // the '-' of "- two"
        XCTAssertEqual(font(styled, at: secondMarker), theme.inlineCodeFont())
        XCTAssertEqual(color(styled, at: secondMarker), theme.ink.withAlphaComponent(0.35))
        XCTAssertGreaterThan(font(styled, at: secondMarker)?.pointSize ?? 0, 1,
                             "a structural marker is faded, never collapsed to a hairline")

        let (quote, _) = makeCell("> a\n> b")
        XCTAssertEqual(color(quote.styledTextForTest, at: 4),
                       theme.ink.withAlphaComponent(0.35),
                       "the second '>' stays faded-visible with the caret elsewhere")
    }

    /// An INLINE span is caret-scoped: "Delimiters appear **only** for the span
    /// containing the caret" (handoff). Move the caret; the attribute flips.
    func testInlineSpanDelimitersRevealOnlyUnderTheCaret() {
        //         0123456789...
        let slice = "say **bold** now"
        let (cell, _) = makeCell(slice)
        let openStar = 4

        // Caret INSIDE the span → faded-visible mono delimiters.
        cell.islandTextView.setSelectedRange(NSRange(location: 8, length: 0))
        var styled = cell.styledTextForTest
        XCTAssertEqual(font(styled, at: openStar), theme.inlineCodeFont())
        XCTAssertEqual(color(styled, at: openStar), theme.ink.withAlphaComponent(0.35))

        // Caret OUTSIDE → the delimiters collapse. They are NEVER removed: the
        // characters are still there, at a hairline clear glyph (the 1:1 rule).
        cell.islandTextView.setSelectedRange(NSRange(location: 0, length: 0))
        styled = cell.styledTextForTest
        XCTAssertEqual(styled.string, slice, "collapsing is styling, not deletion")
        XCTAssertLessThan(font(styled, at: openStar)?.pointSize ?? 99, 1,
                          "an unfocused span's delimiters collapse to a hairline")
        XCTAssertEqual(color(styled, at: openStar), NSColor.clear)
        // The CONTENT keeps its rendered look either way.
        XCTAssertEqual(font(styled, at: 6), theme.boldBodyFont())
    }

    // MARK: - 4. Height / skeleton agreement

    /// The user's "doesn't preserve the layout": the island's measured height
    /// for an UNEDITED block must be within a small epsilon of the read cell's
    /// height for the same block at the same width.
    ///
    /// **Epsilon is 6pt** — under half a body line (14pt at 1.4 ≈ 19.6pt), so a
    /// whole extra rendered line cannot hide inside it, while the genuinely
    /// unavoidable delta does fit: the island shows the `## ` / `- ` / `> `
    /// delimiters the read projection does not (advance width, so a near-full
    /// line can wrap one word earlier) and a task checkbox is an attachment in
    /// the read projection but two mono glyphs in the source.
    ///
    /// SOFT-WRAPPED SOURCE IS EXCLUDED and covered by its own test below: when a
    /// paragraph or quote is hard-wrapped in the file, its source genuinely has
    /// more lines than its render, and no amount of styling can draw three lines
    /// in one line's height without deleting characters (which the 1:1 rule
    /// forbids). That is a real, permanent delta — see
    /// `testSoftWrappedSourceGrowsByExactlyItsExtraLines`.
    func testIslandHeightMatchesTheReadCellHeight() {
        let cases: [(name: String, markdown: String)] = [
            ("heading", "## Headings and structure lol"),
            ("paragraph", "A paragraph of ordinary prose that is long enough to be interesting "
                        + "but not so long that it wraps unpredictably at 600 points."),
            ("list", "- one\n- two\n- three"),
            ("tasks", "- [ ] todo\n- [x] done"),
            ("table", "| a | b |\n| --- | --- |\n| 1 | 2 |"),
        ]
        let width: CGFloat = 600
        var report: [String] = []
        for (name, markdown) in cases {
            let (islandHeight, readHeight) = heights(of: markdown, width: width)
            report.append("\(name): island=\(islandHeight) read=\(readHeight) "
                          + "delta=\(islandHeight - readHeight)")
            XCTAssertEqual(islandHeight, readHeight, accuracy: 6,
                           "\(name): activating a block must not change its height — "
                           + report.joined(separator: " | "))
        }
        // Printed so the report can quote real numbers, not adjectives.
        print("[island-height] " + report.joined(separator: "\n[island-height] "))
    }

    /// The one delta that CANNOT be closed, pinned so it cannot silently grow:
    /// a hard-wrapped paragraph/quote has N source lines and one rendered
    /// paragraph, so the island is taller by the extra lines — and by NOTHING
    /// ELSE. (Before the interior-gap collapse, each extra line also dragged the
    /// 12pt inter-block gap along with it; that is what this bounds.)
    func testSoftWrappedSourceGrowsByExactlyItsExtraLines() {
        // Self-calibrated, not computed from the ramp: `lineHeightMultiple`
        // scales the FONT'S natural line height, not its point size, so the
        // arithmetic answer (14 × 1.4 = 19.6) is not the laid-out one (23.8).
        // Measure one body line instead of restating it.
        let bodyLine = heights(of: "x", width: 600).read
        let cases: [(name: String, markdown: String, extraLines: CGFloat)] = [
            ("hard-wrapped paragraph", "One source line.\nA second source line.\nA third.", 2),
            ("soft-wrapped quote", "> quoted line one\n> quoted line two", 1),
        ]
        var report: [String] = []
        for (name, markdown, extraLines) in cases {
            let (islandHeight, readHeight) = heights(of: markdown, width: 600)
            let delta = islandHeight - readHeight
            report.append("\(name): island=\(islandHeight) read=\(readHeight) delta=\(delta) "
                          + "budget=\(extraLines * bodyLine)")
            XCTAssertEqual(delta, extraLines * bodyLine, accuracy: 6,
                           "\(name): the island may grow by its extra SOURCE lines and no more — "
                           + report.joined(separator: " | "))
        }
        print("[island-height] " + report.joined(separator: "\n[island-height] "))
    }

    /// EMBED blocks are NOT skeleton-preserving yet, and this test says so out
    /// loud rather than leaving it to be discovered in the app. A fenced code
    /// block renders as a canvas with a `swift ‹/› edit ⧉ copy` header row and
    /// no fence lines; its island shows the two fence lines and no header. The
    /// delta is bounded and pinned here so it cannot grow unnoticed, and so the
    /// day embed islands grow their own chrome this test is the one that fails.
    func testEmbedIslandsAreNotYetHeightMatched() {
        let (island, read) = heights(of: "```swift\nlet x = 1\nprint(x)\n```", width: 600)
        print("[island-height] code fence: island=\(island) read=\(read) delta=\(island - read)")
        XCTAssertGreaterThan(island - read, 6,
                             "if this ever passes, embed islands got height-matched — "
                             + "move the case into testIslandHeightMatchesTheReadCellHeight")
        XCTAssertLessThan(island - read, 40,
                          "the embed delta must stay bounded (island=\(island) read=\(read))")
    }

    /// Island vs read-cell text height for one block's markdown at `width`.
    private func heights(of markdown: String, width: CGFloat) -> (island: CGFloat, read: CGFloat) {
        let doc = MarkdownConverter.parse(markdown)
        let block = doc.blocks[0]
        let read = BlockRenderCell()
        read.configure(block: block, document: doc, renderer: renderer, theme: theme, width: width)
        let (island, _) = makeCell(doc.source.substring(in: block.range)!, width: width)
        return (island.fittingHeightForConfiguredWidth, read.fittingHeightForConfiguredWidth)
    }

    /// Anti-vacuity for the epsilon above: the UNSTYLED (Phase-2 mono) island is
    /// NOT within it for a heading, so the test above is measuring the fix, not
    /// a coincidence.
    func testUnstyledIslandMissesTheHeightAgreementItIsAskedFor() {
        let doc = MarkdownConverter.parse("## Headings and structure lol")
        let block = doc.blocks[0]
        let read = BlockRenderCell()
        read.configure(block: block, document: doc, renderer: renderer, theme: theme, width: 600)

        let bare = BlockEditorCell()                   // no sourceStyler → mono seed
        let window = OffscreenTestWindow.make(width: 600, height: 200)
        window.contentView = bare
        window.makeKeyAndOrderFront(nil)
        bare.configure(slice: doc.source.substring(in: block.range)!,
                       blockID: block.id, width: 600)

        XCTAssertGreaterThan(
            abs(read.fittingHeightForConfiguredWidth - bare.fittingHeightForConfiguredWidth), 6,
            "the mono island really is the wrong height for a heading "
            + "(read=\(read.fittingHeightForConfiguredWidth) mono=\(bare.fittingHeightForConfiguredWidth))")
    }

    /// The ROW arithmetic, not just the text: an interior editing row must keep
    /// the decoration bleed AND the inter-block separator contribution the read
    /// row has, or everything below it jumps up by the whole block gap.
    func testEditingRowKeepsTheSeparatorContribution() {
        let doc = MarkdownConverter.parse("First para.\n\nSecond para.\n\nThird para.")
        let block = doc.blocks[1]
        let readRow = BlockRowMetrics.rowHeight(
            for: block, at: 1, in: doc, renderer: renderer, theme: theme, width: 600)
        let editingRow = BlockRowMetrics.rowHeight(
            forTextHeight: renderer.measuredHeight(of: block, in: doc, width: 600),
            of: block, at: 1, in: doc, renderer: renderer, width: 600)
        XCTAssertEqual(editingRow, readRow, accuracy: 0.001,
                       "with the same text height the editing row must equal the read row")
        XCTAssertGreaterThan(
            readRow - renderer.measuredHeight(of: block, in: doc, width: 600),
            2 * DecorationDraw.verticalBleed,
            "anti-vacuity: an interior prose row really does carry a separator gap")
    }

    // MARK: - 5. Restyle on type, and no re-entrancy

    /// Typing inside a heading keeps that line on the H2 ramp, and the restyle
    /// is BOUNDED — one attribute pass per keystroke, not a notification loop.
    func testTypingRestylesWithoutRunaway() {
        let (cell, _) = makeCell("## Head")
        let baseline = cell.restyleCountForTest
        var changeNotifications = 0
        cell.onTextDidChange = { changeNotifications += 1 }

        let tv = cell.islandTextView
        for character in ["i", "n", "g"] {
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            tv.insertText(character, replacementRange: tv.selectedRange())
        }

        XCTAssertEqual(tv.string, "## Heading")
        XCTAssertEqual(font(cell.styledTextForTest, at: 3), theme.headingFont(level: 2),
                       "typing in a heading keeps the heading ramp on that line")
        XCTAssertEqual(font(cell.styledTextForTest, at: 9), theme.headingFont(level: 2),
                       "…including the characters just typed")
        XCTAssertEqual(changeNotifications, 3,
                       "the restyle must not echo back as extra text-change notifications")
        // Three keystrokes → three restyles, plus at most a few caret-move
        // restyles from the explicit selection sets. A re-entrant loop is
        // unbounded, so any small constant falsifies it.
        XCTAssertLessThanOrEqual(cell.restyleCountForTest - baseline, 9,
                                 "restyle count \(cell.restyleCountForTest - baseline) suggests a loop")
        XCTAssertGreaterThanOrEqual(cell.restyleCountForTest - baseline, 3,
                                    "anti-vacuity: the restyle instrument must actually fire")
    }

    /// A caret move alone restyles (the span reveal depends on it) but is
    /// idempotent: parking the caret in the same place twice does no second pass.
    func testCaretMoveRestylesOnceAndOnlyWhenItMoves() {
        let (cell, _) = makeCell("say **bold** now")
        cell.islandTextView.setSelectedRange(NSRange(location: 8, length: 0))
        let after = cell.restyleCountForTest
        cell.islandTextView.setSelectedRange(NSRange(location: 8, length: 0))
        XCTAssertEqual(cell.restyleCountForTest, after,
                       "a no-op selection change must not restyle")
        cell.islandTextView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(cell.restyleCountForTest, after + 1,
                       "a real caret move restyles exactly once")
    }

    // MARK: - Horizontal / vertical alignment with the read cell

    /// `BlockRenderCell` draws its glyphs shifted by `(leftGutter,
    /// verticalBleed)` inside a row that reserves that chrome padding. The
    /// island must start its glyphs at the SAME origin, or the text slides 14pt
    /// left and 5pt up the instant a block is activated — a layout jump the
    /// height tests cannot see because it is horizontal.
    func testIslandGlyphOriginMatchesTheReadCell() {
        let (cell, _) = makeCell("Some prose.")
        XCTAssertEqual(cell.islandTextView.textContainerInset.width,
                       DecorationDraw.leftGutter, accuracy: 0.001)
        XCTAssertEqual(cell.islandTextView.textContainerInset.height,
                       DecorationDraw.verticalBleed, accuracy: 0.001)
    }

    /// The inset's sharp edge, pinned: a non-click activation passes the ROW's
    /// top-left `(0, 0)`, which now sits in the padding — outside the text
    /// container. AppKit answers an out-of-box point with a nonsense index that
    /// clamps to END OF BLOCK, so the caret landed after the last character
    /// instead of before the first.
    func testActivatingAtTheRowTopLeftPutsTheCaretAtTheStart() {
        let doc = MarkdownConverter.parse("# Title\n\nHello world.\n\nTail.")
        let recycler = BlockRecyclerView(renderer: renderer, theme: theme)
        let window = OffscreenTestWindow.make(width: 640, height: 480)
        window.contentView = recycler
        recycler.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        recycler.setDocument(doc, contentWidth: 600)
        recycler.layoutSubtreeIfNeeded()
        let controller = IslandController(recycler: recycler)

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero,
                            in: doc, baseRevision: 0)

        XCTAssertEqual(recycler.currentEditorCell?.islandTextView.selectedRange().location, 0,
                       "the row's top-left must resolve to the START of the block")
    }

    // MARK: - Wiring

    /// The production recycler installs the styler — otherwise every assertion
    /// above tests a code path the app never takes.
    func testRecyclerInstallsTheStylerOnTheIslandItVends() throws {
        let doc = MarkdownConverter.parse("## Headings and structure lol\n\nBody text.")
        let recycler = BlockRecyclerView(renderer: renderer, theme: theme)
        let window = OffscreenTestWindow.make(width: 640, height: 480)
        window.contentView = recycler
        defer { window.contentView = nil; window.close() }
        recycler.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        recycler.setDocument(doc, contentWidth: 600)
        recycler.layoutSubtreeIfNeeded()

        // `try XCTUnwrap`, not `try? XCTUnwrap`: the `try?` form swallows the
        // throw, so every assertion below then ran against `nil` optionals and the
        // failure message pointed at the wrong line.
        let island = try XCTUnwrap(recycler.promoteRow(to: doc.blocks[0].id),
                                   "the recycler must vend an editor cell for the promoted row")
        XCTAssertNotNil(island.sourceStyler, "the recycler must install a source styler")
        let styled = island.styledTextForTest
        XCTAssertEqual(styled.string, "## Headings and structure lol")
        XCTAssertEqual(styled.attribute(.font, at: 3, effectiveRange: nil) as? NSFont,
                       theme.headingFont(level: 2),
                       "the vended island renders its heading on the H2 ramp")
        // Anti-vacuity: the H2 face must not be the mono seed the unstyled island
        // uses, or "the styler is installed" would hold for a styler that did
        // nothing.
        XCTAssertNotEqual(styled.attribute(.font, at: 3, effectiveRange: nil) as? NSFont,
                          NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    }
}
#endif
