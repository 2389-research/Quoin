import Foundation

/// Dependency-free allowlist scrubber for raw HTML embedded in Markdown, used
/// by the standalone HTML export's sanitize policy (issue #4).
///
/// It is a conservative HTML *fragment* cleaner, NOT a full HTML5 parser — the
/// export pipeline never adds a third-party dependency (dependency policy). Its
/// job is to strip the genuinely risky things a hostile or careless `.md` file
/// can carry while leaving benign structural markup intact:
///
///  - **removes** `<script>` / `<style>` / `<iframe>` / `<object>` / `<embed>`
///    elements entirely (`<script>`/`<style>` along with their raw-text
///    content; `<iframe>`/`<object>` with their content when a close tag is
///    present; `<embed>` is a void tag);
///  - strips every `on*` event-handler attribute (case-insensitive);
///  - strips `javascript:` / `vbscript:` URLs from URL-bearing attributes
///    (whitespace and control characters are ignored first, matching how
///    browsers parse a URL scheme);
///  - neutralises auto-loading REMOTE resources — the tracking-pixel / remote
///    embed vector: `http(s)` and protocol-relative (`//host`) `src` /
///    `srcset` / `poster` / `background` on
///    `<img>/<source>/<audio>/<video>/<track>/<input>` are dropped, and so are
///    remote `href`/`xlink:href` on `<link>` (stylesheet / preload), `<base>`
///    (relative-URL rebasing), and SVG `<image>`, plus a `<meta
///    http-equiv=refresh>` whose `content` auto-navigates to a remote URL — so
///    a saved file fetches nothing off-device with zero interaction;
///  - neutralises `data:` navigation targets that yield an active document
///    (`data:text/html`, `data:application/xhtml`, `data:image/svg`) on
///    `<a>`/`<area>` links, alongside `javascript:`/`vbscript:`;
///  - **preserves** benign structural HTML (tables, spans, emphasis, links,
///    HTML comments, `data:` images, inline `style=`).
///
/// Documented limits (acceptable for an export scrubber, not a security
/// boundary): it does not decode HTML entities inside attribute values (so an
/// entity-obfuscated `javascript:` scheme is not caught), and it does not scrub
/// `url(...)` inside inline `style=` attributes. Anything it cannot confidently
/// parse as a tag it emits as literal text.
public enum HTMLSanitizer {

    /// Elements removed outright (never rendered in a sanitized export).
    static let forbiddenElements: Set<String> = ["script", "style", "iframe", "object", "embed"]
    /// Raw-text forbidden elements: their content runs to `</name>`.
    static let rawTextForbidden: Set<String> = ["script", "style"]
    /// Void forbidden elements: a single tag, no content to skip.
    static let voidForbidden: Set<String> = ["embed"]
    // The remainder (iframe, object) are container forbidden elements.

    /// Attribute names whose value is a URL we scheme-check for `javascript:`.
    static let urlAttributes: Set<String> = [
        "href", "src", "xlink:href", "formaction", "action", "srcset",
        "background", "poster", "data", "cite", "longdesc", "usemap",
    ]
    /// Tags that auto-load a resource from their URL attributes.
    static let remoteResourceTags: Set<String> = [
        "img", "source", "audio", "video", "track", "input", "image",
    ]
    /// Auto-loading URL attributes on `remoteResourceTags` that must not point
    /// at a remote host in a private, self-contained file.
    static let remoteResourceAttributes: Set<String> = ["src", "srcset", "poster", "background"]
    /// Tags that auto-load from a remote `href`/`xlink:href` (not `src`):
    /// `<link>` (stylesheet / preload font), `<base>` (rebases every relative
    /// URL onto a remote origin), and SVG `<image>`. A remote value here fetches
    /// off-device on load with no interaction, exactly like a tracking pixel.
    static let remoteHrefTags: Set<String> = ["link", "base", "image", "use"]
    /// The `href`-family attributes checked on `remoteHrefTags` (and on links
    /// for dangerous navigation schemes).
    static let hrefAttributes: Set<String> = ["href", "xlink:href"]
    /// Navigation elements whose `href` is followed on click: a `data:` document
    /// or `javascript:` here executes in the file's origin.
    static let navigationTags: Set<String> = ["a", "area"]

