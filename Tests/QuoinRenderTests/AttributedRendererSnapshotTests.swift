#if canImport(AppKit) || canImport(UIKit)
import XCTest
@testable import QuoinRender
import QuoinCore

/// Golden-snapshot coverage for `AttributedRenderer` — the QuoinRender layer
/// had no automated tests before this. Every fixture module in
/// `Fixtures/renderer/` is rendered through `AttributedRenderer.render(_:)`
/// with a pinned light `Theme`, reduced to a deterministic `DocDigest`
/// (see `RenderDigest.swift`), and compared to a committed JSON golden.
///
/// A renderer change that shifts run structure, attributes, paragraph
/// metrics, block decorations, or semantic colors fails the build. Regenerate
/// after an intentional change with `QUOIN_UPDATE_SNAPSHOTS=1 swift test`.
///
/// Determinism note: the digest never captures font glyph widths or
/// rasterised image bytes, and it maps the user-configurable accent color to
/// a `"accent"` token, so the golden is portable between developer machines
/// and the macOS CI runner.
final class AttributedRendererSnapshotTests: XCTestCase {

    /// Pinned light appearance so dynamic colors resolve identically every run.
    private var theme: Theme { Theme(prefersDark: false) }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // QuoinRenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }
    private var fixturesDir: URL { repoRoot.appendingPathComponent("Fixtures/renderer") }
    private var snapshotFile: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Snapshots/render-digests.json")
    }

    private func fixtureURLs() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func render(_ source: String) -> RenderedDocument {
        // baseURL nil: relative images resolve to a synchronous placeholder,
        // so no async decode races leak nondeterminism into the digest.
        let renderer = AttributedRenderer(theme: theme, baseURL: nil)
        return renderer.render(MarkdownConverter.parse(source))
    }

    private func digests() throws -> [String: DocDigest] {
        var out: [String: DocDigest] = [:]
        for url in try fixtureURLs() {
            let source = try String(contentsOf: url, encoding: .utf8)
            out[url.lastPathComponent] = RenderDigester.digest(render(source), theme: theme)
        }
        return out
    }

    func testFixtureDigestsMatchGolden() throws {
        let current = try digests()

        if ProcessInfo.processInfo.environment["QUOIN_UPDATE_SNAPSHOTS"] != nil {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try FileManager.default.createDirectory(
                at: snapshotFile.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try encoder.encode(current).write(to: snapshotFile)
            print("Wrote render digests to \(snapshotFile.path)")
            return
        }

        let golden = try JSONDecoder().decode(
            [String: DocDigest].self, from: Data(contentsOf: snapshotFile)
        )
        // Compare per fixture so a failure names the module and diffs cleanly.
        XCTAssertEqual(Set(current.keys), Set(golden.keys), "fixture set changed")
        for (name, digest) in current.sorted(by: { $0.key < $1.key }) {
            guard let expected = golden[name] else { continue }
            if digest != expected {
                XCTFail("Render digest changed for \(name): \(firstDigestDifference(digest, expected)). "
                    + "If intentional, regenerate with QUOIN_UPDATE_SNAPSHOTS=1 swift test.")
            }
        }
    }

    private func firstDigestDifference(_ current: DocDigest, _ expected: DocDigest) -> String {
        if current.runs.count != expected.runs.count {
            return "run count \(current.runs.count), expected \(expected.runs.count)"
        }
        for index in current.runs.indices where current.runs[index] != expected.runs[index] {
            return "run \(index) current \(summarize(current.runs[index])), expected \(summarize(expected.runs[index]))"
        }
        return "digests differ"
    }

    private func summarize(_ run: RunDigest) -> String {
        let text = run.t.replacingOccurrences(of: "\n", with: "\\n")
        let clipped = text.count > 40 ? String(text.prefix(40)) + "..." : text
        return "{t:\(clipped.debugDescription), q:\(run.q), f:\(run.f ?? "nil"), p:\(run.p ?? "nil"), "
            + "fg:\(run.fg ?? "nil"), bg:\(run.bg ?? "nil"), deco:\(run.deco ?? "nil")}"
    }

    /// The digest is a pure function of the render — rendering twice must
    /// produce byte-identical digests (guards against hidden per-run state
    /// leaking, e.g. an image cache or mutable scratch).
    func testDigestIsStableAcrossRepeatedRenders() throws {
        for url in try fixtureURLs() {
            let source = try String(contentsOf: url, encoding: .utf8)
            let a = RenderDigester.digest(render(source), theme: theme)
            let b = RenderDigester.digest(render(source), theme: theme)
            XCTAssertEqual(a, b, "\(url.lastPathComponent): digest not stable across renders")
        }
    }

    /// Every block's recorded range is in bounds, carries its own `BlockID`
    /// tag somewhere inside it, and the ranges are ordered by position — the
    /// invariants scroll anchoring and the splice-diff patcher depend on.
    /// (The tag needn't sit on the range's first character: a footnote's range
    /// opens on its "1. " marker, which the renderer draws around the tagged
    /// body.)
    func testBlockRangesAreTaggedAndOrdered() throws {
        for url in try fixtureURLs() {
            let source = try String(contentsOf: url, encoding: .utf8)
            let rendered = render(source)
            let ns = rendered.attributed
            XCTAssertGreaterThan(rendered.blockRanges.count, 0, "\(url.lastPathComponent): no block ranges")
            for (id, range) in rendered.blockRanges {
                XCTAssertLessThanOrEqual(NSMaxRange(range), ns.length,
                    "\(url.lastPathComponent): block range out of bounds")
                guard range.length > 0 else { continue }
                var taggedWithSelf = false
                ns.enumerateAttribute(QuoinAttribute.blockID, in: range) { value, _, stop in
                    if value as? String == id.description { taggedWithSelf = true; stop.pointee = true }
                }
                XCTAssertTrue(taggedWithSelf,
                    "\(url.lastPathComponent): block range for \(id.description) carries no self tag")
            }
            // Ranges are ordered by position with distinct starts (they tile the
            // string; trailing separators keep them contiguous, not overlapping).
            let starts = rendered.blockRanges.values.map(\.location).sorted()
            XCTAssertEqual(Set(starts).count, starts.count,
                "\(url.lastPathComponent): two blocks share a start location")
        }
    }

    /// Embed blocks (code, math, mermaid, table, html) carry the `embedBlock`
    /// flag so a single click admires them and only a double-click flips them
    /// to editable source. Regression guard for that interaction contract.
    func testEmbedBlocksAreFlaggedForDoubleClick() throws {
        let source = """
        ```swift
        let x = 1
        ```

        | A | B |
        | - | - |
        | 1 | 2 |

        $$ x = 1 $$
        """
        let rendered = render(source)
        var embedCount = 0
        rendered.attributed.enumerateAttribute(
            QuoinAttribute.embedBlock, in: NSRange(location: 0, length: rendered.attributed.length)
        ) { value, _, _ in if value != nil { embedCount += 1 } }
        XCTAssertGreaterThanOrEqual(embedCount, 3, "code, table, and math blocks should all be embed blocks")
    }
}
#endif
