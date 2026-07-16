#if canImport(AppKit)
import AppKit

/// Reads an image off the pasteboard for ⌘V image paste (#24) and normalizes
/// it to PNG bytes. A screenshot / copied bitmap arrives as raw TIFF (or an
/// `NSImage`), which we re-encode so the saved asset is always `.png`; a direct
/// PNG on the pasteboard passes through untouched. Lives in the package (not
/// the app) so the encode paths are unit-testable against a scratch pasteboard.
public enum ClipboardImage {
    /// The pasteboard's image as PNG bytes, or nil when it carries no image.
    public static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }
}
#endif
