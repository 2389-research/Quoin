#if canImport(AppKit)
import XCTest
import AppKit
@testable import QuoinRender
import QuoinCore

/// Local images referenced by `![](assets/x.png)` must survive PDF/RTF export
/// (issue #3): the exporter renders through the same attributed string as the
/// screen, so the image has to resolve relative to the document directory AND
/// decode synchronously (the async placeholder-then-re-render path would bake a
/// placeholder into the single fixed output).
final class ExportImageTests: XCTestCase {

    /// A 1×1 PNG — valid enough for ImageIO to decode into an attachment image.
    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    private func makeDocumentDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-export-img-\(UUID().uuidString)")
        let assets = dir.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Self.onePixelPNG.write(to: assets.appendingPathComponent("pixel.png"))
        return dir
    }

    /// True when the attributed string contains a drawable image attachment
    /// (not the text placeholder the renderer emits for unresolved images).
    private func hasImageAttachment(_ attributed: NSAttributedString) -> Bool {
        var found = false
        attributed.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: attributed.length)
        ) { value, _, stop in
            if let attachment = value as? NSTextAttachment, attachment.image != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    func testBaseURLPlusSyncDecodeResolvesLocalImage() throws {
        let dir = try makeDocumentDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = MarkdownConverter.parse("![a pixel](assets/pixel.png)")

        // Without a base URL the relative path cannot resolve → placeholder text.
        let bare = AttributedRenderer().render(doc).attributed
        XCTAssertFalse(hasImageAttachment(bare),
                       "no base URL should leave a placeholder, not an attachment")

        // With the document directory and synchronous decode, the attachment draws.
        let resolved = AttributedRenderer(baseURL: dir, imageResolution: .synchronousAttachment)
            .render(doc).attributed
        XCTAssertTrue(hasImageAttachment(resolved),
                      "base URL + sync decode should produce a drawn image attachment")
    }

    func testRTFExportKeepsVisibleImageReferenceNotSilentGap() throws {
        // Plain RTF cannot embed raster attachments (AppKit drops the image),
        // so the export must leave a visible named reference — never a gap.
        let dir = try makeDocumentDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = MarkdownConverter.parse("![a pixel](assets/pixel.png)")

        let data = try DocumentExporters.rtf(from: doc, baseURL: dir)
        let rtf = String(decoding: data, as: UTF8.self)
        // The alt text and the resolved reference survive as readable text.
        XCTAssertTrue(rtf.contains("a pixel"), "alt text should remain visible in RTF")
        XCTAssertTrue(rtf.contains("assets/pixel.png"), "the image path should remain visible in RTF")
    }

    func testPDFExportSucceedsWithLocalImage() throws {
        let dir = try makeDocumentDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = MarkdownConverter.parse("Before.\n\n![a pixel](assets/pixel.png)\n\nAfter.")

        let data = try DocumentExporters.pdf(from: doc, baseURL: dir)
        XCTAssertFalse(data.isEmpty)
        XCTAssertNotNil(NSPDFImageRep(data: data), "export should be a valid PDF")
        // The drawn attachment lands in the PDF as an embedded image XObject;
        // the same document exported without a base URL (placeholder text) has
        // none, so the image path genuinely contributed pixels.
        let withImage = String(decoding: data, as: UTF8.self)
        let withoutBase = try DocumentExporters.pdf(from: doc, baseURL: nil)
        let noImage = String(decoding: withoutBase, as: UTF8.self)
        XCTAssertTrue(withImage.contains("/Image"), "PDF should embed the drawn image")
        XCTAssertFalse(noImage.contains("/Image"), "no base URL should draw a placeholder, no image")
    }
}
#endif
