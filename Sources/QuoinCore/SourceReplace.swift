import Foundation

/// Find & replace over the document's RAW SOURCE, in bytes — because a
/// replace changes what the file says, it must operate on the source of
/// truth, not the rendered projection (the visual find is projection-based
/// for navigation; replace is source-based for correctness). Both paths
/// draw their match rules from the SAME `TextMatcher`, so the highlight/count
/// and Replace-All can never recognize different occurrences (#23). Every
/// edit routes through the session, so undo and byte-losslessness come free.
public enum SourceReplace {

    /// Byte ranges of every occurrence of `query` in `source` under
    /// `options`, left to right, non-overlapping. `within` scopes the search
    /// to a source byte range (In-Selection). An invalid regex yields no
    /// matches (never a crash) — the find bar shows the invalid state.
    public static func matches(
        of query: String,
        in source: String,
        options: SearchOptions = SearchOptions(),
        within scope: ByteRange? = nil
    ) -> [ByteRange] {
        guard !query.isEmpty else { return [] }
        let haystack = source as NSString

        // Scope: byte range → UTF-16 NSRange for the matcher.
        var nsScope: NSRange?
        if let scope {
            guard let lower = EditMapping.utf16Offset(inText: source, utf8Offset: scope.offset),
                  let upper = EditMapping.utf16Offset(inText: source, utf8Offset: scope.upperBound)
            else { return [] }
            nsScope = NSRange(location: lower, length: upper - lower)
        }

        guard let nsRanges = TextMatcher.matches(
            of: query, in: haystack, options: options, within: nsScope)
        else { return [] }

        // NSRange (UTF-16) → ByteRange (UTF-8); a match on a non-scalar
        // boundary is impossible here (matcher ranges are whole matches).
        return nsRanges.compactMap { r in
            EditMapping.utf8Range(inText: source, utf16Range: r.location..<NSMaxRange(r))
        }
    }

    /// The edit that replaces the FIRST match at or after `fromByteOffset`
    /// (wrapping to the start when none follow), or nil when there is no
    /// match. `nextSearchOffset` is where a follow-on "replace next" should
    /// resume (just past the replacement). `replacement` is inserted
    /// literally — regex capture-group substitution is intentionally not
    /// supported (a `$1` in the replacement is the two characters `$1`).
    public static func replaceNextEdit(
        of query: String, with replacement: String, in source: String,
        fromByteOffset: Int,
        options: SearchOptions = SearchOptions(),
        within scope: ByteRange? = nil
    ) -> (edit: SourceEdit, nextSearchOffset: Int)? {
        let all = matches(of: query, in: source, options: options, within: scope)
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
        of query: String, with replacement: String, in source: String,
        options: SearchOptions = SearchOptions(),
        within scope: ByteRange? = nil
    ) -> SourceEdit? {
        let all = matches(of: query, in: source, options: options, within: scope)
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
