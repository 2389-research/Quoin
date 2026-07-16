import XCTest
@testable import QuoinCore

/// Outline follow vs manual collapse (#74): the panel must never expand a
/// user-collapsed branch to show the reading position — the highlight
/// climbs to the deepest VISIBLE ancestor instead. These tests pin the
/// pure resolution the app's OutlinePanel delegates to.
final class OutlineCollapseTests: XCTestCase {

    /// Flat outline shaped like the UX-test fixture:
    /// 1 Intro (H1) › 1.1 (H2) — 2 Setup (H1) — 3 Inline (H1) › 3.1 (H2) › 3.3.1 (H3) › 3.2 (H2)
    private let outline: [HeadingInfo] = [
        heading(1, level: 1, title: "Intro"),
        heading(2, level: 2, title: "1.1"),
        heading(3, level: 1, title: "Setup"),
        heading(4, level: 1, title: "Inline Formatting"),
        heading(5, level: 2, title: "3.1"),
        heading(6, level: 3, title: "3.1.1"),
        heading(7, level: 2, title: "3.2"),
    ]

    private static func heading(_ n: Int, level: Int, title: String) -> HeadingInfo {
        HeadingInfo(
            id: BlockID(contentHash: n, occurrence: 0),
            level: level,
            title: title,
            slug: title.lowercased(),
            range: ByteRange(offset: n * 10, length: 5)
        )
    }

    private func id(_ n: Int) -> BlockID { BlockID(contentHash: n, occurrence: 0) }

    // MARK: - Highlight resolution

    func testFullyExpandedHighlightsTheSectionItself() {
        XCTAssertEqual(
            OutlineCollapse.resolveHighlight(for: id(6), outline: outline, collapsed: []),
            id(6)
        )
    }

    func testCollapsedParentMovesHighlightUp() {
        // Reading 3.1 while "Inline Formatting" is collapsed: the H1 row
        // takes the highlight; the branch stays closed.
        XCTAssertEqual(
            OutlineCollapse.resolveHighlight(for: id(5), outline: outline, collapsed: [id(4)]),
            id(4)
        )
    }

    func testNestedCollapseResolvesToShallowestCollapsedAncestor() {
        // Both the H1 and the H2 above the current H3 are collapsed. The
        // H2 row is itself hidden inside the H1's branch, so the highlight
        // must land on the H1 — the deepest row actually on screen.
        XCTAssertEqual(
            OutlineCollapse.resolveHighlight(for: id(6), outline: outline, collapsed: [id(4), id(5)]),
            id(4)
        )
    }

    func testInnerCollapseOnlyStopsAtThatAncestor() {
        // Only the H2 is collapsed: it stays visible (it carries the
        // chevron), so the H3 underneath resolves to it.
        XCTAssertEqual(
            OutlineCollapse.resolveHighlight(for: id(6), outline: outline, collapsed: [id(5)]),
            id(5)
        )
    }

    func testRootLevelCurrentSectionKeepsHighlightWhenSelfCollapsed() {
        // Collapsing a section hides its DESCENDANTS, not the row itself:
        // reading the root section of a collapsed branch highlights it.
        XCTAssertEqual(
            OutlineCollapse.resolveHighlight(for: id(4), outline: outline, collapsed: [id(4)]),
            id(4)
        )
    }

    func testUnrelatedCollapseDoesNotMoveHighlight() {
        XCTAssertEqual(
            OutlineCollapse.resolveHighlight(for: id(2), outline: outline, collapsed: [id(4)]),
            id(2)
        )
    }

    func testLevelSkipStillChainsToPositionalParent() {
        // H1 followed directly by H3 (no H2): the H3's parent is the H1.
        let skippy = [
            Self.heading(1, level: 1, title: "Top"),
            Self.heading(2, level: 3, title: "Deep"),
        ]
        XCTAssertEqual(
            OutlineCollapse.resolveHighlight(for: id(2), outline: skippy, collapsed: [id(1)]),
            id(1)
        )
    }

    func testNilOrUnknownCurrentSectionHighlightsNothing() {
        XCTAssertNil(OutlineCollapse.resolveHighlight(for: nil, outline: outline, collapsed: []))
        XCTAssertNil(OutlineCollapse.resolveHighlight(for: id(99), outline: outline, collapsed: []))
    }

    // MARK: - Visible rows (no current-section exception)

    func testCollapsedBranchHidesDescendantsButKeepsTheHeading() {
        let visible = OutlineCollapse.visibleHeadings(outline: outline, collapsed: [id(4)])
        XCTAssertEqual(visible.map(\.id), [id(1), id(2), id(3), id(4)])
    }

    func testCurrentSectionInsideCollapsedBranchStaysHidden() {
        // The old behavior punched an orphan row for the current section
        // into a closed branch; manual collapse is now authoritative, so
        // visibility must not depend on the reading position at all.
        let visible = OutlineCollapse.visibleHeadings(outline: outline, collapsed: [id(4)])
        XCTAssertFalse(visible.contains { $0.id == id(6) })
    }

    func testSiblingAfterCollapsedBranchReappears() {
        // Collapsing the H2 hides only its H3; the following H2 sibling
        // and everything outside the branch stay visible.
        let visible = OutlineCollapse.visibleHeadings(outline: outline, collapsed: [id(5)])
        XCTAssertEqual(visible.map(\.id), [id(1), id(2), id(3), id(4), id(5), id(7)])
    }

    func testAncestorChainRootFirstEndsWithSelf() {
        XCTAssertEqual(
            OutlineCollapse.ancestorChain(of: id(6), in: outline)?.map(\.id),
            [id(4), id(5), id(6)]
        )
        XCTAssertNil(OutlineCollapse.ancestorChain(of: id(99), in: outline))
    }
}
