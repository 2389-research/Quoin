#if canImport(UIKit)
import UIKit
import SwiftUI
import QuoinCore

/// The iOS/iPadOS reading surface: a TextKit 2 `UITextView` wrapped for
/// SwiftUI. Read-first (checkbox toggles write back; full editing follows
/// the macOS engine later); links, anchors, and TOC jumps work like the
/// macOS reader.
public struct MarkdownReaderViewIOS: UIViewRepresentable {

    public let rendered: RenderedDocument
    public let theme: Theme
    public let scrollTarget: BlockID?
    public let onTaskToggle: (Int) -> Void
    public let anchorResolver: (String) -> BlockID?

    public init(
        rendered: RenderedDocument,
        theme: Theme = Theme(),
        scrollTarget: BlockID? = nil,
        onTaskToggle: @escaping (Int) -> Void = { _ in },
        anchorResolver: @escaping (String) -> BlockID? = { _ in nil }
    ) {
        self.rendered = rendered
        self.theme = theme
        self.scrollTarget = scrollTarget
        self.onTaskToggle = onTaskToggle
        self.anchorResolver = anchorResolver
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = theme.canvas
        textView.textContainerInset = UIEdgeInsets(top: 24, left: 16, bottom: 24, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.linkTextAttributes = [.foregroundColor: theme.linkColor]
        textView.adjustsFontForContentSizeCategory = false
        context.coordinator.textView = textView
        return textView
    }

    public func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        // An outline jump is about to reposition the viewport itself, so there
        // is nothing worth pinning across the swap in that case.
        let willJump = scrollTarget != nil && scrollTarget != coordinator.lastScrollTarget

        if coordinator.renderedGeneration !== rendered.attributed {
            // Block-anchored scroll preservation (issue #2): the async local
            // image decode replaces a one-line placeholder with a full-height
            // image, and simply assigning `attributedText` both resets the
            // scroll to the top AND shifts everything below any grown image.
            // Pin the fragment at the top of the viewport across the swap so
            // the line the reader is on does not move — the iOS analogue of the
            // macOS reader's settle pass.
            let anchor = willJump ? nil : coordinator.captureScrollAnchor(in: textView)
            textView.attributedText = rendered.attributed
            coordinator.renderedGeneration = rendered.attributed
            if let anchor {
                coordinator.restoreScrollAnchor(anchor, in: textView)
            }
        }

        if let scrollTarget, scrollTarget != coordinator.lastScrollTarget {
            coordinator.lastScrollTarget = scrollTarget
            if let range = rendered.blockRanges[scrollTarget] {
                textView.scrollRangeToVisible(range)
            }
        }
    }

    public final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownReaderViewIOS
        weak var textView: UITextView?
        var renderedGeneration: NSAttributedString?
        var lastScrollTarget: BlockID?

        init(parent: MarkdownReaderViewIOS) {
            self.parent = parent
        }

        // MARK: - Block-anchored scroll preservation (issue #2)

        /// A fragment pinned across a re-render swap. The anchor is stored as a
        /// character OFFSET (not a live `NSTextLocation`) so it survives the
        /// content-storage replacement `attributedText =` performs, and — for
        /// the async-image case the source is byte-identical, so the offset
        /// maps to the very same character before and after.
        struct ScrollAnchor {
            let charOffset: Int
            let fragmentMinY: CGFloat
            let offsetY: CGFloat
        }

        /// Records the fragment at the top of the visible viewport and the
        /// current scroll offset. Returns `nil` when there is nothing to
        /// preserve (already at the very top) or the layout is unavailable.
        func captureScrollAnchor(in textView: UITextView) -> ScrollAnchor? {
            guard let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager else { return nil }
            let offsetY = textView.contentOffset.y
            guard offsetY > 0 else { return nil }
            // Viewport top expressed in the text container's coordinate space
            // (content offset minus the fixed top inset).
            let topInContainer = max(0, offsetY - textView.textContainerInset.top)
            guard let fragment = layoutManager.textLayoutFragment(
                for: CGPoint(x: 0, y: topInContainer)) else { return nil }
            let charOffset = contentManager.offset(
                from: contentManager.documentRange.location,
                to: fragment.rangeInElement.location)
            return ScrollAnchor(
                charOffset: charOffset,
                fragmentMinY: fragment.layoutFragmentFrame.minY,
                offsetY: offsetY)
        }

        /// Restores the scroll offset so the pinned fragment sits where it was
        /// before the swap, absorbing any height delta from images that
        /// resolved above the viewport.
        func restoreScrollAnchor(_ anchor: ScrollAnchor, in textView: UITextView) {
            guard let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager else { return }
            // Settle the whole document so the grown fragments have final
            // frames and `contentSize` reflects the true height for clamping.
            layoutManager.ensureLayout(for: layoutManager.documentRange)
            // Rebuild the location from the offset against the NEW storage; a
            // shorter edited document that no longer contains the offset yields
            // nil and we simply skip the restore (no crash, no jump attempt).
            guard let location = contentManager.location(
                    contentManager.documentRange.location, offsetBy: anchor.charOffset),
                  let fragment = layoutManager.textLayoutFragment(for: location) else { return }
            let maxOffsetY = max(0, textView.contentSize.height - textView.bounds.height)
            textView.contentOffset.y = ScrollAnchorMath.restoredOffsetY(
                oldOffsetY: anchor.offsetY,
                anchorYBefore: anchor.fragmentMinY,
                anchorYAfter: fragment.layoutFragmentFrame.minY,
                maxOffsetY: maxOffsetY)
        }

        public func textView(
            _ textView: UITextView,
            shouldInteractWith URL: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            if let offset = QuoinLink.markerOffset(from: URL) {
                parent.onTaskToggle(offset)
                return false
            }
            if let slug = QuoinLink.anchorSlug(from: URL) {
                if let blockID = parent.anchorResolver(slug),
                   let range = parent.rendered.blockRanges[blockID] {
                    textView.scrollRangeToVisible(range)
                }
                return false
            }
            return true // system handles web links
        }
    }
}
#endif