    /// Scrubs a raw HTML fragment per the policy above.
    public static func sanitize(_ html: String) -> String {
        let s = Array(html)
        let n = s.count
        var out = ""
        var i = 0

        while i < n {
            let c = s[i]
            guard c == "<" else {
                out.append(c)
                i += 1
                continue
            }

            // HTML comment: pass through verbatim (inert).
            if i + 3 < n, s[i + 1] == "!", s[i + 2] == "-", s[i + 3] == "-" {
                let end = findCommentEnd(s, from: i + 4)
                out += String(s[i..<end])
                i = end
                continue
            }
            // Declaration / processing instruction (`<!doctype…>`, `<?…>`):
            // pass through to the next `>`.
            if i + 1 < n, s[i + 1] == "!" || s[i + 1] == "?" {
                var j = i + 1
                while j < n, s[j] != ">" { j += 1 }
                if j < n { j += 1 }
                out += String(s[i..<j])
                i = j
                continue
            }

            guard let tag = parseTag(s, i) else {
                // A `<` that does not start a tag is literal text.
                out.append(c)
                i += 1
                continue
            }

            let lname = tag.name.lowercased()
            if forbiddenElements.contains(lname) {
                if tag.isClosing || tag.selfClosing || voidForbidden.contains(lname) {
                    // Stray close, self-closed, or void: drop just the tag.
                    i = tag.end
                } else if rawTextForbidden.contains(lname) {
                    // <script>/<style>: everything up to </name> is raw text.
                    // If unterminated, drop the rest — a browser would treat it
                    // all as script/style, so we must not leak it.
                    i = findClose(s, from: tag.end, name: lname) ?? n
                } else {
                    // <iframe>/<object>: drop content when closed, else the tag.
                    i = findClose(s, from: tag.end, name: lname) ?? tag.end
                }
                continue
            }

            out += serialize(tag, attributes: filterAttributes(tag))
            i = tag.end
        }

        return out
    }

    // MARK: - Scheme classification (shared with HTMLExporter's link/image path)

    /// True when a URL's scheme is `javascript:` or `vbscript:`, ignoring
    /// leading/embedded whitespace and control characters the way a browser
    /// does before it parses the scheme.
    static func isDangerousScheme(_ value: String) -> Bool {
        let lower = strippedScheme(value)
        return lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:")
    }

    /// True when a URL, *navigated to* from a link, yields an active document in
    /// the file's origin: `javascript:`/`vbscript:`, or a `data:` document whose
    /// media type renders as scriptable markup (`text/html`, `application/xhtml`,
    /// `image/svg`). This is stricter than `isDangerousScheme` and is applied
    /// ONLY to link/navigation contexts — a `data:image/png` (or `data:image/svg`)
    /// loaded as an `<img>` is inert and stays allowlisted.
    static func isDangerousNavigationScheme(_ value: String) -> Bool {
        if isDangerousScheme(value) { return true }
        let lower = strippedScheme(value)
        guard lower.hasPrefix("data:") else { return false }
        let mediatype = lower.dropFirst("data:".count).prefix { $0 != "," && $0 != ";" }
        return mediatype.hasPrefix("text/html")
            || mediatype.hasPrefix("application/xhtml")
            || mediatype.hasPrefix("image/svg")
    }

    /// True when a URL points at a remote host (`http(s)://` or `//host`).
    static func isRemoteURL(_ value: String) -> Bool {
        let lower = strippedScheme(value)
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//")
    }

    private static func strippedScheme(_ value: String) -> String {
        // Decode the character references a browser resolves inside an
        // attribute value BEFORE it parses the scheme. Without this,
        // `href="&#106;avascript:alert(1)"` reads as an inert string here while
        // the browser decodes `&#106;` → `j` and runs a live `javascript:`.
        let decoded = decodingCharacterReferences(value)
        return String(decoded.unicodeScalars.filter { $0.value > 0x20 }).lowercased()
    }

    /// Decode numeric (`&#106;`, `&#x6a;`) and a small set of named character
    /// references that can hide a URL scheme (`&colon;` → `:`, `&NewLine;`,
    /// `&Tab;` → whitespace stripped by `strippedScheme`). Not a full HTML
    /// entity table — just the references a browser would resolve in a URL
    /// before scheme parsing, so `strippedScheme` classifies what the browser
    /// will actually see. Unrecognized `&…` is left verbatim.
    static func decodingCharacterReferences(_ value: String) -> String {
        guard value.contains("&") else { return value }
        let named: [String: Character] = [
            "colon": ":", "tab": "\t", "newline": "\n", "sol": "/",
            "excl": "!", "lpar": "(", "rpar": ")", "period": ".",
        ]
        let chars = Array(value)
        let n = chars.count
        var out = ""
        var i = 0
        while i < n {
            guard chars[i] == "&" else { out.append(chars[i]); i += 1; continue }
            // Numeric reference: &#123; or &#x1F;  (trailing `;` optional).
            if i + 1 < n, chars[i + 1] == "#" {
                var j = i + 2
                let hex = j < n && (chars[j] == "x" || chars[j] == "X")
                if hex { j += 1 }
                let start = j
                while j < n, hex ? chars[j].isHexDigit : chars[j].isNumber { j += 1 }
                if j > start,
                   let code = UInt32(String(chars[start..<j]), radix: hex ? 16 : 10),
                   let scalar = Unicode.Scalar(code) {
                    out.append(Character(scalar))
                    if j < n, chars[j] == ";" { j += 1 }
                    i = j
                    continue
                }
                out.append(chars[i]); i += 1; continue
            }
            // Named reference from the small scheme-relevant set.
            var j = i + 1
            while j < n, chars[j].isLetter, j - i <= 10 { j += 1 }
            if let ch = named[String(chars[(i + 1)..<j]).lowercased()] {
                out.append(ch)
                if j < n, chars[j] == ";" { j += 1 }
                i = j
                continue
            }
            out.append(chars[i]); i += 1
        }
        return out
    }

