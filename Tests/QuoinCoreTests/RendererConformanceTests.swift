import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import QuoinCore

/// Renders every fixture module in `Fixtures/renderer/` through the core
/// parse + layout pipeline and guards against regressions:
///
///  1. every fixture parses, produces blocks, and preserves its source
///     byte-for-byte (the round-trip invariant);
///  2. structural metrics (block / heading / diagram / math counts) match a
///     committed snapshot, so a parser change that silently shifts them
///     fails the build;
///  3. every mermaid diagram we render natively produces a non-degenerate
///     layout (guards the Phase 2 diagram routing).
///
/// The fixtures double as dogfooding docs: `-QuoinLibraryPath Fixtures/renderer`
/// loads them into the app. Regenerate the metrics snapshot after an
/// intentional fixture/parser change with `QUOIN_UPDATE_SNAPSHOTS=1 swift test`.
final class RendererConformanceTests: XCTestCase {

    struct FixtureMetrics: Codable, Equatable {
        var blocks: Int
        var headings: Int
        var links: Int
        var images: Int
        var codeBlocks: Int
        var tables: Int
        var math: Int
        var diagrams: Int
        var tasks: Int
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // QuoinCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }
    private var fixturesDir: URL { repoRoot.appendingPathComponent("Fixtures/renderer") }
    private var snapshotFile: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Snapshots/renderer-metrics.json")
    }

    private func fixtureURLs() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func metrics(for doc: QuoinDocument) -> FixtureMetrics {
        FixtureMetrics(
            blocks: doc.blocks.count,
            headings: doc.stats.headingCount,
            links: doc.stats.linkCount,
            images: doc.stats.imageCount,
            codeBlocks: doc.stats.codeBlockCount,
            tables: doc.stats.tableCount,
            math: doc.stats.mathCount,
            diagrams: doc.stats.diagramCount,
            tasks: doc.stats.taskTotal
        )
    }

    func testFixturesExist() throws {
        let urls = try fixtureURLs()
        XCTAssertGreaterThanOrEqual(urls.count, 12, "expected the full fixture module set")
    }

    func testFixturesParseLosslessly() throws {
        for url in try fixtureURLs() {
            let source = try String(contentsOf: url, encoding: .utf8)
            let doc = MarkdownConverter.parse(source)
            XCTAssertEqual(doc.source, source, "\(url.lastPathComponent): source not preserved")
            XCTAssertGreaterThan(doc.blocks.count, 0, "\(url.lastPathComponent): no blocks parsed")
        }
    }

    func testFixtureMetricsMatchSnapshot() throws {
        var current: [String: FixtureMetrics] = [:]
        for url in try fixtureURLs() {
            let source = try String(contentsOf: url, encoding: .utf8)
            current[url.lastPathComponent] = metrics(for: MarkdownConverter.parse(source))
        }

        if ProcessInfo.processInfo.environment["QUOIN_UPDATE_SNAPSHOTS"] != nil {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(
                at: snapshotFile.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try encoder.encode(current).write(to: snapshotFile)
            print("Wrote metrics snapshot to \(snapshotFile.path)")
            return
        }

        let golden = try JSONDecoder().decode(
            [String: FixtureMetrics].self, from: Data(contentsOf: snapshotFile)
        )
        XCTAssertEqual(current, golden,
            "Fixture metrics changed. If intentional, regenerate with QUOIN_UPDATE_SNAPSHOTS=1 swift test.")
    }

    func testSupportedDiagramsLayoutNonDegenerate() throws {
        // Deterministic fake measurer (no font metrics needed for geometry).
        let measure: DiagramTextMeasurer = { text, size in
            CGSize(width: CGFloat(max(text.count, 1)) * size * 0.6, height: size + 4)
        }
        var supportedCount = 0
        for url in try fixtureURLs() {
            let source = try String(contentsOf: url, encoding: .utf8)
            let doc = MarkdownConverter.parse(source)
            for block in Self.flatten(doc.blocks) {
                guard case .diagram(let mermaidSource, _) = block.kind,
                      let diagram = MermaidParser.parse(mermaidSource),
                      let size = Self.layoutSize(diagram, measure: measure) else { continue }
                supportedCount += 1
                XCTAssertGreaterThan(size.width, 0, "\(url.lastPathComponent): degenerate diagram width")
                XCTAssertGreaterThan(size.height, 0, "\(url.lastPathComponent): degenerate diagram height")
                XCTAssertLessThan(size.width, 20_000, "\(url.lastPathComponent): runaway diagram width")
            }
        }
        XCTAssertGreaterThan(supportedCount, 0, "expected the diagram fixture to exercise native layouts")
    }

    private static func layoutSize(_ diagram: MermaidDiagram, measure: DiagramTextMeasurer) -> CGSize? {
        // The scene lowering runs the per-type layout dispatch for us — and
        // unlike a hand-written exhaustive switch here, it can't fall out of
        // sync when MermaidKit adds diagram types (the 23->30 bump broke the
        // old switch at compile time).
        DiagramScene.lower(diagram, measure: measure).size
    }

    private static func flatten(_ blocks: [Block]) -> [Block] {
        var out: [Block] = []
        for block in blocks {
            out.append(block)
            switch block.kind {
            case .blockQuote(let children), .callout(_, let children):
                out.append(contentsOf: flatten(children))
            case .list(let items, _, _):
                for item in items { out.append(contentsOf: flatten(item.blocks)) }
            default:
                break
            }
        }
        return out
    }
}
