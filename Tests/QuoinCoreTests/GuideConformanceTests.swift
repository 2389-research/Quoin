import XCTest
@testable import QuoinCore

/// The bundled Markdown Guide is a CONTRACT: everything it teaches must
/// actually parse and render (launch ledger L5 acceptance). If a feature
/// regresses or the guide drifts from reality, this fails in CI.
final class GuideConformanceTests: XCTestCase {

    private func guideSource(_ name: String) throws -> String {
        // Tests run from the package; the guide lives with the app shell.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // QuoinCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("App/macOS/Resources/\(name).md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testMarkdownGuideParsesAndCoversTheAdvertisedBlocks() throws {
        let source = try guideSource("MarkdownGuide")
        let doc = MarkdownConverter.parse(source)

        // Byte-lossless invariant: the parsed document IS the file.
        XCTAssertEqual(doc.source, source)
        XCTAssertGreaterThan(doc.blocks.count, 20, "guide should be substantial")

        // The guide advertises these features — each must survive the
        // parse as its real block kind, not degrade to a paragraph.
        func hasBlock(_ predicate: (BlockKind) -> Bool, _ label: String) {
            XCTAssertTrue(doc.blocks.contains { predicate($0.kind) },
                          "guide lost its \(label) example")
        }
        hasBlock({ if case .heading = $0 { return true }; return false }, "heading")
        hasBlock({ if case .codeBlock = $0 { return true }; return false }, "code block")
        hasBlock({ if case .table = $0 { return true }; return false }, "table")
        hasBlock({ if case .blockQuote = $0 { return true }; return false }, "blockquote")
        hasBlock({ if case .list = $0 { return true }; return false }, "list")
        hasBlock({ if case .diagram = $0 { return true }; return false }, "mermaid diagram")
        hasBlock({ if case .mathBlock = $0 { return true }; return false }, "math block")

        // Every block's range must map back to the exact bytes it claims.
        for block in doc.blocks {
            XCTAssertNotNil(doc.source.substring(in: block.range),
                            "block range out of bounds: \(block.kind)")
        }
    }

    func testWelcomeDocumentParsesLosslessly() throws {
        let source = try guideSource("WelcomeToQuoin")
        let doc = MarkdownConverter.parse(source)
        XCTAssertEqual(doc.source, source)
        XCTAssertFalse(doc.blocks.isEmpty)
    }

    /// Every Help-menu entry (#13) MUST resolve to a real bundled resource, and
    /// each must parse losslessly — a broken Help route or a resource that
    /// drifted from the menu fails here in CI, not for a user. This is the
    /// headless mirror of "Help routing resolves to a real bundled resource".
    func testEveryHelpResourceExistsAndParses() throws {
        for entry in LibrarySeeding.helpSet {
            let source = try guideSource(entry.resource)
            let doc = MarkdownConverter.parse(source)
            // Byte-lossless: the parsed document IS the file.
            XCTAssertEqual(doc.source, source, "\(entry.resource).md is not round-trip lossless")
            XCTAssertFalse(doc.blocks.isEmpty, "\(entry.resource).md parsed to nothing")
            for block in doc.blocks {
                XCTAssertNotNil(doc.source.substring(in: block.range),
                                "\(entry.resource).md block range out of bounds: \(block.kind)")
            }
        }
    }

    /// The offered first-run sample set must also be real, parseable resources —
    /// accepting the seed can never fail to find a file to copy.
    func testEverySampleResourceExists() throws {
        for entry in LibrarySeeding.sampleSet {
            let source = try guideSource(entry.resource)
            XCTAssertFalse(source.isEmpty, "\(entry.resource).md is empty")
        }
    }
}