    private static func srcsetHasRemote(_ value: String) -> Bool {
        value.split(separator: ",").contains { candidate in
            let url = candidate.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            return isRemoteURL(url)
        }
    }

    // MARK: - Attribute filtering

    private static func filterAttributes(_ tag: ParsedTag) -> [Attribute] {
        let lname = tag.name.lowercased()
        let isResource = remoteResourceTags.contains(lname)
        let isHrefResource = remoteHrefTags.contains(lname)
        let isNavigation = navigationTags.contains(lname)
        let metaRefresh = isMetaRefresh(tag)
        return tag.attributes.filter { attr in
            let an = attr.name.lowercased()
            if an.hasPrefix("on") { return false }              // event handler
            // Inline CSS can auto-fetch off-device via `url(...)` in any
            // property (background, list-style-image, border-image, …), and
            // detecting that reliably means parsing CSS (comments, hex escapes,
            // whitespace splits). Rather than play that cat-and-mouse and risk
            // leaking a tracking pixel — contradicting the "fetches nothing
            // off-device" guarantee — sanitize mode drops `style` wholesale.
            // Inline styling is cosmetic; a private export forgoes it.
            if an == "style" { return false }
            guard let v = attr.value else { return true }
            // Link destinations: strip javascript:/vbscript: AND active data:
            // documents (the click-to-XSS vector).
            if isNavigation, hrefAttributes.contains(an), isDangerousNavigationScheme(v) {
                return false
            }
            if urlAttributes.contains(an), isDangerousScheme(v) {
                return false                                    // javascript:/vbscript:
            }
            if isResource, remoteResourceAttributes.contains(an) {
                let remote = an == "srcset" ? srcsetHasRemote(v) : isRemoteURL(v)
                if remote { return false }                      // remote auto-load
            }
            // Remote <link>/<base>/SVG <image> href auto-loads off-device.
            if isHrefResource, hrefAttributes.contains(an), isRemoteURL(v) {
                return false
            }
            // <meta http-equiv=refresh content="…;url=remote">: drop the
            // auto-navigation directive (a click-free off-device redirect).
            if metaRefresh, an == "content", metaRefreshIsRemote(v) {
                return false
            }
            return true
        }
    }

    /// True when the tag is a `<meta http-equiv="refresh">` (case-insensitive).
    private static func isMetaRefresh(_ tag: ParsedTag) -> Bool {
        guard tag.name.lowercased() == "meta" else { return false }
        return tag.attributes.contains { attr in
            attr.name.lowercased() == "http-equiv"
                && (attr.value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "refresh")
        }
    }

