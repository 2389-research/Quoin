import Foundation

/// Turns a chunk of selected text — handed in by the macOS Services menu
/// ("New Quoin Document with Selection") — into the two things a new document
/// needs: a filename *base* and a document body. Pure and platform-free so the
/// naming/content rules are unit-testable without touching a live
/// `NSPasteboard` (the pasteboard handler in the app shell is a thin wrapper
/// over this seam).
///
/// The body is the selection verbatim, only newline-normalized and given a
/// trailing newline (the POSIX text convention for a fresh file). The base
/// name is derived from the selection's first non-empty line, lightly
/// de-marked (a leading `#` heading run or `- `/`* `/`1.` list marker is not
/// wanted in a filename) and then run through `FilenamePolicy` so it is a safe,
/// length-bounded on-disk name that falls back to "Untitled" when the
/// selection has no usable title line.
public enum NewDocumentSeed {

    public struct Seed: Equatable, Sendable {
        /// Filename base (no extension); already `FilenamePolicy`-sanitized.
        public let baseName: String
        /// Document body to write to disk.
        public let content: String

        public init(baseName: String, content: String) {
            self.baseName = baseName
            self.content = content
        }
    }

    /// A friendlier cap for a *title* than `FilenamePolicy`'s 200-byte
    /// filesystem budget: a selection's first line can be a whole sentence, and
    /// a tidy name beats a paragraph-long one. `FilenamePolicy` still enforces
    /// the hard byte limit underneath.
    static let maxTitleCharacters = 60

    public static func make(fromSelection text: String) -> Seed {
        let normalized = normalizeNewlines(text)
        return Seed(baseName: baseName(from: normalized), content: body(from: normalized))
    }

    // MARK: - Body

    private static func body(from normalized: String) -> String {
        // A brand-new file, so byte-losslessness doesn't bind here; end with a
        // single trailing newline unless the selection is empty.
        guard !normalized.isEmpty else { return "" }
        return normalized.hasSuffix("\n") ? normalized : normalized + "\n"
    }

    // MARK: - Name

    private static func baseName(from normalized: String) -> String {
        let firstLine = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        let titled = deMark(firstLine)
        let capped = cap(titled, to: maxTitleCharacters)
        // FilenamePolicy owns the fallback + the hard byte/whitespace/leading-
        // dot rules; deferring to it keeps one source of truth for file names.
        return FilenamePolicy.sanitize(capped)
    }

    /// Strips a leading heading run (`#` … up to six, then a space) or a list
    /// marker (`- `, `* `, `+ `, `1. `) so a selected heading or bullet becomes
    /// a clean title. Only the *title* is de-marked; the body keeps the source
    /// verbatim.
    private static func deMark(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        // Heading: 1–6 '#' followed by whitespace.
        let hashRun = s.prefix(while: { $0 == "#" }).count
        if hashRun >= 1, hashRun <= 6 {
            let afterHashes = s.dropFirst(hashRun)
            if afterHashes.first == " " || afterHashes.first == "\t" {
                s = String(afterHashes).trimmingCharacters(in: .whitespaces)
                return s
            }
        }
        // Bullet list: - * + followed by a space.
        if let first = s.first, first == "-" || first == "*" || first == "+" {
            let rest = s.dropFirst()
            if rest.first == " " || rest.first == "\t" {
                return String(rest).trimmingCharacters(in: .whitespaces)
            }
        }
        // Ordered list: digits then '.' or ')' then a space.
        let digits = s.prefix(while: { $0.isNumber })
        if !digits.isEmpty {
            let afterDigits = s.dropFirst(digits.count)
            if let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" {
                let rest = afterDigits.dropFirst()
                if rest.first == " " || rest.first == "\t" {
                    return String(rest).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return s
    }

    /// Truncate on grapheme-cluster boundaries so a title never splits an emoji
    /// or a base+combining-mark pair mid-character.
    private static func cap(_ s: String, to characters: Int) -> String {
        guard s.count > characters else { return s }
        return String(s.prefix(characters))
    }

    private static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
