import Foundation

extension StringProtocol {
    /// Byte-level substring presence over the UTF-8 view.
    ///
    /// `String.contains` / `String.range(of:)` are Unicode-grapheme-aware:
    /// on a multi-megabyte document a single full search costs tens of
    /// milliseconds even when it finds nothing. For ASCII structural markers
    /// (`$$`, `\[`, `\n---\n`) grapheme awareness is unnecessary — a plain
    /// byte scan is 10–50× faster and identical in result, because these
    /// markers have exactly one UTF-8 byte encoding. Used by the parse
    /// preprocessing passes to bail out cheaply on documents that contain no
    /// front matter / math / endmatter (see performance.md → Benchmarks).
    func utf8Contains(_ needle: [UInt8]) -> Bool {
        guard let first = needle.first else { return true }
        let view = utf8
        var cursor = view.startIndex
        while let hit = view[cursor...].firstIndex(of: first) {
            var vi = hit
            var ni = needle.startIndex
            var matched = true
            while ni < needle.endIndex {
                if vi == view.endIndex || view[vi] != needle[ni] {
                    matched = false
                    break
                }
                vi = view.index(after: vi)
                ni += 1
            }
            if matched { return true }
            cursor = view.index(after: hit)
        }
        return false
    }
}
