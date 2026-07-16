#if canImport(AppKit) || canImport(UIKit)
import XCTest
import QuoinCore
@testable import QuoinRender

/// Footnote navigation plumbing (#80): a `[^id]` reference is a
/// `quoin-footnote://` link tagged with its id; the definition appended at
/// the document tail wears the id across its whole range and ends in a
/// `quoin-footnote-back://` ↩ backlink. References and definitions share ONE
/// attributed string, so both directions of the jump are range lookups over
/// these tags — the coordinator adds no geometry of its own.
final class FootnoteNavigationTests: XCTestCase {

    private let source = """
    First mention.[^alpha] Second footnote here.[^beta]

    Alpha again.[^alpha]

    [^alpha]: The alpha definition text.
    [^beta]: The beta definition text.
    """

    private func render(_ source: String) -> RenderedDocument {
        AttributedRenderer(theme: Theme(prefersDark: false), baseURL: nil)
            .render(MarkdownConverter.parse(source))
    }

    /// Every tagged run for `id`, in document order.
    private func runs(
        tag: NSAttributedString.Key, id: String, in attributed: NSAttributedString
    ) -> [NSRange] {
        var out: [NSRange] = []
        attributed.enumerateAttribute(
            tag, in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            if value as? String == id { out.append(range) }
        }
        return out
    }

    func testReferenceRunCarriesLinkAndIDTag() throws {
        let rendered = render(source)
        let refs = runs(tag: QuoinAttribute.footnoteID, id: "alpha", in: rendered.attributed)
        // Two [^alpha] references; each is a jump-to-definition link.
        XCTAssertEqual(refs.count, 2)
        for range in refs {
            let attrs = rendered.attributed.attributes(at: range.location, effectiveRange: nil)
            XCTAssertEqual(attrs[.link] as? URL, QuoinLink.footnoteURL(id: "alpha"))
            // Superscript ordinal: raised baseline, ordinal text.
            let offset = try XCTUnwrap(attrs[.baselineOffset] as? CGFloat)
            XCTAssertGreaterThan(offset, 0)
            XCTAssertEqual((rendered.attributed.string as NSString).substring(with: range), "1")
        }
        let betaRefs = runs(tag: QuoinAttribute.footnoteID, id: "beta", in: rendered.attributed)
        XCTAssertEqual(betaRefs.count, 1)
        XCTAssertEqual((rendered.attributed.string as NSString).substring(with: betaRefs[0]), "2")
    }

    func testDefinitionRangeIsTaggedAndEndsInBacklink() throws {
        let rendered = render(source)
        for (id, body) in [("alpha", "The alpha definition text."),
                           ("beta", "The beta definition text.")] {
            let defs = runs(tag: QuoinAttribute.footnoteDefinitionID, id: id, in: rendered.attributed)
            XCTAssertFalse(defs.isEmpty, "\(id): no tagged definition runs")
            // The tagged runs are contiguous: one definition range per id.
            let start = defs[0].location
            let end = defs.map(NSMaxRange).max()!
            XCTAssertEqual(defs.map { $0.length }.reduce(0, +), end - start,
                           "\(id): definition tag is not one contiguous range")
            let text = (rendered.attributed.string as NSString)
                .substring(with: NSRange(location: start, length: end - start))
            XCTAssertTrue(text.contains(body), "\(id): definition text missing")
            XCTAssertTrue(text.hasSuffix(" ↩"), "\(id): no trailing backlink glyph")
            // The ↩ run links back to the reference.
            let backAt = end - 1
            XCTAssertEqual(
                rendered.attributed.attribute(.link, at: backAt, effectiveRange: nil) as? URL,
                QuoinLink.footnoteBackURL(id: id))
        }
    }

    func testFirstTaggedReferencePrecedesDefinition() throws {
        // The ↩ contract: scanning for the id tag finds the FIRST reference,
        // which must precede the tail definition in the same string.
        let rendered = render(source)
        let refs = runs(tag: QuoinAttribute.footnoteID, id: "alpha", in: rendered.attributed)
        let defs = runs(tag: QuoinAttribute.footnoteDefinitionID, id: "alpha", in: rendered.attributed)
        let firstRef = try XCTUnwrap(refs.first)
        let def = try XCTUnwrap(defs.first)
        XCTAssertLessThan(NSMaxRange(firstRef), def.location)
    }

    func testFootnoteURLsRoundTripTheirIDs() throws {
        let url = try XCTUnwrap(QuoinLink.footnoteURL(id: "basic-footnote"))
        XCTAssertEqual(url.absoluteString, "quoin-footnote://basic-footnote")
        XCTAssertEqual(QuoinLink.footnoteID(from: url), "basic-footnote")
        XCTAssertNil(QuoinLink.footnoteBackID(from: url), "schemes must not cross-parse")

        let back = try XCTUnwrap(QuoinLink.footnoteBackURL(id: "basic-footnote"))
        XCTAssertEqual(back.absoluteString, "quoin-footnote-back://basic-footnote")
        XCTAssertEqual(QuoinLink.footnoteBackID(from: back), "basic-footnote")
        XCTAssertNil(QuoinLink.footnoteID(from: back), "schemes must not cross-parse")

        // Anchor links stay in their own lane.
        let anchor = try XCTUnwrap(QuoinLink.anchorURL(slug: "basic-footnote"))
        XCTAssertNil(QuoinLink.footnoteID(from: anchor))
    }
}
#endif