    /// True when a `<meta http-equiv=refresh>` `content` value
    /// (`"<seconds>[; url=<url>]"`) auto-navigates to a remote URL.
    private static func metaRefreshIsRemote(_ content: String) -> Bool {
        for part in content.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("url=") else { continue }
            var url = String(trimmed.dropFirst("url=".count)).trimmingCharacters(in: .whitespaces)
            if let quote = url.first, quote == "\"" || quote == "'" {
                url.removeFirst()
                if url.last == quote { url.removeLast() }
            }
            return isRemoteURL(url)
        }
        return false
    }

    // MARK: - Tag parsing / serialization

    private struct Attribute {
        var name: String
        var value: String?
    }

    private struct ParsedTag {
        var name: String
        var isClosing: Bool
        var selfClosing: Bool
        var attributes: [Attribute]
        /// Index just past the tag's closing `>` (or end of input if none).
        var end: Int
    }

    /// Parses the tag beginning at `start` (which must be `<`). Returns nil when
    /// what follows is not a tag (so the caller can treat `<` as literal text).
    private static func parseTag(_ s: [Character], _ start: Int) -> ParsedTag? {
        let n = s.count
        var i = start + 1
        var isClosing = false
        if i < n, s[i] == "/" {
            isClosing = true
            i += 1
        }
        guard i < n, isNameStart(s[i]) else { return nil }

        var name = ""
        while i < n, isNameChar(s[i]) {
            name.append(s[i])
            i += 1
        }

        var attributes: [Attribute] = []
        var selfClosing = false

        while i < n {
            while i < n, isSpace(s[i]) { i += 1 }
            if i >= n { break }
            if s[i] == ">" {
                i += 1
                return ParsedTag(name: name, isClosing: isClosing, selfClosing: selfClosing,
                                 attributes: attributes, end: i)
            }
            if s[i] == "/" {
                var k = i + 1
                while k < n, isSpace(s[k]) { k += 1 }
                if k < n, s[k] == ">" {
                    selfClosing = true
                    i = k + 1
                    return ParsedTag(name: name, isClosing: isClosing, selfClosing: selfClosing,
                                     attributes: attributes, end: i)
                }
                i += 1  // stray slash
                continue
            }

            // Attribute name.
            var aname = ""
            while i < n, !isSpace(s[i]), s[i] != "=", s[i] != ">", s[i] != "/" {
                aname.append(s[i])
                i += 1
            }
            if aname.isEmpty {
                i += 1  // defensive: never spin on an unexpected char
                continue
            }

            // Optional `= value`.
            var value: String?
            var k = i
            while k < n, isSpace(s[k]) { k += 1 }
            if k < n, s[k] == "=" {
                i = k + 1
                while i < n, isSpace(s[i]) { i += 1 }
                if i < n, s[i] == "\"" || s[i] == "'" {
                    let quote = s[i]
                    i += 1
                    var v = ""
                    while i < n, s[i] != quote {
                        v.append(s[i])
                        i += 1
                    }
                    if i < n { i += 1 }  // past closing quote
                    value = v
                } else {
                    var v = ""
                    while i < n, !isSpace(s[i]), s[i] != ">" {
                        v.append(s[i])
                        i += 1
                    }
                    value = v
                }
            }
            attributes.append(Attribute(name: aname, value: value))
        }

        // Unterminated tag: consume to end of input.
        return ParsedTag(name: name, isClosing: isClosing, selfClosing: selfClosing,
                         attributes: attributes, end: n)
    }

    private static func serialize(_ tag: ParsedTag, attributes: [Attribute]) -> String {
        var out = "<"
        if tag.isClosing { out += "/" }
        out += tag.name
        for attr in attributes {
            out += " " + attr.name
            if let v = attr.value {
                // Re-quote with `"`; escape only `"` so existing entities in the
                // value are preserved verbatim.
                out += "=\"" + v.replacingOccurrences(of: "\"", with: "&quot;") + "\""
            }
        }
        if tag.selfClosing { out += " /" }
        out += ">"
        return out
    }

    // MARK: - Scanning helpers

    /// Index just past the matching `</name>` from `from`, or nil if absent.
    private static func findClose(_ s: [Character], from: Int, name: String) -> Int? {
        let n = s.count
        var i = from
        while i < n {
            if s[i] == "<", i + 1 < n, s[i + 1] == "/" {
                var j = i + 2
                var candidate = ""
                while j < n, isNameChar(s[j]) {
                    candidate.append(s[j])
                    j += 1
                }
                if candidate.lowercased() == name {
                    while j < n, s[j] != ">" { j += 1 }
                    if j < n { j += 1 }
                    return j
                }
            }
            i += 1
        }
        return nil
    }

    /// Index just past the end of an HTML comment whose `<!--` opener ended at
    /// `from`, matching the HTML5 tokenizer's comment-closing rules — NOT just
    /// the literal `-->`. Browsers also close a comment on the abrupt-close
    /// forms `<!-->` and `<!--->` (empty comment) and on the comment-end-bang
    /// `--!>`. A scanner that only searched for `-->` would treat live markup
    /// after one of those sequences as comment text and pass an embedded
    /// `<script>` through untouched — a sanitizer bypass. An unterminated
    /// comment runs to EOF, which the browser also treats as comment (inert).
    private static func findCommentEnd(_ s: [Character], from: Int) -> Int {
        let n = s.count
        // Abrupt closing of an empty comment: `<!-->` (from at `>`) and
        // `<!--->` (from at `-` then `>`).
        if from < n, s[from] == ">" { return from + 1 }
        if from + 1 < n, s[from] == "-", s[from + 1] == ">" { return from + 2 }
        var i = from
        while i < n {
            // `--!>` — comment-end-bang state closes the comment.
            if i + 3 < n, s[i] == "-", s[i + 1] == "-", s[i + 2] == "!", s[i + 3] == ">" {
                return i + 4
            }
            // `-->` — the ordinary terminator.
            if i + 2 < n, s[i] == "-", s[i + 1] == "-", s[i + 2] == ">" { return i + 3 }
            i += 1
        }
        return n
    }

    private static func isNameStart(_ c: Character) -> Bool {
        c.isLetter && c.isASCII
    }

    private static func isNameChar(_ c: Character) -> Bool {
        (c.isLetter || c.isNumber) && c.isASCII || c == "-" || c == "_" || c == ":" || c == "."
    }

    private static func isSpace(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}"
    }
}
