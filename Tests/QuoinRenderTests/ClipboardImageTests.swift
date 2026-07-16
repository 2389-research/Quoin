#if canImport(AppKit)
import AppKit
import XCTest
@testable import QuoinRender

/// #24 — clipboard image paste. Verifies the pasteboard → PNG normalization
/// that turns a screenshot / copied bitmap into the bytes we save under
/// `assets/`. Uses a scratch (uniquely named) pasteboard so it never touches
/// the user's real clipboard.
final class ClipboardImageTests: XCTestCase {
    private func scratchPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("QuoinClipboardImageTests"))
        pb.clearContents()
        return pb
    }

    /// A 2×2 red square as PNG bytes, built without touching disk.
    private func sampleImageData(as fileType: NSBitmapImageRep.FileType) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<2 {
            for y in 0..<2 {
                rep.setColor(.red, atX: x, y: y)
            }
        }
        return rep.representation(using: fileType, properties: [:])!
    }

    func testDirectPNGPassesThrough() {
        let pb = scratchPasteboard()
        let png = sampleImageData(as: .png)
        pb.setData(png, forType: .png)

        let result = ClipboardImage.pngData(from: pb)
        XCTAssertEqual(result, png, "A PNG already on the pasteboard should be returned unchanged.")
    }

    func testTIFFIsReencodedToPNG() {
        let pb = scratchPasteboard()
        pb.setData(sampleImageData(as: .tiff), forType: .tiff)

        let result = ClipboardImage.pngData(from: pb)
        XCTAssertNotNil(result, "A TIFF screenshot should normalize to PNG bytes.")
        // PNG magic number — proves the re-encode actually produced a PNG.
        XCTAssertEqual(Array(result!.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        // And it must round-trip back to a decodable 2×2 image.
        let decoded = NSBitmapImageRep(data: result!)
        XCTAssertEqual(decoded?.pixelsWide, 2)
        XCTAssertEqual(decoded?.pixelsHigh, 2)
    }

    func testNoImageYieldsNil() {
        let pb = scratchPasteboard()
        pb.setString("just some text", forType: .string)

        XCTAssertNil(ClipboardImage.pngData(from: pb),
                     "Text-only pasteboard carries no image, so paste falls through to plain text.")
    }
}
#endif
