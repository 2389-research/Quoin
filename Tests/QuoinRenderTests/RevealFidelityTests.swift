#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Reveal round-trip fidelity: activating a block must not leave residue
/// when it closes, and must not change the block's height when it opens.
final class RevealFidelityTests: XCTestCase {

    private let source = """
    # Reveal fidelity

    First paragraph of prose, plain as can be, with no markup at all here.

    Second paragraph, equally plain, sitting right below the first one.

    ### A heading to reveal

    Closing paragraph under the heading for good measure.
    """

    /// The sticky-tint regression: a PLAIN paragraph's revealed source is
    /// the same STRING as its rendered text — only attributes differ. When
    /// a deactivation lands via the resync path (string-equal splice), the
    /// old splice "changed nothing" and left the reveal tint behind. The
    /// attribute sync must remove it.
    func testResyncRemovesRevealTintWhenStringsAreEqual() throws {
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let para = try XCTUnwrap(document.blocks.first {
            if case .paragraph = $0.kind { return true }
            return false
        }?.id)

        // Storage holds the ACTIVE projection (tinted paragraph)…
        let active = renderer.render(document, activeBlockID: para, activeCaret: 3, cache: &cache)
        let storage = NSTextStorage()
        storage.setAttributedString(active.attributed)
        let tint = renderer.theme.accent.withAlphaComponent(0.05)
        let activeRange = try XCTUnwrap(active.activeEditableRange)
        let tinted = storage.attribute(.backgroundColor, at: activeRange.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(tinted, tint, "test premise: the revealed block is tinted")

        // …and the model publishes the READING projection with NO patches
        // (the resync path — what a skipped patch revision falls back to).
        cache.removeAll()
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let projection = RenderedDocument(
            attributed: reading.attributed, blockRanges: reading.blockRanges, revision: 7)
        _ = MarkdownReaderView.Coordinator.applyProjection(projection, to: storage)

        // The tint (and every other reveal attribute) must be gone.
        var residue = 0
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let color = value as? NSColor, color == tint { residue += 1 }
        }
        XCTAssertEqual(residue, 0, "reveal tint survived a string-equal resync")
        XCTAssertEqual(storage.string, reading.attributed.string)
    }

    /// A plain paragraph's revealed fragment must occupy exactly the height
    /// of its rendered fragment — same string, same font, same line metrics,
    /// same outer spacing — so click-to-edit doesn't shift the content below.
    func testPlainParagraphRevealIsHeightNeutral() throws {
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let para = try XCTUnwrap(document.blocks.first {
            if case .paragraph = $0.kind { return true }
            return false
        }?.id)

        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let revealed = renderer.render(document, activeBlockID: para, activeCaret: 3, cache: &cache)
        XCTAssertEqual(measureHeight(reading.attributed),
                       measureHeight(revealed.attributed),
                       accuracy: 1.0,
                       "revealing a plain paragraph must not change the document height")
    }

    /// A heading's reveal changes fonts by design (source view), but its
    /// OUTER spacing must hold so the shift stays small — bounded well under
    /// the ~30pt lurch the missing spacing-above used to cause.
    func testHeadingRevealKeepsOuterSpacing() throws {
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let heading = try XCTUnwrap(document.blocks.first {
            if case .heading(let level, _, _) = $0.kind { return level == 3 }
            return false
        }?.id)

        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let revealed = renderer.render(document, activeBlockID: heading, activeCaret: 3, cache: &cache)
        let delta = abs(measureHeight(reading.attributed) - measureHeight(revealed.attributed))
        XCTAssertLessThan(delta, 8, "heading reveal shifted content by \(delta)pt")
    }

