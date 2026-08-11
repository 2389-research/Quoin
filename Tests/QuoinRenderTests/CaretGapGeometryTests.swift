#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// CARET-1 (Task 3): the pure geometry decision that turns the 2pt sliver
/// caret drawn on a compressed blank line into a body-height bar. These
/// exercise the helper WITHOUT instantiating the view (no NSApplication /
/// graphics context needed) plus one integration check that the renderer's
/// real compressed-gap paragraph style is recognized — so a threshold drift
/// in either place fails a test.
final class CaretGapGeometryTests: XCTestCase {

    private let sliverHeight: CGFloat = 2   // matches AttributedRenderer's compressed rows
    private let bodyHeight: CGFloat = 23

    private func compressedGapStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.maximumLineHeight = 2
        style.minimumLineHeight = 0
        style.lineHeightMultiple = 1
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        return style
    }

    private func bodyStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        // A real body line: unset maximum, driven by the line-height multiple.
        style.maximumLineHeight = 0
        style.lineHeightMultiple = 1.4
        style.paragraphSpacing = 12
        return style
    }

    // (a) A compressed-gap paragraph yields a caret TALLER than the sliver,
    //     centered on it, with x/width unchanged.
    func testCompressedGapProducesBodyHeightCaret() {
        let base = CGRect(x: 40, y: 100, width: 1, height: sliverHeight)
        let caret = CaretGapGeometry.caretRect(
            base: base, paragraphStyle: compressedGapStyle(), bodyLineHeight: bodyHeight)

        XCTAssertEqual(caret.height, bodyHeight, accuracy: 0.001)
        XCTAssertGreaterThan(caret.height, base.height, "caret must exceed the sliver height")
        XCTAssertEqual(caret.origin.x, base.origin.x, accuracy: 0.001, "x is unchanged")
        XCTAssertEqual(caret.width, base.width, accuracy: 0.001, "width is unchanged")
        XCTAssertEqual(caret.midY, base.midY, accuracy: 0.001, "bar is centered on the sliver")
        // The input sliver geometry itself is untouched (the helper is pure).
        XCTAssertEqual(base.height, sliverHeight, accuracy: 0.001)
    }

    // (b) A normal body line returns the caret rect UNCHANGED.
    func testNormalBodyLineLeavesCaretUnchanged() {
        let base = CGRect(x: 40, y: 100, width: 1, height: bodyHeight)
        let caret = CaretGapGeometry.caretRect(
            base: base, paragraphStyle: bodyStyle(), bodyLineHeight: bodyHeight)
        XCTAssertEqual(caret, base)
    }

    // The double-newline occupiable line uses maximumLineHeight == 0 (body
    // height via the multiple) — it is NOT a sliver and must be excluded.
    func testZeroMaxLineHeightIsNotAGap() {
        let style = NSMutableParagraphStyle()
        style.maximumLineHeight = 0
        style.paragraphSpacing = 0
        style.lineHeightMultiple = 1.4
        XCTAssertFalse(CaretGapGeometry.isCompressedGap(style))
        let base = CGRect(x: 0, y: 0, width: 1, height: bodyHeight)
        XCTAssertEqual(
            CaretGapGeometry.caretRect(base: base, paragraphStyle: style, bodyLineHeight: bodyHeight),
            base)
    }

    // A short maximumLineHeight but WITH paragraph spacing is not the sliver.
    func testMaxLineHeightWithSpacingIsNotAGap() {
        let style = NSMutableParagraphStyle()
        style.maximumLineHeight = 2
        style.paragraphSpacing = 12
        XCTAssertFalse(CaretGapGeometry.isCompressedGap(style))
    }

    // Nil style (no storage / ranged selection) is a no-op passthrough.
    func testNilStylePassesThrough() {
        let base = CGRect(x: 5, y: 5, width: 1, height: sliverHeight)
        XCTAssertEqual(
            CaretGapGeometry.caretRect(base: base, paragraphStyle: nil, bodyLineHeight: bodyHeight),
            base)
    }

    // Defensive: if the "body" height is not actually taller, leave the rect
    // alone rather than shrink the caret.
    func testBodyHeightNotTallerReturnsBase() {
        let base = CGRect(x: 0, y: 0, width: 1, height: sliverHeight)
        let caret = CaretGapGeometry.caretRect(
            base: base, paragraphStyle: compressedGapStyle(), bodyLineHeight: 1)
        XCTAssertEqual(caret, base)
    }

    // Integration: the renderer's actual compressed-gap paragraph style (from a
    // loose list's interior blank line, revealed as the active block) must be
    // recognized by the helper — pins the threshold to real output.
    @MainActor
    func testRendererCompressedGapIsRecognized() {
        let document = MarkdownConverter.parse("- one\n\n- two\n")
        guard let list = document.blocks.first(where: {
            if case .list = $0.kind { return true }
            return false
        }) else {
            return XCTFail("expected a list block in the fixture")
        }

        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let rendered = renderer.render(
            document, activeBlockID: list.id, activeCaret: 0, cache: &cache)

        var recognizedGap = false
        rendered.attributed.enumerateAttribute(
            .paragraphStyle, in: NSRange(location: 0, length: rendered.attributed.length)
        ) { value, _, _ in
            if let style = value as? NSParagraphStyle, CaretGapGeometry.isCompressedGap(style) {
                recognizedGap = true
            }
        }
        XCTAssertTrue(
            recognizedGap,
            "renderer produced a compressed-gap paragraph the caret helper did not recognize")
    }
}
#endif
