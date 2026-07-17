import Foundation

/// The options that shape a find/replace match. One value drives BOTH the
/// projection-based visual find scan (`ReaderCoordinator.performSearchScan`)
/// and the source-based replace (`SourceReplace`), so a query can never mean
/// one thing to the highlight/count and another to Replace-All (the shipped
/// "two recognizers for one grammar diverge" bug class; #23).
public struct SearchOptions: Equatable, Sendable {
    /// Case-sensitive when true; otherwise Unicode case-insensitive.
    /// Diacritics are ALWAYS significant — "cafe" never matches "café" —
    /// because a replace acts on the source bytes and must not silently
    /// rewrite an accented word.
    public var matchCase: Bool
    /// Match only whole words: the run must be bounded by non-word
    /// characters (or the ends of the scanned range) on both sides.
    public var wholeWord: Bool
    /// Interpret the query as an ICU regular expression rather than a
    /// literal string. Invalid patterns match nothing (never crash).
    public var regex: Bool

    public init(matchCase: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.regex = regex
    }

    /// The default (case-insensitive, diacritic-sensitive, literal) — the
    /// least-surprising behavior and the pre-#23 baseline.
    public static let literalCaseInsensitive = SearchOptions()
}

/// The ONE matcher both find-highlighting and replace share. Works in
/// UTF-16 (`NSString`/`NSRange`) — the common denominator between the
/// TextKit projection and `NSRegularExpression`; `SourceReplace` bridges
/// the results to source byte ranges. Matches are left-to-right and
/// non-overlapping; zero-width matches (e.g. a regex that can match the
/// empty string) are dropped so a highlight or a replace never lands on an
/// empty run.
public enum TextMatcher {

    /// Every match of `query` in `haystack`, honoring `options`, optionally
    /// restricted to `range` (In-Selection scoping). Returns nil ONLY when
    /// `options.regex`/`options.wholeWord` require a regular expression and
    /// the pattern is invalid — callers surface a subtle invalid state and
    /// highlight/replace nothing. An empty query returns an empty array.
    public static func matches(
        of query: String,
        in haystack: NSString,
        options: SearchOptions = SearchOptions(),
        within range: NSRange? = nil
    ) -> [NSRange]? {
        guard !query.isEmpty else { return [] }

        // Clamp the scan window to the haystack; a caller's stale selection
        // range must never index out of bounds.
        let full = NSRange(location: 0, length: haystack.length)
        let scope: NSRange
        if let range {
            let lower = min(max(0, range.location), haystack.length)
            let upper = min(max(lower, NSMaxRange(range)), haystack.length)
            scope = NSRange(location: lower, length: upper - lower)
        } else {
            scope = full
        }
        guard scope.length > 0 else { return [] }

        if options.regex || options.wholeWord {
            guard let regex = try? regularExpression(for: query, options: options) else { return nil }
            var results: [NSRange] = []
            regex.enumerateMatches(in: haystack as String, options: [], range: scope) { match, _, _ in
                if let r = match?.range, r.length > 0, r.location != NSNotFound {
                    results.append(r)
                }
            }
            return results
        }

        // Literal fast path: exactly the pre-#23 behavior (case-insensitive
        // unless Match Case, always diacritic-sensitive).
        let compareOptions: NSString.CompareOptions = options.matchCase ? [] : [.caseInsensitive]
        var results: [NSRange] = []
        var searchRange = scope
        while searchRange.length > 0 {
            let found = haystack.range(of: query, options: compareOptions, range: searchRange)
            guard found.location != NSNotFound else { break }
            results.append(found)
            // Advance past the match; never spin on a zero-width find.
            let next = found.location + max(found.length, 1)
            let end = NSMaxRange(scope)
            guard next < end else { break }
            searchRange = NSRange(location: next, length: end - next)
        }
        return results
    }

    /// Whether `query` compiles under `options` — the find bar's invalid
    /// pattern indicator drives off this (a literal query is always valid).
    public static func isValidQuery(_ query: String, options: SearchOptions) -> Bool {
        guard !query.isEmpty, options.regex || options.wholeWord else { return true }
        return (try? regularExpression(for: query, options: options)) != nil
    }

    /// The compiled expression for a regex and/or whole-word query. Whole
    /// word wraps the (possibly literal, then escaped) pattern in
    /// zero-width boundary lookarounds — more robust than `\b…\b` for
    /// queries that start or end with a non-word character.
    private static func regularExpression(
        for query: String, options: SearchOptions
    ) throws -> NSRegularExpression {
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord {
            pattern = "(?<![\\p{L}\\p{N}_])(?:\(pattern))(?![\\p{L}\\p{N}_])"
        }
        let regexOptions: NSRegularExpression.Options = options.matchCase ? [] : [.caseInsensitive]
        return try NSRegularExpression(pattern: pattern, options: regexOptions)
    }
}
