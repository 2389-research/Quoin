import XCTest
@testable import QuoinCore

/// Ledger senior #10 — committing a fenced block whose closing fence was
/// deleted must heal the fence (as an undoable edit) instead of letting it
/// swallow the rest of the document.
final class FenceHealingTests: XCTestCase {

    private let code = BlockKind.codeBlock(language: "swift", code: "")
    private let mermaid = BlockKind.diagram(source: "", format: .mermaid)
    private let math = BlockKind.mathBlock(latex: "")

    func testHealthyFenceNeedsNoHealing() {
        XCTAssertNil(FenceHealing.healingSuffix(for: "```swift\nlet a = 1\n```", kind: code))
        XCTAssertNil(FenceHealing.healingSuffix(for: "~~~\nx\n~~~", kind: code))
        XCTAssertNil(FenceHealing.healingSuffix(for: "```mermaid\nflowchart TD\n  A-->B\n```", kind: mermaid))
    }

    func testMissingClosingFenceHeals() {
        XCTAssertEqual(
            FenceHealing.healingSuffix(for: "```swift\nlet a = 1", kind: code), "\n```")
        XCTAssertEqual(
            FenceHealing.healingSuffix(for: "```swift\nlet a = 1\n", kind: code), "```")
        XCTAssertEqual(
            FenceHealing.healingSuffix(for: "~~~\nx", kind: code), "\n~~~")
    }

    func testLongerOpenerHealsWithMatchingLength() {
        XCTAssertEqual(
            FenceHealing.healingSuffix(for: "````\n```\ninner\n```", kind: code), "\n````",
            "a ```` opener is only closed by ≥4 fence chars")
    }

    func testShorterCloserDoesNotCountAsClosed() {
        XCTAssertEqual(
            FenceHealing.healingSuffix(for: "````\ntext\n```", kind: code), "\n````")
    }

    func testIndentedOpenerPreservesIndent() {
        XCTAssertEqual(
            FenceHealing.healingSuffix(for: "  ```\nx", kind: code), "\n  ```")
    }

    func testIndentedCodeBlockNeverHeals() {
        XCTAssertNil(FenceHealing.healingSuffix(for: "    let a = 1\n    let b = 2", kind: code))
    }

    func testMismatchedFenceCharDoesNotClose() {
        XCTAssertEqual(
            FenceHealing.healingSuffix(for: "```\nx\n~~~", kind: code), "\n```")
    }

    func testMathHealing() {
        XCTAssertNil(FenceHealing.healingSuffix(for: "$$\nE = mc^2\n$$", kind: math))
        XCTAssertEqual(FenceHealing.healingSuffix(for: "$$\nE = mc^2", kind: math), "\n$$")
        XCTAssertEqual(FenceHealing.healingSuffix(for: "$$\nE = mc^2\n", kind: math), "$$")
        XCTAssertNil(FenceHealing.healingSuffix(for: "$$", kind: math),
                     "a bare opener is ambiguous — leave it alone")
    }

    func testNonFencedKindsNeverHeal() {
        XCTAssertNil(FenceHealing.healingSuffix(
            for: "> quote", kind: .paragraph(inlines: [])))
    }

    /// The end-to-end contract: a healed commit re-parses with the
    /// following blocks restored.
    func testHealedSourceRestoresSwallowedBlocks() {
        let broken = "```swift\nlet a = 1\n\nTail paragraph.\n"
        let doc = MarkdownConverter.parse(broken)
        let block = doc.blocks.first { if case .codeBlock = $0.kind { return true }; return false }
        let slice = doc.source.substring(in: block!.range)!
        let suffix = FenceHealing.healingSuffix(for: slice, kind: block!.kind)
        XCTAssertNotNil(suffix, "the fence swallowed the tail; healing must trigger")

        let healed = MarkdownConverter.parse(slice + suffix!)
        XCTAssertTrue(healed.blocks.contains {
            if case .codeBlock = $0.kind { return true }; return false
        })
    }
}
