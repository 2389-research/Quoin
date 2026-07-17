#if canImport(AppKit) || canImport(UIKit)
import XCTest
@testable import QuoinRender
import QuoinCore

/// Guards issue #33: the full-document projection is now built OFF the main
/// actor (see `ReaderModel.rerenderAsync`). Two properties must hold for that
/// to be correct, and both are proven here against the whole fixture corpus:
///
///  1. **Thread safety.** `AttributedRenderer.render` — including the native
///     math/diagram attachment builders and the async image store it calls —
///     must be safe to run on a background executor. A data race in the render
///     tree would surface as a crash, a hang, or a diverging digest under the
///     concurrent-render stress below.
///  2. **Equivalence.** The projection built off-main must be byte- and
///     attribute-identical to the one built on-main. `ReaderModel` adopts the
///     off-main result verbatim, so any divergence would be a visible
///     projection difference depending purely on which executor rendered it.
///
/// This does not exercise the `renderGeneration` stale-drop guard directly
/// (that lives in `ReaderModel`, in the app target, and is verified by the app
/// build + review) — it proves the premise the guard relies on: that an
/// off-main render is a pure, deterministic, executor-independent function of
/// its inputs.
final class OffMainRenderEquivalenceTests: XCTestCase {

    private var theme: Theme { Theme(prefersDark: false) }

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // QuoinRenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Fixtures/renderer")
    }

    private func fixtureURLs() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Renders each fixture on the main actor and on a detached background
    /// executor; the deterministic digests must be identical.
    func testOffMainRenderMatchesMainRenderAcrossTheCorpus() async throws {
        let urls = try fixtureURLs()
        XCTAssertGreaterThan(urls.count, 0, "no renderer fixtures found")
        let theme = self.theme
        var checks = 0
        for url in urls {
            let source = try String(contentsOf: url, encoding: .utf8)
            let document = MarkdownConverter.parse(source)

            // baseURL nil: relative images resolve to a synchronous
            // placeholder, so no async decode leaks nondeterminism.
            let onMain = AttributedRenderer(theme: theme, baseURL: nil).render(document)
            let offMain = await Task.detached(priority: .userInitiated) {
                AttributedRenderer(theme: theme, baseURL: nil).render(document)
            }.value

            XCTAssertEqual(
                RenderDigester.digest(onMain, theme: theme),
                RenderDigester.digest(offMain, theme: theme),
                "off-main render diverged from on-main for \(url.lastPathComponent)")
            checks += 1
        }
        // Coverage floor (invariant 20): a bug that made every fixture bail
        // early must not masquerade as a pass.
        XCTAssertGreaterThanOrEqual(checks, urls.count)
    }

    /// Stress the render tree for data races: render one document from many
    /// background tasks at once and assert every result equals the serial
    /// baseline. A shared-mutable-state race in any attachment builder would
    /// corrupt at least one concurrent digest.
    func testConcurrentBackgroundRendersAreDeterministic() async throws {
        let theme = self.theme
        // Pick the largest fixture so the render actually overlaps across
        // tasks rather than finishing before the next one starts.
        func byteSize(_ url: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        }
        guard let url = try fixtureURLs().max(by: { byteSize($0) < byteSize($1) }) else {
            return XCTFail("no renderer fixtures found")
        }

        let source = try String(contentsOf: url, encoding: .utf8)
        let document = MarkdownConverter.parse(source)
        let baseline = RenderDigester.digest(
            AttributedRenderer(theme: theme, baseURL: nil).render(document), theme: theme)

        let digests = await withTaskGroup(of: DocDigest.self) { group -> [DocDigest] in
            for _ in 0..<16 {
                group.addTask(priority: .userInitiated) {
                    let rendered = AttributedRenderer(theme: theme, baseURL: nil).render(document)
                    return RenderDigester.digest(rendered, theme: theme)
                }
            }
            var out: [DocDigest] = []
            for await d in group { out.append(d) }
            return out
        }

        XCTAssertEqual(digests.count, 16)
        for (i, d) in digests.enumerated() {
            XCTAssertEqual(d, baseline, "concurrent render #\(i) diverged for \(url.lastPathComponent)")
        }
    }
}
#endif
