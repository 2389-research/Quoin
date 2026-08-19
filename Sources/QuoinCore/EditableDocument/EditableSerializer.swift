import Foundation

public extension EditableDocument {
    /// Concatenate the segments. A pristine block re-emits its retained source
    /// bytes verbatim (byte-lossless); an edited block emits its live `text`.
    /// Trivia is emitted verbatim. (For Phase 1 a block's `text` IS its source
    /// slice whether pristine or edited, so this is a plain concatenation; the
    /// `pristine` distinction becomes load-bearing in Phase 1's later
    /// inline-canonicalization work and is kept explicit here so that hook
    /// exists.)
    func serialized() -> String {
        var out = ""
        out.reserveCapacity(segments.reduce(0) { acc, seg in
            switch seg {
            case .trivia(let t): return acc + t.utf8.count
            case .block(let b): return acc + b.text.utf8.count
            }
        })
        for seg in segments {
            switch seg {
            case .trivia(let t): out += t
            case .block(let b): out += b.text
            }
        }
        return out
    }
}
