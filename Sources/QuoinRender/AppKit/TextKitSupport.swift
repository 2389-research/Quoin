#if canImport(AppKit)
import AppKit

/// Converts a UTF-16 `NSRange` into a TextKit 2 `NSTextRange` within a content
/// manager, or nil when the offsets fall outside the document. `NSTextContentStorage`
/// is an `NSTextContentManager`, so both the reader coordinator and the text
/// view share this one conversion.
func nsTextRange(_ range: NSRange, in contentManager: NSTextContentManager) -> NSTextRange? {
    let documentStart = contentManager.documentRange.location
    guard let start = contentManager.location(documentStart, offsetBy: range.location),
          let end = contentManager.location(start, offsetBy: range.length)
    else { return nil }
    return NSTextRange(location: start, end: end)
}
#endif
