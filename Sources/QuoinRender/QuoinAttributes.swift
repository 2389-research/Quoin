#if canImport(AppKit) || canImport(UIKit)
import Foundation
import QuoinCore

/// Custom attributed-string keys that carry Quoin semantics through the
/// text system: block identity for scroll anchoring and diff patching,
/// and task-marker ranges for checkbox interaction.
public enum QuoinAttribute {
    /// Value: `String` — the `BlockID` description of the enclosing block.
    public static let blockID = NSAttributedString.Key("quoin.blockID")
    /// Value: `NSNumber` (byte offset) — start of a `[ ]`/`[x]` marker.
    public static let taskMarkerOffset = NSAttributedString.Key("quoin.taskMarkerOffset")
    /// Value: `String` — LaTeX source of a math run (styled-source fallback
    /// today; swapped for QuoinMath rendering in M2a).
    public static let mathSource = NSAttributedString.Key("quoin.mathSource")
    /// Value: `String` — mermaid source of a diagram block (styled-source
    /// fallback today; QuoinDiagram in M2b).
    public static let diagramSource = NSAttributedString.Key("quoin.diagramSource")
    /// Value: `NSNumber(true)` — marks the active block's editable source
    /// run in the editor (the syntax-reveal region).
    public static let editableSource = NSAttributedString.Key("quoin.editableSource")
    /// Value: `BlockDecoration` — block-level chrome (code canvas, callout
    /// box, quote rule…) drawn behind the text by the reader view.
    public static let blockDecoration = NSAttributedString.Key("quoin.blockDecoration")
    /// Value: `String` — text placed on the pasteboard when the run's
    /// copy link is clicked (code block header buttons).
    public static let copySource = NSAttributedString.Key("quoin.copySource")
    /// Value: `NSNumber(true)` — an embed block (code, math, mermaid,
    /// table) that flips to editable source on double-click, not on a
    /// single click (handoff: whole blocks flip on double-click).
    public static let embedBlock = NSAttributedString.Key("quoin.embedBlock")
    /// Value: `NSNumber` (Int) — on an embed block's rendered body run, the
    /// UTF-16 offset (relative to the block's source start) that the run's
    /// first character maps to. Lets a click land the caret at the matching
    /// source position when the block flips to editable source.
    public static let embedSourceStart = NSAttributedString.Key("quoin.embedSourceStart")
    /// Value: `NSNumber(true)` — marks a run awaiting async content (an image
    /// still decoding). Its fragment must not be cached, or the placeholder
    /// would be returned forever once the block's content-hash `BlockID`
    /// stabilizes; the renderer drops such fragments from the cache.
    public static let pendingContent = NSAttributedString.Key("quoin.pendingContent")
    /// A rendered CriticMarkup run's whole-mark SOURCE byte range, boxed as
    /// NSValue(range:) — accept/reject reads it back at the click point and
    /// re-verifies against the CURRENT source before splicing (suggestions
    /// design, S2).
    public static let suggestionRange = NSAttributedString.Key("quoin.suggestionRange")
    /// Value: `String` — the footnote id on a `[^id]` reference superscript.
    /// References and definitions live in the SAME attributed string
    /// (definitions are appended at the document tail), so both directions
    /// of the jump resolve by scanning for these tags — no separate index.
    public static let footnoteID = NSAttributedString.Key("quoin.footnoteID")
    /// Value: `String` — the footnote id spanning a rendered definition
    /// (marker, body, and ↩ backlink) in the appended footnote section.
    public static let footnoteDefinitionID = NSAttributedString.Key("quoin.footnoteDefinitionID")
    /// Value: `NSNumber` (Int 1–6) — tags a heading block's rendered range
    /// with its level. The reader view scans these runs to build the
    /// VoiceOver "Headings" custom rotor (accessibility structure, #10);
    /// it never affects layout.
    public static let headingLevel = NSAttributedString.Key("quoin.headingLevel")
}

/// Custom URL schemes used for in-document interaction via the text view's
/// standard link plumbing.
public enum QuoinLink {
    public static let taskScheme = "quoin-task"
    public static let anchorScheme = "quoin-anchor"
    public static let copyScheme = "quoin-copy"
    public static let editScheme = "quoin-edit"

    /// quoin-copy://block — clicking copies the run's `copySource` text.
    public static var copyURL: URL? { URL(string: "\(copyScheme)://block") }

    public static func isCopyURL(_ url: URL) -> Bool { url.scheme == copyScheme }

    /// quoin-edit://block — the `‹/› edit` chip: clicking opens the
    /// enclosing block's source for editing (`✓ done` on the open block
    /// closes it; same URL, the handler toggles on the active state).
    public static var editURL: URL? { URL(string: "\(editScheme)://block") }

    /// Opens the Review inspector (the endmatter chip's click target — the
    /// metadata's UI is the panel, never inline YAML editing).
    public static let reviewScheme = "quoin-review"
    public static var reviewURL: URL? { URL(string: "\(reviewScheme)://panel") }
    public static func isReviewURL(_ url: URL) -> Bool { url.scheme == reviewScheme }

    public static func isEditURL(_ url: URL) -> Bool { url.scheme == editScheme }

    /// quoin-task://toggle?offset=N — a clickable checkbox.
    public static func taskURL(markerOffset: Int) -> URL? {
        URL(string: "\(taskScheme)://toggle?offset=\(markerOffset)")
    }

    public static func markerOffset(from url: URL) -> Int? {
        guard url.scheme == taskScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "offset" })?.value
        else { return nil }
        return Int(value)
    }

    /// quoin-anchor://slug — an internal heading link.
    public static func anchorURL(slug: String) -> URL? {
        var components = URLComponents()
        components.scheme = anchorScheme
        components.host = slug
        return components.url
    }

    public static func anchorSlug(from url: URL) -> String? {
        guard url.scheme == anchorScheme else { return nil }
        return url.host
    }

    /// quoin-footnote://id — a `[^id]` reference; clicking jumps to the
    /// definition at the document tail (hover peeks it).
    public static let footnoteScheme = "quoin-footnote"
    /// quoin-footnote-back://id — the ↩ on a definition; clicking returns
    /// to the footnote's FIRST reference.
    public static let footnoteBackScheme = "quoin-footnote-back"

    public static func footnoteURL(id: String) -> URL? {
        footnoteIDURL(scheme: footnoteScheme, id: id)
    }

    public static func footnoteBackURL(id: String) -> URL? {
        footnoteIDURL(scheme: footnoteBackScheme, id: id)
    }

    public static func footnoteID(from url: URL) -> String? {
        guard url.scheme == footnoteScheme else { return nil }
        return url.host
    }

    public static func footnoteBackID(from url: URL) -> String? {
        guard url.scheme == footnoteBackScheme else { return nil }
        return url.host
    }

    private static func footnoteIDURL(scheme: String, id: String) -> URL? {
        // URLComponents rejects host-invalid characters (an id can hold
        // almost anything but whitespace/`]`); an unlinkable id degrades
        // to a plain superscript rather than a malformed URL.
        var components = URLComponents()
        components.scheme = scheme
        components.host = id
        return components.url
    }
}
#endif
