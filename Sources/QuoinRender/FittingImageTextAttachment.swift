#if canImport(AppKit) || canImport(UIKit)
import Foundation
import CoreGraphics

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A text attachment for block embeds (diagrams, display math) that scales its
/// image DOWN to fit the content column when the natural render is wider than
/// the available width — never up. A diagram or a wide matrix that out-measures
/// the column would otherwise overflow its frame (the "Draw node pokes out of
/// the box" bug); TextKit lays the fragment at container width while the image
/// draws at natural width, so the decoration frame (measured from the fragment)
/// ends up narrower than the picture.
///
/// Because the decoration frame is measured from the fragment's used rect,
/// shrinking the attachment here also shrinks the frame to match — the box then
/// encloses the diagram exactly. Re-fits automatically on resize, since TextKit
/// re-queries `attachmentBounds` with the new line fragment.
final class FittingImageTextAttachment: NSTextAttachment {
    /// The full-resolution size the image renders at (device-independent
    /// points). Set once at construction; `bounds` may be scaled per layout.
    private let naturalSize: CGSize

    /// Breathing room kept inside the content column so the fitted image sits
    /// within its decoration frame rather than flush against the edge.
    private let horizontalInset: CGFloat

    init(image imageValue: PlatformImage, naturalSize: CGSize, horizontalInset: CGFloat = 12) {
        self.naturalSize = naturalSize
        self.horizontalInset = horizontalInset
        super.init(data: nil, ofType: nil)
        self.image = imageValue
        self.bounds = CGRect(origin: .zero, size: naturalSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        guard naturalSize.width > 1, naturalSize.height > 1 else { return bounds }
        let available = lineFrag.width - horizontalInset
        // Only ever shrink: an embed that already fits keeps its exact size.
        guard available > 0, naturalSize.width > available else {
            return CGRect(origin: .zero, size: naturalSize)
        }
        let scale = available / naturalSize.width
        return CGRect(
            x: 0, y: 0,
            width: available.rounded(.down),
            height: (naturalSize.height * scale).rounded()
        )
    }
}

extension NSMutableAttributedString {
    /// Replace every plain image attachment in the string with a
    /// `FittingImageTextAttachment`, so block embeds scale to fit the content
    /// column. Used for diagram and display-math embeds (not inline math, which
    /// is line-height-sized and never oversized).
    func refitImageAttachmentsToContentWidth(horizontalInset: CGFloat = 12) {
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  !(attachment is FittingImageTextAttachment),
                  let image = attachment.image else { return }
            let natural = attachment.bounds.size == .zero ? image.size : attachment.bounds.size
            let fitting = FittingImageTextAttachment(
                image: image, naturalSize: natural, horizontalInset: horizontalInset)
            addAttribute(.attachment, value: fitting, range: range)
        }
    }
}
#endif