    /// THE reported symptom: "spacing between lines goes away in edit mode
    /// and comes back in real mode." A hard-break paragraph's rendered lines
    /// carry the body's paragraph spacing; the revealed source must carry
    /// the same per-line metrics, keeping the reveal height-neutral.
    func testHardBreakParagraphRevealIsHeightNeutral() throws {
        let hardBreakSource = """
        # Interior spacing

        This line ends with two spaces.  \u{20}
        This line should appear after a hard line break.  \u{20}
        And a third line to make the gaps unmissable.

        Tail paragraph.
        """
        let document = MarkdownConverter.parse(hardBreakSource)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let para = try XCTUnwrap(document.blocks.first {
            if case .paragraph = $0.kind { return true }
            return false
        }?.id)

        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let revealed = renderer.render(document, activeBlockID: para, activeCaret: 3, cache: &cache)
        XCTAssertEqual(measureHeight(reading.attributed),
                       measureHeight(revealed.attributed),
                       accuracy: 2.0,
                       "hard-break paragraph reveal must keep its interior line spacing")
    }

    /// List items keep their gaps and indents when the list reveals.
    func testListRevealKeepsItemSpacing() throws {
        let listSource = """
        # Lists

        - first item of the list
        - second item of the list
        - third item of the list

        Tail paragraph.
        """
        let document = MarkdownConverter.parse(listSource)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let list = try XCTUnwrap(document.blocks.first {
            if case .list = $0.kind { return true }
            return false
        }?.id)

        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let revealed = renderer.render(document, activeBlockID: list, activeCaret: 3, cache: &cache)
        let delta = abs(measureHeight(reading.attributed) - measureHeight(revealed.attributed))
        XCTAssertLessThan(delta, 6, "list reveal shifted content by \(delta)pt")
    }

    /// LOOSE lists (blank lines between items) — the live report's shape:
    /// the reveal showed the transplanted item gap AND a compressed blank
    /// row for every source blank line, spreading items ~2x.
    func testLooseNestedListRevealIsHeightNeutral() throws {
        var listSource = "# Loose\n\n"
        listSource += "1. Item one\n\n"
        listSource += "   1. Nested item one\n\n"
        listSource += "      Paragraph under nested item.\n\n"
        listSource += "   2. Nested item two\n\n"
        listSource += "2. Item two after nested list.\n\n"
        listSource += "Tail paragraph.\n"
        let document = MarkdownConverter.parse(listSource)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let list = try XCTUnwrap(document.blocks.first {
            if case .list = $0.kind { return true }
            return false
        }?.id)

        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let revealed = renderer.render(document, activeBlockID: list, activeCaret: 3, cache: &cache)
        let delta = abs(measureHeight(reading.attributed) - measureHeight(revealed.attributed))
        XCTAssertLessThan(delta, 14, "loose nested list reveal shifted content by \(delta)pt")
    }

    /// The traced +100..364pt reveals: entity- and markup-dense paragraphs
    /// exploded on reveal because their source is several times longer than
    /// their rendered text. With caret-scoped collapse of entities (and
    /// URLs before them), the reveal must stay near height-neutral even at
    /// a narrow column.
    func testEntityDenseParagraphRevealIsNearHeightNeutral() throws {
        var source = "# Entities\n\n"
        source += "HTML entities: &amp; &lt; &gt; &quot; &apos; &copy; &trade; &mdash; &ndash; &#169; &#x1F680; and once more &amp; &lt; &gt; &quot; &apos; &copy; &trade; &mdash; &ndash; for width.\n\n"
        source += "Tail paragraph.\n"
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let para = try XCTUnwrap(document.blocks.dropFirst().first {
            if case .paragraph = $0.kind { return true }
            return false
        }?.id)
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let revealed = renderer.render(document, activeBlockID: para, activeCaret: 0, cache: &cache)
        let delta = abs(measureHeight(reading.attributed, width: 500) - measureHeight(revealed.attributed, width: 500))
        XCTAssertLessThan(delta, 40, "entity-dense reveal reflowed by \(delta)pt")
    }

