#if canImport(AppKit)
import AppKit

/// The macOS `PasteboardImageSource`, backed by `NSPasteboard` (+ `ClipboardImage`
/// for the PNG rasterization). The platform implementation of the seam declared
/// in `PasteboardImageSource.swift` (ADR 0010).
public struct NSPasteboardImageSource: PasteboardImageSource {
    private let pasteboard: NSPasteboard
    public init(_ pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    public func imageFileURLs() -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
    }

    public func pngImageData() -> Data? { ClipboardImage.pngData(from: pasteboard) }
}
#endif
