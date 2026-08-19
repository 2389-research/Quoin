import XCTest
@testable import QuoinCore

final class EditableDocumentBuildTests: XCTestCase {

    /// The segment model mirrors the Phase 0 decomposition: leading trivia, then
    /// alternating block/trivia. A pristine block carries its exact source text
    /// and span.
    func testBuildDecomposesIntoTriviaAndBlocks() {
        let doc = EditableDocument.build(parsing: "# H\n\nBody\n")
        // Blocks in order with their exact source text.
        let blocks = doc.segments.compactMap { seg -> EditableBlock? in
            if case .block(let b) = seg { return b } else { return nil }
        }
        XCTAssertEqual(blocks.map(\.text), ["# H", "Body"])
        XCTAssertTrue(blocks.allSatisfy(\.pristine))
        // Every block has a source span equal to its text.
        for b in blocks {
            XCTAssertNotNil(b.sourceSpan)
        }
    }

    /// Distinct blocks get distinct identities.
    func testBlocksHaveDistinctIdentities() {
        let doc = EditableDocument.build(parsing: "a\n\nb\n\nc")
        let ids = doc.segments.compactMap { seg -> NodeID? in
            if case .block(let b) = seg { return b.id } else { return nil }
        }
        XCTAssertEqual(Set(ids).count, 3)
    }

    /// Leading and trailing trivia are preserved as segments.
    func testLeadingAndTrailingTriviaPreserved() {
        let doc = EditableDocument.build(parsing: "\n\n# H\n\n")
        guard case .trivia(let lead)? = doc.segments.first else {
            return XCTFail("expected leading trivia")
        }
        XCTAssertEqual(lead, "\n\n")
        guard case .trivia(let tail)? = doc.segments.last else {
            return XCTFail("expected trailing trivia")
        }
        XCTAssertEqual(tail, "\n\n")
    }
}
