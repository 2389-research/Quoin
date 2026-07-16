import Foundation

/// Find & replace over the document's RAW SOURCE, in bytes — because a
/// replace changes what the file says, it must operate on the source of
/// truth, not the rendered projection (the visual find is projection-based
/// for navigation; replace is source-based for correctness). Matching is
/// literal and case-insensitive, the least-surprising behavior for a
/// replace field; every edit routes through the session, so undo and
/// byte-losslessness come for free.
public enum SourceReplace {

    /// Byte ranges of every literal (case-insensitive) occurrence of
    /// `query` in `source`, left to right, non-overlapping.
    public static func matches(of query: String, in source: String) -> [ByteRange] {
        guard !query.isEmpty else { return [] }
        var results: [ByteRange] = []
        var searchStart = source.startIndex
        while searchStart < source.endIndex,
              let found = source.range(
                of: query, options: [.caseInsensitive],
                range: searchStart..<source.endIndex) {
            let lower = source.utf8.distance(
                from: source.utf8.startIndex, to: found.lowerBound.samePosition(in: source.utf8)!)
            let upper = source.utf8.distance(
                from: source.utf8.startIndex, to: found.upperBound.samePosition(in: source.utf8)!)
            results.append(ByteRange(offset: lower, length: upper - lower))
            // Advance past the match; never spin on a zero-width find.
            searchStart = found.upperBound > found.lowerBound
                ? found.upperBound : source.index(after: found.lowerBound)
        }
        return results
    }

    /// The edit that replaces the FIRST match at or after `fromByteOffset`
    /// (wrapping to the start when none follow), or nil when there is no
    /// match. `nextSearchOffset` is where a follow-on "replace next" should
    /// resume (just past the replacement).
    public static func replaceNextEdit(
        of query: String, with replacement: String, in source: String,
        fromByteOffset: Int
    ) -> (edit: SourceEdit, nextSearchOffset: Int)? {
        let all = matches(of: query, in: source)
        guard !all.isEmpty else { return nil }
        let target = all.first { $0.offset >= fromByteOffset } ?? all[0]
        return (
            SourceEdit(range: target, replacement: replacement),
            target.offset + replacement.utf8.count
        )
    }

    /// ONE atomic edit replacing every match (one undo restores all).
    /// Applied right-to-left internally but emitted as a single spanning
    /// splice from the first match to the last, so the session records one
    /// history entry. Nil when there are no matches.
    public static func replaceAllEdit(
        of query: String, with replacement: String, in source: String
    ) -> SourceEdit? {
        let all = matches(of: query, in: source)
        guard let first = all.first, let last = all.last else { return nil }
        let bytes = Array(source.utf8)
        // Rebuild the span [first.offset, last.end) with every match
        // replaced; the bytes outside stay untouched (byte-lossless).
        var out: [UInt8] = []
        var cursor = first.offset
        let repl = Array(replacement.utf8)
        for m in all {
            out.append(contentsOf: bytes[cursor..<m.offset])
            out.append(contentsOf: repl)
            cursor = m.offset + m.length
        }
        let spanEnd = last.offset + last.length
        return SourceEdit(
            range: ByteRange(offset: first.offset, length: spanEnd - first.offset),
            replacement: String(decoding: out, as: UTF8.self))
    }
}
