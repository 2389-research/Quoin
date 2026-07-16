import Foundation

/// Shared scalar helpers for the two hand-rolled YAML readers (front matter
/// and review endmatter), so the escape grammar can't drift between them.
enum YAMLScalar {
    /// Single left-to-right unescape of a double-quoted scalar's inner body
    /// (the surrounding quotes already stripped): `\x` → `x`. ONE pass — the
    /// two-pass `replacingOccurrences` version mangled `\\\"` (it unescaped the
    /// backslash, then treated the freed quote as an escape).
    static func unescapeDoubleQuotedBody<S: StringProtocol>(_ inner: S) -> String {
        var unescaped = ""
        var iterator = inner.makeIterator()
        while let ch = iterator.next() {
            if ch == "\\", let next = iterator.next() {
                unescaped.append(next)
            } else {
                unescaped.append(ch)
            }
        }
        return unescaped
    }
}
