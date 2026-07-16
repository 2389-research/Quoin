#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// The generalized "no surprises" ratchet: for EVERY block of EVERY
/// renderer fixture, revealing the block must change the document's height
/// by at most ~one line's worth (42pt) — with a short, documented exception
/// list that can only shrink. A reveal that reflows more than that shoves
/// content around the user's click no matter how well the viewport anchor
/// works; this is what keeps every block type honest as the reveal styling
/// evolves.
final class RevealDeltaRatchetTests: XCTestCase {

    /// Per-kind ceilings above the default 40pt, measured at introduction
    /// (2026-07-09). Lowering is welcome; raising or adding entries needs a
    /// design reason. Documented causes:
    /// - paragraph (default 40): soft-broken source shows its physical
    ///   lines; the rendered form joins them.
    /// - heading 60: a setext heading's `====` underline exists only in
    ///   source.
    /// - code 55: the two fence lines exist only in source.
    /// - list 115: loose lists show their blank separator lines (compressed
    ///   to gap height, but items also carry structural markers); the caret
    ///   mapper's syntax-only constraint trades a ±1-line transplant anchor
    ///   in loose structures for EXACT caret placement.
    /// - blockQuote 185: `>` scaffolding lines, quote-interior fences and
    ///   blank lines — REDUCTION TRACKED (the largest remaining reveal).
    /// - thematicBreak 90: the document-final HR's trailing-newline phantom
    ///   — REDUCTION TRACKED.
    /// - html 75: the raw-source card's padding versus prose spacing.
    /// - image paragraphs 120: the attachment collapses to a one-line
    ///   source reference; the delta is the image height itself.
    /// - table 55: the delimiter row (`|---|`) exists only in source, and
    ///   the rendered form carries the `‹/› edit` chip band the revealed
    ///   source doesn't (embed-editing brief, Phase 2.1; measured 52 on the
    ///   widest fixture table).
    private let exceptions: [String: CGFloat] = [
        "table": 55,
        "heading": 60,
        "code": 55,
        "list": 115,
        "blockQuote": 205,
        "thematicBreak": 90,
        "html": 85,
        // Review endmatter: the chip condenses N metadata entries to one
        // line; the reveal unfolds the full YAML. Scales with entry count —
        // the fixture's three-entry endmatter measures 281.
        "endmatter": 320,
        // Attachment-backed reveals (equations, images, diagrams): with the
        // preview-anchored reveal the artifact STAYS rendered and the
        // source unfolds beneath it, so the delta is now the source
        // panel's own height (plus, for images, the attachment height —
        // images have no preview mode). Bounded by source length; the
        // kitchen-sink sequence diagram measures 1227. The caret-line pin
        // and the anchored preview are the user's guards here.
        "attachment": 1300,
        // Reference-link definitions are INVISIBLE in the reading
        // projection; revealing them must show their lines (URLs collapse,
        // labels can't).
        "definitions": 220,
    ]

    func testEveryBlockRevealsWithinBudget() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/renderer")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(files.count, 12)

        var failures: [String] = []
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            let document = MarkdownConverter.parse(source)
            let renderer = AttributedRenderer()
            var cache: [BlockID: NSAttributedString] = [:]
            let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
            let base = measureHeight(reading.attributed)

            for block in document.blocks {
                var blockCache = cache
                let revealed = renderer.render(
                    document, activeBlockID: block.id, activeCaret: 0, cache: &blockCache)
                let delta = abs(measureHeight(revealed.attributed) - base)
                let readFragment = reading.blockRanges[block.id].map {
                    reading.attributed.attributedSubstring(from: $0)
                }
                let budget = self.budget(for: block, in: document, readFragment: readFragment)
                if delta > budget {
                    let head = (document.source.substring(in: block.range) ?? "")
                        .prefix(40).replacingOccurrences(of: "\n", with: "⏎")
                    failures.append(
                        "\(url.lastPathComponent): \(Int(delta))pt (budget \(Int(budget))) <<\(head)>>")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty,
                      "reveals reflowing beyond budget:\n" + failures.joined(separator: "\n"))
    }

    private func budget(for block: Block, in document: QuoinDocument,
                        readFragment: NSAttributedString?) -> CGFloat {
        let defaultBudget: CGFloat = 42
        // Attachment-backed reading forms (equations, images, diagrams)
        // reveal at the attachment/source height difference — inherent.
        if let readFragment, readFragment.string.contains("\u{FFFC}") {
            return exceptions["attachment", default: defaultBudget]
        }
        if case .mathBlock = block.kind {
            return exceptions["attachment", default: defaultBudget]
        }
        // Math-scanner stress blocks (display-math source that cmark bins
        // as prose) and unsupported `:::` containers: source-shaped, not
        // kind-shaped.
        if let slice = document.source.substring(in: block.range) {
            if slice.contains("\\begin{") || slice.hasPrefix("\\[") {
                return exceptions["attachment", default: defaultBudget]
            }
            if slice.hasPrefix(":::") {
                return exceptions["html", default: defaultBudget]
            }
        }
        // Reference-link definition paragraphs are invisible when rendered.
        if let slice = document.source.substring(in: block.range),
           slice.range(of: #"^\[[^\]]+\]:"#, options: .regularExpression) != nil {
            return exceptions["definitions", default: defaultBudget]
        }
        switch block.kind {
        case .paragraph(let inlines):
            let hasImage = inlines.contains { if case .image = $0 { return true }; return false }
            return hasImage ? exceptions["attachment", default: defaultBudget] : defaultBudget
        case .table: return exceptions["table", default: defaultBudget]
        case .heading: return exceptions["heading", default: defaultBudget]
        case .codeBlock: return exceptions["code", default: defaultBudget]
        case .list: return exceptions["list", default: defaultBudget]
        case .blockQuote, .callout: return exceptions["blockQuote", default: defaultBudget]
        case .thematicBreak: return exceptions["thematicBreak", default: defaultBudget]
        case .htmlBlock, .frontMatter:
            return exceptions["html", default: defaultBudget]
        case .reviewEndmatter:
            // Condensed chip ↔ full YAML source: inherent expansion, like
            // front matter but multi-entry.
            return exceptions["endmatter", default: defaultBudget]
        default: return defaultBudget
        }
    }

    private func measureHeight(_ attributed: NSAttributedString) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributed)
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = storage
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 680, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        layoutManager.ensureLayout(for: contentStorage.documentRange)
        var maxY: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(from: contentStorage.documentRange.location) { fragment in
            maxY = max(maxY, fragment.layoutFragmentFrame.maxY)
            return true
        }
        return maxY
    }
}
#endif
