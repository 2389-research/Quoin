#if canImport(AppKit) || canImport(UIKit)
import XCTest
@testable import QuoinRender
import QuoinCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The async-image seam both platform readers depend on (issue #2): the first
/// render of a local image shows a placeholder tagged `pendingContent` and
/// decodes off-main; when the decode finishes the renderer fires
/// `onContentReady`, and the NEXT render (the placeholder was never cached)
/// swaps in the drawn attachment. macOS wires this in `ReaderModel`; iOS wires
/// the same callback in `IOSReaderModel.scheduleAsyncContentRerender`. This
/// exercises the renderer contract those wirings both rely on — no fixed sleep:
/// the second render is driven by the callback via an expectation.
final class AsyncImageRerenderTests: XCTestCase {

    /// A 1×1 PNG — valid enough for ImageIO to decode into an attachment image.
    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    /// A fresh directory + image per test: the shared `AsyncImageStore` cache is
    /// keyed on path+mtime, so a unique path guarantees a cache MISS and thus the
    /// placeholder-first path (a warm cache would return the attachment directly).
    private func makeDocumentDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-async-img-\(UUID().uuidString)")
        let assets = dir.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Self.onePixelPNG.write(to: assets.appendingPathComponent("pixel.png"))
        return dir
    }

    private func hasImageAttachment(_ attributed: NSAttributedString) -> Bool {
        var found = false
        attributed.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: attributed.length)
        ) { value, _, stop in
            if let attachment = value as? NSTextAttachment, attachment.image != nil {
                found = true; stop.pointee = true
            }
        }
        return found
    }

    private func hasPendingContent(_ attributed: NSAttributedString) -> Bool {
        var pending = false
        attributed.enumerateAttribute(
            QuoinAttribute.pendingContent, in: NSRange(location: 0, length: attributed.length)
        ) { value, _, stop in
            if value != nil { pending = true; stop.pointee = true }
        }
        return pending
    }

    /// First render → placeholder tagged pending; onContentReady fires after the
    /// off-main decode; the re-render replaces the placeholder with the image.
    func testPlaceholderThenAttachmentAfterContentReady() throws {
        let dir = try makeDocumentDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = MarkdownConverter.parse("![a pixel](assets/pixel.png)")

        let ready = expectation(description: "onContentReady fires when the decode completes")
        let renderer = AttributedRenderer(
            baseURL: dir,
            imageResolution: .async,
            onContentReady: { ready.fulfill() }
        )

        // First render: cache miss → quiet placeholder, no drawn attachment, and
        // the fragment is flagged pending so it is NOT cached (a cached
        // placeholder would stick forever).
        let first = renderer.render(doc).attributed
        XCTAssertFalse(hasImageAttachment(first),
                       "first render of an uncached image should be a placeholder, not an attachment")
        XCTAssertTrue(hasPendingContent(first),
                      "the placeholder fragment must be tagged pendingContent so it is not cached")

        wait(for: [ready], timeout: 5)

        // Second render (what onContentReady schedules): the decode is now cached,
        // so the attachment draws and the pending flag is gone.
        let second = renderer.render(doc).attributed
        XCTAssertTrue(hasImageAttachment(second),
                      "after onContentReady, the re-render should swap in the drawn image")
        XCTAssertFalse(hasPendingContent(second),
                       "the resolved fragment must no longer be pending")
    }

    /// No render loop: once the image is cached, a render is a pure cache hit
    /// that does NOT re-arm `onReady`, so the callback cannot fire endlessly for
    /// already-decoded content. Guards the iOS/macOS rerender against a loop.
    func testResolvedImageDoesNotRefireContentReady() throws {
        let dir = try makeDocumentDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = MarkdownConverter.parse("![a pixel](assets/pixel.png)")

        // onContentReady fires from an off-main detached task, so the fire count
        // is behind a lock (a plain captured var would be a data race).
        let firstReady = expectation(description: "first decode fires onContentReady once")
        let fireCount = LockedCounter()
        let renderer = AttributedRenderer(
            baseURL: dir,
            imageResolution: .async,
            onContentReady: {
                fireCount.increment()
                firstReady.fulfill()
            }
        )

        _ = renderer.render(doc).attributed   // schedules the decode
        wait(for: [firstReady], timeout: 5)

        // Re-render against the now-warm cache several times; a cache hit must not
        // re-arm the decode, so no further onContentReady callbacks are produced.
        for _ in 0..<3 {
            let attributed = renderer.render(doc).attributed
            XCTAssertTrue(hasImageAttachment(attributed))
            XCTAssertFalse(hasPendingContent(attributed))
        }
        XCTAssertEqual(fireCount.value, 1,
                       "a warm-cache re-render must not re-fire onContentReady (would loop)")
    }
}

/// A lock-guarded integer so the off-main `onContentReady` callback can bump a
/// counter the test thread reads without a data race.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
#endif
