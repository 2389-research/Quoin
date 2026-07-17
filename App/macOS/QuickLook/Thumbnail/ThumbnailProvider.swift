import AppKit
import QuickLookThumbnailing
import QuoinCore

/// Quick Look thumbnail provider for Markdown documents (issue #8).
///
/// Thin by design: it reads the file under the thumbnail byte budget, reduces
/// it via `BoundedPreview` (shared QuoinCore logic), and rasterises the top of
/// the page through `ThumbnailRasterizer` (extension-safe CoreText — see that
/// file for why QuoinRender can't be linked into an app-extension). No
/// Mermaid/Vinculum layout runs: the bounded model already swapped those
/// embeds for placeholders.
final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let url = request.fileURL
        let bounded = QuickLookContent.boundedDocument(at: url, bounds: .thumbnail)

        // Fit a page-proportioned (US Letter) card inside the requested box so
        // the thumbnail reads as a document, not a stretched square.
        let target = Self.pageSize(fitting: request.maximumSize)
        let scale = max(1, request.scale)

        let reply = QLThumbnailReply(contextSize: target) { () -> Bool in
            guard let cgImage = ThumbnailRasterizer.cgImage(
                for: bounded, size: target, scale: scale),
                let context = NSGraphicsContext.current?.cgContext
            else { return false }

            let rect = CGRect(origin: .zero, size: target)
            // The drawing context can be flipped (top-left origin); the raster
            // is upright (row 0 = top), so counter a flip before drawing.
            if NSGraphicsContext.current?.isFlipped == true {
                context.saveGState()
                context.translateBy(x: 0, y: target.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(cgImage, in: rect)
                context.restoreGState()
            } else {
                context.draw(cgImage, in: rect)
            }
            return true
        }
        handler(reply, nil)
    }

    /// Largest US-Letter-proportioned size that fits inside `maxSize`.
    private static func pageSize(fitting maxSize: CGSize) -> CGSize {
        let ratio: CGFloat = 8.5 / 11.0   // width / height
        guard maxSize.width > 0, maxSize.height > 0 else {
            return CGSize(width: 85, height: 110)
        }
        var height = maxSize.height
        var width = height * ratio
        if width > maxSize.width {
            width = maxSize.width
            height = width / ratio
        }
        return CGSize(width: width, height: height)
    }
}
