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

        if coordinator.renderedGeneration !== rendered.attributed {
            textView.attributedText = rendered.attributed
            coordinator.renderedGeneration = rendered.attributed
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
