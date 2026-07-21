#if canImport(AppKit) || canImport(UIKit)
import Foundation
import QuoinCore

/// Derives VoiceOver announcements and heading levels from block structure.
///
/// Pure and platform-free (no AppKit/UIKit): the mapping from a `BlockKind`
/// to a spoken label is unit-tested directly (`BlockAccessibilityTests`), and
/// the renderer consumes it to name the document's structure for assistive
/// technologies. `AttributedRenderer.render(block:)` stamps every block's
/// announcement onto its rendered range (`headingLevel` for headings,
/// `blockAccessibilityLabel` for the rest); `QuoinTextView` then vends those
/// as the Headings and Landmarks VoiceOver rotors. So there is ONE source of
/// truth for how a block announces itself — the heading rotor labels, the
/// landmark labels, and the attachment fallbacks all route through here.
///
/// Scope (accessibility structure, #10): this is the *bounded* subset — a
/// concise "what is this region" sentence per block kind (surfaced through the
/// block-level Landmarks rotor) plus heading-level extraction. Rich
/// per-*element* navigation (stepping individual tables, links, tasks as rotor
/// targets), container grouping, and alternate actions are deferred; see
/// `docs/reference/architecture.md`.
public enum BlockAccessibility {

    /// The heading level a block announces at (1–6), or nil for non-headings.
    public static func headingLevel(for kind: BlockKind) -> Int? {
        if case .heading(let level, _, _) = kind { return level }
        return nil
    }

    /// A concise spoken announcement naming the block's kind (and, for
    /// structured blocks, its shape) so a VoiceOver listener learns WHAT a
    /// region is without visually scanning it.
    ///
    /// Returns nil for kinds that read fine as their own text (a paragraph)
    /// or have no visible projection at all (review endmatter) — the
    /// listener hears nothing extra rather than a redundant "paragraph".
    public static func announcement(for kind: BlockKind) -> String? {
        switch kind {
        case .heading(let level, let inlines, _):
            return headingAnnouncement(level: level, title: plainText(inlines))
        case .paragraph:
            return nil
        case .codeBlock(let language, let code):
            let head: String
            if let language, !language.trimmingCharacters(in: .whitespaces).isEmpty {
                head = "Code block, \(language)"
            } else {
                head = "Code block"
            }
            return "\(head), \(pluralized(lineCount(code), "line"))"
        case .diagram:
            return "Diagram"
        case .mathBlock:
            return "Equation"
        case .table(let header, let rows, _):
            return "Table, \(pluralized(header.count, "column")), \(pluralized(rows.count, "row"))"
        case .list(let items, let ordered, _):
            return "\(ordered ? "Ordered" : "Bulleted") list, \(pluralized(items.count, "item"))"
        case .blockQuote:
            return "Block quote"
        case .callout(let calloutKind, _):
            return "\(calloutKind.rawValue.capitalized) callout"
        case .frontMatter:
            return "Front matter"
        case .reviewEndmatter:
            return nil
        case .tableOfContents:
            return "Table of contents"
        case .thematicBreak:
            return "Separator"
        case .htmlBlock:
            return "HTML block"
        }
    }

    /// The label a heading announces with, level first so a listener orients
    /// in the outline before hearing the title. Shared by `announcement` and
    /// the heading rotor so both read identically.
    public static func headingAnnouncement(level: Int, title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Heading level \(level)" : "Heading level \(level), \(trimmed)"
    }

    // MARK: - Attachment labels

    /// VoiceOver label for a display-equation attachment: the engine's
    /// spoken-math description, role-prefixed. Falls back to the bare role
    /// when the equation has no spoken form (an unsupported command).
    public static func equationLabel(spokenDescription: String?) -> String {
        detailLabel(role: "Equation", detail: spokenDescription)
    }

    /// VoiceOver label for a diagram attachment: the engine's narration
    /// (which already leads with the diagram type), or the bare role when
    /// the source doesn't parse.
    public static func diagramLabel(narration: String?) -> String {
        if let narration, !narration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return narration
        }
        return "Diagram"
    }

    private static func detailLabel(role: String, detail: String?) -> String {
        guard let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return role
        }
        return "\(role), \(detail)"
    }

    // MARK: - Helpers

    private static func plainText(_ inlines: [Inline]) -> String {
        inlines.map(\.plainText).joined()
    }

    /// Lines a code payload spans. cmark keeps a single trailing newline on
    /// fenced code; count the content lines, not the terminator, and never
    /// report zero for a non-empty block.
    private static func lineCount(_ code: String) -> Int {
        if code.isEmpty { return 0 }
        let normalized = code.replacingOccurrences(of: "\r\n", with: "\n")
        var body = Substring(normalized)
        if body.hasSuffix("\n") { body = body.dropLast() }
        if body.isEmpty { return 1 }
        return body.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Regular English pluralization for the counted nouns this file uses
    /// (line/column/row/item — all take a bare "-s"). A dedicated helper so
    /// "1 column" never reads "1 columns".
    private static func pluralized(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
#endif
