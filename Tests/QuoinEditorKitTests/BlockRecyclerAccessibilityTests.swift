#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender
@testable import QuoinEditorKit

/// Phase 1, Task 7: per-cell accessibility + table-level structure rotors.
///
/// Mirrors `BlockAccessibilityTests` / `StructureRotorTests` at the recycler
/// layer: a heading CELL reports its heading role + level + label read back
/// from its rendered fragment (via `BlockAccessibility`), and the recycler's
/// heading ROTOR lists the document's headings in document order and steps
/// through them with the shared `StructureRotor.result` navigator.
@MainActor
final class BlockRecyclerAccessibilityTests: XCTestCase {

    private let theme = Theme()   // Theme has no `.graphite`; default is the app default.

    // MARK: - Cell AX

    func testHeadingCellReportsHeadingRoleLevelAndLabel() {
        let doc = MarkdownConverter.parse("## Introduction\n\nBody text here.")
        let cell = BlockRenderCell()
        cell.configure(
            block: doc.blocks[0], document: doc,
            renderer: AttributedRenderer(), theme: theme, width: 600)

        let ax = try! XCTUnwrap(cell.accessibilityForTest)
        XCTAssertEqual(ax.headingLevel, 2)
        XCTAssertEqual(ax.role, BlockRecyclerAccessibility.headingRole)
        XCTAssertEqual(ax.label, "Heading level 2, Introduction")
        // The AX overrides surface the same values to an AX client.
        XCTAssertEqual(cell.accessibilityRole(), BlockRecyclerAccessibility.headingRole)
        XCTAssertEqual(cell.accessibilityLabel(), "Heading level 2, Introduction")
    }

    func testStructuralCellReportsLandmarkLabelAndGroupRole() {
        let doc = MarkdownConverter.parse("```swift\nlet a = 1\nlet b = 2\n```")
        let cell = BlockRenderCell()
        cell.configure(
            block: doc.blocks[0], document: doc,
            renderer: AttributedRenderer(), theme: theme, width: 600)

        let ax = try! XCTUnwrap(cell.accessibilityForTest)
        XCTAssertNil(ax.headingLevel)
        XCTAssertEqual(ax.role, .group)
        XCTAssertEqual(ax.label, "Code block, swift, 2 lines")
    }

    func testProseCellHasNoExtraLabel() {
        let doc = MarkdownConverter.parse("Just a paragraph of prose.")
        let cell = BlockRenderCell()
        cell.configure(
            block: doc.blocks[0], document: doc,
            renderer: AttributedRenderer(), theme: theme, width: 600)

        let ax = try! XCTUnwrap(cell.accessibilityForTest)
        XCTAssertNil(ax.headingLevel)
        XCTAssertEqual(ax.role, .group)
        // Prose reads as its own drawn text — no redundant spoken label.
        XCTAssertNil(ax.label)
    }

    // MARK: - Recycler heading rotor

    private func recycler(_ markdown: String) -> BlockRecyclerView {
        let view = BlockRecyclerView(renderer: AttributedRenderer(), theme: theme)
        view.setDocument(MarkdownConverter.parse(markdown), contentWidth: 600)
        return view
    }

    func testHeadingRotorListsDocumentHeadingsInOrder() {
        let view = recycler("""
        # Alpha

        Some prose.

        ## Beta

        ```
        code
        ```

        ### Gamma
        """)

        let headings = view.headingRotorItemsForTest
        XCTAssertEqual(headings.map(\.label), [
            "Heading level 1, Alpha",
            "Heading level 2, Beta",
            "Heading level 3, Gamma",
        ])
        // Locations are block indices, strictly ascending (document order).
        XCTAssertEqual(headings.map(\.location), headings.map(\.location).sorted())
        XCTAssertEqual(Set(headings.map(\.location)).count, headings.count)
    }

    func testHeadingRotorStepsThroughHeadingsWithSharedNavigator() {
        let view = recycler("# One\n\n## Two\n\n### Three")
        let items = view.headingRotorItemsForTest
        XCTAssertEqual(items.count, 3)

        // First .next search opens on the first heading; stepping walks forward.
        let first = view.headingRotorStepForTest(from: nil, direction: .next)
        XCTAssertEqual(first?.label, "Heading level 1, One")
        let second = view.headingRotorStepForTest(from: first?.location, direction: .next)
        XCTAssertEqual(second?.label, "Heading level 2, Two")
        let third = view.headingRotorStepForTest(from: second?.location, direction: .next)
        XCTAssertEqual(third?.label, "Heading level 3, Three")
        // Past the last heading returns nil.
        XCTAssertNil(view.headingRotorStepForTest(from: third?.location, direction: .next))
    }

    func testBlocksRotorHoldsNonHeadingStructuralBlocks() {
        let view = recycler("# Title\n\n```\ncode\n```\n\n> quote")
        let blocks = view.blockRotorItemsForTest
        // The Blocks rotor excludes headings (they own the Headings rotor) and
        // prose (reads as its own text); it holds the structural landmarks.
        XCTAssertEqual(blocks.map(\.label), ["Code block, 1 line", "Block quote"])
        XCTAssertTrue(view.headingRotorItemsForTest.allSatisfy { item in
            !blocks.contains(where: { $0.location == item.location })
        })
    }
}
#endif