    /// Task #71: revealing a pure HTML-comment block showed the opening
    /// `<!--` but never the closing `-->` — cmark reported the block's
    /// source range one line short, so the "1:1" slice (and with it the
    /// editable area AND the view height) lost the final line. The revealed
    /// string must equal the source slice, closing marker included, on both
    /// projection paths (full render and activation-flip patch).
    func testPureHTMLCommentRevealIsOneToOneIncludingClosingMarker() throws {
        let commentSource = """
        <!--
        section_id: abc-123
        note: stress header
        -->

        Body paragraph after the comment.
        """
        let document = MarkdownConverter.parse(commentSource)
        let renderer = AttributedRenderer()
        let comment = try XCTUnwrap(document.blocks.first {
            if case .htmlBlock = $0.kind { return true }
            return false
        })
        let slice = try XCTUnwrap(document.source.substring(in: comment.range))
        XCTAssertTrue(slice.hasSuffix("-->"), "test premise: the slice carries the closing marker")

        // Full render path: the editable area is the whole slice, 1:1.
        var cache: [BlockID: NSAttributedString] = [:]
        let active = renderer.render(document, activeBlockID: comment.id, activeCaret: 0, cache: &cache)
        let editable = try XCTUnwrap(active.activeEditableRange)
        XCTAssertEqual((active.attributed.string as NSString).substring(with: editable), slice,
                       "revealed source must be character-for-character the block's slice")

        // Flip-patch path must agree byte-for-byte with the full render.
        cache.removeAll()
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let flip = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: reading, from: nil, to: comment.id, caret: 0))
        let storage = NSMutableAttributedString(attributedString: reading.attributed)
        for patch in flip.storagePatches {
            storage.replaceCharacters(in: patch.oldRange, with: patch.replacement)
        }
        XCTAssertEqual(storage.string, active.attributed.string,
                       "activation flip patch drifted from the full render")
        let flipEditable = try XCTUnwrap(flip.activeEditableRange)
        XCTAssertEqual((storage.string as NSString).substring(with: flipEditable), slice)
    }

    /// Issue #1: footnote definitions are READ-ONLY. Their first-block ranges
    /// used to be published into `blockRanges`, so a click/keystroke in the
    /// appended footnote section resolved to a block id the model can't find
    /// (footnote blocks live in `document.footnotes`, not `document.blocks`),
    /// stranding activation on a phantom block. The renderer must NOT publish
    /// any footnote definition block id as an editable range, so a hit-test in
    /// the footnote region finds no block and activation is a clean no-op.
    func testFootnoteDefinitionsAreNotPublishedAsEditableBlocks() throws {
        let footnoteSource = """
        # Footnotes

        First mention.[^alpha] Second mention.[^beta]

        [^alpha]: The alpha definition text.
        [^beta]: The beta definition text.
        """
        let document = MarkdownConverter.parse(footnoteSource)
        XCTAssertEqual(document.footnotes.count, 2, "test premise: two gathered footnotes")

        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let rendered = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)

        // No footnote definition block id is an editable range key.
        for footnote in document.footnotes {
            for block in footnote.blocks {
                XCTAssertNil(rendered.blockRanges[block.id],
                             "footnote \(footnote.id) block leaked into editable blockRanges")
            }
        }

        // A hit-test anywhere in a tagged definition region resolves to no
        // block range — the click is a no-op, never a broken activation.
        rendered.attributed.enumerateAttribute(
            QuoinAttribute.footnoteDefinitionID,
            in: NSRange(location: 0, length: rendered.attributed.length)
        ) { value, range, _ in
            guard value is String else { return }
            for index in [range.location, range.location + range.length / 2, NSMaxRange(range) - 1] {
                let hit = rendered.blockRanges.first { _, r in
                    index >= r.location && index < NSMaxRange(r)
                }
                XCTAssertNil(hit, "footnote char \(index) is inside an editable block range")
            }
        }

        // The jump/hover plumbing still works: every definition keeps its
        // `footnoteDefinitionID` tag (keyed off attributes, not blockRanges).
        for footnote in document.footnotes {
            var found = false
            rendered.attributed.enumerateAttribute(
                QuoinAttribute.footnoteDefinitionID,
                in: NSRange(location: 0, length: rendered.attributed.length)
            ) { value, _, stop in
                if value as? String == footnote.id { found = true; stop.pointee = true }
            }
            XCTAssertTrue(found, "footnote \(footnote.id) lost its definition tag")
        }
    }

    /// R1: a LONG paragraph that soft-wraps to several visual lines must reveal
    /// height-neutrally too. The other paragraph cases are short enough not to
    /// wrap at the measured width, so they never exposed a per-line metric
    /// mismatch on the wrapped lines. Measured at a narrow width to force wrap.
    func testWrappedParagraphRevealIsHeightNeutral() throws {
        let longSource = """
        # Wrapping

        This is a deliberately long paragraph of ordinary prose with no markup \
        at all, written to be far wider than the measuring container so that it \
        soft-wraps across several visual lines, which is exactly the case where \
        a per-line metric mismatch between the rendered body and the revealed \
        source would balloon the line height on activation.
        """
        let document = MarkdownConverter.parse(longSource)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let para = try XCTUnwrap(document.blocks.first {
            if case .paragraph = $0.kind { return true }
            return false
        }?.id)

        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let revealed = renderer.render(document, activeBlockID: para, activeCaret: 3, cache: &cache)
        XCTAssertEqual(measureHeight(reading.attributed, width: 320),
                       measureHeight(revealed.attributed, width: 320),
                       accuracy: 1.0,
                       "revealing a soft-wrapped paragraph must not change the document height")
    }

    /// R1 (the version the height test missed): a paragraph HARD-WRAPPED in the
    /// source — real newlines that Markdown joins into ONE paragraph via soft
    /// breaks — was revealed with the read paragraph's trailing `paragraphSpacing`
    /// (12pt) copied onto EVERY source line, so a 12pt gap appeared between each
    /// line and the block ballooned on activation. `testWrappedParagraphReveal…`
    /// used a single physical source line (a `\`-continued literal), so it never
    /// hit this. The trailing gap must apply ONCE, at the paragraph's end;
    /// interior hard-wrap lines carry none.
    func testHardWrappedParagraphRevealDoesNotBalloonLineSpacing() throws {
        let source = """
        # Heading

        Try it: put the caret in the column and set it to the right so the
        values re-align and every other column keeps its alignment while you
        insert a column, delete a column, or move a whole row up or down
        without ever touching a single pipe by hand in the source text.
        """
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let para = try XCTUnwrap(document.blocks.first {
            if case .paragraph = $0.kind { return true }
            return false
        }?.id)

        let revealed = renderer.render(document, activeBlockID: para, activeCaret: 3, cache: &cache)
        let attr = revealed.attributed
        let ns = attr.string as NSString

        // Locate the revealed paragraph by its source text (the paragraph is the
        // last block, so it runs from "Try it:" to the end of the content).
        let start = ns.range(of: "Try it:")
        XCTAssertNotEqual(start.location, NSNotFound, "revealed source text not found")

        // Trailing paragraphSpacing per source line of the revealed paragraph.
        var perLineSpacing: [CGFloat] = []
        var loc = start.location
        while loc < attr.length {
            let line = ns.lineRange(for: NSRange(location: loc, length: 0))
            let anchor = min(line.location, attr.length - 1)
            let style = attr.attribute(.paragraphStyle, at: anchor, effectiveRange: nil) as? NSParagraphStyle
            perLineSpacing.append(style?.paragraphSpacing ?? 0)
            loc = NSMaxRange(line)
            if line.length == 0 { break }
        }

        XCTAssertGreaterThan(perLineSpacing.count, 1, "the paragraph should reveal as multiple source lines")
        XCTAssertTrue(perLineSpacing.dropLast().allSatisfy { $0 == 0 },
                      "interior hard-wrap lines must not each carry the paragraph's trailing gap "
                      + "(got \(perLineSpacing))")
    }

    private func measureHeight(_ attributed: NSAttributedString, width: CGFloat = 600) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributed)
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = storage
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        layoutManager.ensureLayout(for: contentStorage.documentRange)
        var maxY: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(from: contentStorage.documentRange.location) { fragment in
            maxY = max(maxY, fragment.layoutFragmentFrame.maxY)
            return true
        }
        return maxY
    }
}
#endif
