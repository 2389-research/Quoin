import Foundation

/// Maps between UTF-8 byte offsets and UTF-16 offsets for a single string.
///
/// Used to translate an editable block's local caret position (UTF-16, as
/// reported by `NSTextView`) to a document byte offset and back.
///
/// Both directions return `nil` for offsets that aren't valid Unicode
/// scalar boundaries: a UTF-8 offset that lands mid-scalar (e.g. inside the
/// two-byte encoding of "é"), or a UTF-16 offset that lands on the low half
/// of a surrogate pair (e.g. the second unit of "😀").
public struct UTF8IndexMap: Sendable {
    // utf16AtByte[b] = UTF-16 offset when b is a scalar-start byte (or the
    // string's end), else -1 (mid-scalar, not representable in UTF-16).
    private let utf16AtByte: [Int]
    // byteAtUTF16[u] = UTF-8 offset when u is the first UTF-16 unit of a
    // scalar (or the string's end), else -1 (the low half of a surrogate
    // pair, not a valid caret position).
    private let byteAtUTF16: [Int]

    public init(_ text: String) {
        var utf16AtByte = [Int](repeating: -1, count: text.utf8.count + 1)
        var byteAtUTF16 = [Int](repeating: -1, count: text.utf16.count + 1)

        var byte = 0
        var u16 = 0
        for scalar in text.unicodeScalars {
            utf16AtByte[byte] = u16
            byteAtUTF16[u16] = byte
            byte += String(scalar).utf8.count
            u16 += scalar.value > 0xFFFF ? 2 : 1
        }
        utf16AtByte[byte] = u16
        byteAtUTF16[u16] = byte

        self.utf16AtByte = utf16AtByte
        self.byteAtUTF16 = byteAtUTF16
    }

    public var utf8Count: Int { utf16AtByte.count - 1 }
    public var utf16Count: Int { byteAtUTF16.count - 1 }

    public func utf16(fromUTF8 byteOffset: Int) -> Int? {
        guard byteOffset >= 0, byteOffset < utf16AtByte.count else { return nil }
        let v = utf16AtByte[byteOffset]
        return v >= 0 ? v : nil
    }

    public func utf8(fromUTF16 utf16Offset: Int) -> Int? {
        guard utf16Offset >= 0, utf16Offset < byteAtUTF16.count else { return nil }
        let v = byteAtUTF16[utf16Offset]
        return v >= 0 ? v : nil
    }
}
