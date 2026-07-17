import XCTest
@testable import QuoinCore

/// #R3 — the outline current-section highlight must track the section the
/// reader is IN, resolved by document order so it survives the section heading
/// scrolling above the viewport.
final class OutlineNavigationTests: XCTestCase {
    private let doc = MarkdownConverter.parse("""
    # Alpha

    Alpha intro paragraph.

    ## Beta

    Beta paragraph one.

    Beta paragraph two.

    ## Gamma

    Gamma paragraph.
    """)

    private func block(_ predicate: (Block) -> Bool) -> BlockID {
        doc.blocks.first(where: predicate)!.id
    }

    private func heading(_ title: String) -> BlockID {
        block { if case .heading(_, let inlines, _) = $0.kind {
            return inlines.contains { if case .text(let t) = $0 { return t == title }; return false }
        }; return false }
    }

    private func paragraph(_ text: String) -> BlockID {
        block { if case .paragraph(let inlines) = $0.kind {
            return inlines.contains { if case .text(let t) = $0 { return t == text }; return false }
        }; return false }
    }

    private func section(topBlockID: BlockID?) -> String? {
        OutlineNavigation.currentSection(
            topBlockID: topBlockID, blocks: doc.blocks, outline: doc.outline)?.title
    }

    func testTopBlockIsAHeadingReportsThatSection() {
        XCTAssertEqual(section(topBlockID: heading("Beta")), "Beta")
    }

    func testParagraphInsideSectionReportsItsHeading() {
        // The bug: reading a paragraph deep in Beta (Beta's heading above the
        // viewport) must still report Beta, not Alpha.
        XCTAssertEqual(section(topBlockID: paragraph("Beta paragraph two.")), "Beta")
    }

    func testParagraphBeforeFirstHeadingFallsBackToFirst() {
        XCTAssertEqual(section(topBlockID: paragraph("Alpha intro paragraph.")), "Alpha")
    }

    func testLastSectionStaysHighlighted() {
        XCTAssertEqual(section(topBlockID: paragraph("Gamma paragraph.")), "Gamma")
    }

    func testNilTopBlockFallsBackToFirstHeading() {
        XCTAssertEqual(section(topBlockID: nil), "Alpha")
    }
}
