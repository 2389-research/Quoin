import Foundation

/// The clipboard-image seam: what the editing view-model needs to insert a
/// pasted image, decoupled from AppKit's `NSPasteboard` so the paste logic can
/// move platform-free (iOS-shell extraction, ADR 0010, Phase 1). macOS wraps
/// `NSPasteboard` (`NSPasteboardImageSource`); iOS will wrap `UIPasteboard`.
public protocol PasteboardImageSource {
    /// Image FILE URLs on the pasteboard — a copied image *file* keeps its own
    /// format (reuses the drag-drop path).
    func imageFileURLs() -> [URL]
    /// Rasterized PNG bytes — a screenshot or copied bitmap normalizes to PNG.
    func pngImageData() -> Data?
}
