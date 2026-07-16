import Foundation

/// The ONE word counter (both stats sites route here — the fast-path
/// delta and the full-parse total must agree by construction).
///
/// On Darwin this is `.byWords` enumeration. swift-corelibs-foundation
/// marks `.byWords` explicitly unavailable (no ICU word breaking), so
/// Linux uses a letter/number-run fallback matching ICU's observed
/// behavior on prose: apostrophes (straight and curly) join ("don't" is
/// one word), HYPHENS BREAK ("byte-safe" is two — verified against
/// `.byWords`), and a period joins only between digits ("3.14" is one).
/// CJK text under-counts on Linux relative to ICU; the platforms plan
/// (docs/design/platforms.md Phase 0) accepts that as a documented
/// approximation, pinned by the cross-platform parity test.
enum WordCounting {

    static func count(in text: String) -> Int {
        #if canImport(Darwin)
        var words = 0
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, _, _, _ in
            words += 1
        }
        return words
        #else
        return fallbackCount(in: text)
        #endif
    }

    /// Exposed for the parity test (runs on BOTH platforms, comparing
    /// against `.byWords` where available).
    static func fallbackCount(in text: String) -> Int {
        var words = 0
        var inWord = false
        var previousWasJoiner = false
        var previousWasDigit = false
        for scalar in text.unicodeScalars {
            let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
            let isWordScalar = scalar.properties.isAlphabetic
                || isDigit
                || scalar.properties.numericType != nil
            if isWordScalar {
                if !inWord { words += 1 }
                inWord = true
                previousWasJoiner = false
                previousWasDigit = isDigit
            } else if inWord, !previousWasJoiner,
                      scalar == "'" || scalar == "\u{2019}"
                        || (scalar == "." && previousWasDigit) {
                // Joiners, exactly one at a time: apostrophes inside words
                // ("don't"), a period between digits ("3.14"). Hyphens
                // deliberately BREAK — that is `.byWords`' behavior.
                previousWasJoiner = true
            } else {
                inWord = false
                previousWasJoiner = false
                previousWasDigit = false
            }
        }
        return words
    }
}
