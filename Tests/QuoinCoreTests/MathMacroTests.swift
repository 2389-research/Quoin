import XCTest
@testable import QuoinCore

/// Document-scoped math macros — the ENGINE tests (collection, expansion,
/// recursion cap) live in Vinculum (VinculumLayoutTests/MathMacroTests).
/// This keeps only the Quoin INTEGRATION: MarkdownConverter collecting
/// `\newcommand` across a whole document and expanding uses at parse time.
final class MathMacroTests: XCTestCase {

    func testMacroResolvesAcrossBlocksInDocument() {
        // Use in an EARLIER block, definition in a LATER block — document
        // scope means the use still resolves (order-independent).
        let source = """
        $$\\R^n$$

        $$\\newcommand{\\R}{\\mathbb{R}}$$
        """
        let doc = MarkdownConverter.parse(source)
        var mathBlockLatex: [String] = []
        for block in doc.blocks {
            if case .mathBlock(let latex) = block.kind { mathBlockLatex.append(latex) }
        }
        XCTAssertTrue(mathBlockLatex.contains { $0.contains("\\mathbb{R}") && $0.contains("^n") },
                      "the use must expand despite the definition appearing later; saw \(mathBlockLatex)")
        // The definition-only block keeps its raw source (renderer chips it).
        XCTAssertTrue(mathBlockLatex.contains { $0.contains("\\newcommand") })
    }
}
