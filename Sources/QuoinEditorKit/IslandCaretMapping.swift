import Foundation

/// Converts an editable island's caret between two coordinate spaces:
/// the island-local UTF-16 offset `NSTextView.selectedRange()` reports,
/// and the absolute UTF-8 byte offset into the document source.
///
/// A thin composition over `UTF8IndexMap`, which does the actual
/// UTF-8/UTF-16 boundary bookkeeping for the island's own source string.
public enum IslandCaretMapping {
    /// Island-local UTF-16 caret → absolute document byte offset.
    ///
    /// Returns `nil` when `caret` is out of range or lands on the low
    /// half of a surrogate pair (not a valid caret position).
    public static func documentByte(localUTF16 caret: Int, islandSource: String, islandByteStart: Int) -> Int? {
        guard let localByte = UTF8IndexMap(islandSource).utf8(fromUTF16: caret) else { return nil }
        return islandByteStart + localByte
    }

    /// Absolute document byte offset → island-local UTF-16 caret (to
    /// re-seed the caret after reconcile).
    ///
    /// Returns `nil` when `offset` falls before the island's start, is
    /// otherwise out of range, or lands mid-scalar.
    public static func localUTF16(documentByte offset: Int, islandSource: String, islandByteStart: Int) -> Int? {
        guard offset >= islandByteStart else { return nil }
        return UTF8IndexMap(islandSource).utf16(fromUTF8: offset - islandByteStart)
    }
}
