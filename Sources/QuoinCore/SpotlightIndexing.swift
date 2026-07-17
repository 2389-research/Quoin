import Foundation

/// Platform-free logic for Core Spotlight indexing (#6): deriving the
/// searchable fields (title, headings, snippet, keywords, body text) from a
/// parsed `QuoinDocument`, and computing the STABLE identifier that routes a
/// tapped Spotlight result back through the existing `quoin://` deep-link /
/// open path.
///
/// The identifier is the document's **root-scoped absolute path**. Core
/// Spotlight's `CSSearchableIndex.default()` is a SINGLE app-wide index, but
/// each window owns its own `LibraryModel` and can hold a different root
/// (multi-folder windows, #61). A bare library-relative id (`Notes/Today.md`)
/// would therefore COLLIDE across libraries — two roots each containing
/// `Notes/Today.md` would fight over one index slot (overwriting each other's
/// title/snippet, deleting each other's items, and opening the wrong file on
/// tap). The absolute path is unique across libraries (a path lives under
/// exactly one root), so every window's items are naturally namespaced.
///
/// The id still round-trips through the SAME `QuoinURLScheme` confinement
/// (``QuoinURLScheme/resolvedPath(forRawPath:relativeTo:)``) every other open
/// goes through: no parallel open path, and no way to escape the granted
/// library root. Because it is absolute, a tapped item routes to the library
/// that OWNS the document (the tap link is `confinedToContainingRoot`), never
/// to a same-named file in whichever window is key. It is a per-device index
/// value that never leaves the machine, so it need not be machine-portable the
/// way the #36 Handoff link (relative) must be.
///
/// ALL device/framework glue (CSSearchableIndex, CSSearchableItemAttributeSet)
/// lives in the macOS app behind `canImport(CoreSpotlight)`. Nothing here
/// imports CoreSpotlight, so it builds and is exhaustively testable on Linux.
///
/// Privacy: the app indexes into Quoin's PRIVATE, on-device Core Spotlight
/// index (`CSSearchableIndex.default()`). Nothing produced here is uploaded or
/// marked for public/server indexing; the derived text never leaves the device.
public enum SpotlightIndexing {

    /// The Core Spotlight domain that groups every Quoin document item, so the
    /// app can reconcile or wipe the whole set in one call.
    public static let domainIdentifier = "ai.2389.Quoin.documents"

    /// Default snippet length, in extended grapheme clusters.
    public static let defaultSnippetLimit = 300

    /// Default cap on the full-text body handed to Spotlight, in grapheme
    /// clusters — a guard against indexing a pathologically large document.
    public static let defaultTextContentLimit = 100_000

    /// Device-independent snapshot of one indexed document: everything the
    /// macOS glue needs to fill a `CSSearchableItemAttributeSet`, and nothing
    /// platform-specific.
    public struct IndexedDocument: Equatable, Sendable {
        /// Stable, root-scoped identifier == the document's absolute path (e.g.
        /// `/Work/Notes/Today.md`). Unique across libraries so the app-wide
        /// index never collides; see the type doc.
        public let identifier: String
        /// Display title: front-matter `title`, else the first heading, else
        /// the filename stem.
        public let title: String
        /// The library-relative path (e.g. `Notes/Today.md`), shown as the
        /// item's subtitle.
        public let relativePath: String
        /// Heading titles in document order.
        public let headings: [String]
        /// Front-matter scalar values / tags (deduped), for keyword search.
        public let keywords: [String]
        /// A short, grapheme-safe prose snippet for the result description.
        public let snippet: String
        /// Fuller plain-text body for full-text matching.
        public let textContent: String

        public init(
            identifier: String,
            title: String,
            relativePath: String,
            headings: [String],
            keywords: [String],
            snippet: String,
            textContent: String
        ) {
            self.identifier = identifier
            self.title = title
            self.relativePath = relativePath
            self.headings = headings
            self.keywords = keywords
            self.snippet = snippet
            self.textContent = textContent
        }
    }

    // MARK: - Stable identifier (⇄ deep link)

    /// The stable, root-scoped identifier for a document at `documentPath`
    /// inside `rootPath` — its normalized ABSOLUTE path. `nil` when the document
    /// is not strictly contained within the root (nothing outside a granted
    /// library is indexable, and the root folder itself is not a document).
    /// Pure: no I/O.
    ///
    /// Absolute (not relative) so it is unique across libraries: the app-wide
    /// `CSSearchableIndex.default()` holds items from every window's root, and a
    /// bare relative id would collide when two roots share a relative path (see
    /// the type doc). Containment is validated by the SAME check the deep link
    /// uses (``QuoinURLScheme/deepLink(forDocumentPath:relativeTo:)`` — refuses
    /// the root itself, out-of-root paths, and NUL bytes), and the id round-
    /// trips back through ``documentPath(forIdentifier:relativeTo:)``.
    public static func identifier(forDocumentPath documentPath: String, relativeTo rootPath: String) -> String? {
        // Reuse the deep link purely as the containment/validity gate; the id
        // itself is the absolute path so it stays globally unique.
        guard QuoinURLScheme.deepLink(forDocumentPath: documentPath, relativeTo: rootPath) != nil
        else { return nil }
        return QuoinURLScheme.normalize(documentPath)
    }

    /// The library-relative path for a document at `documentPath` inside
    /// `rootPath` (e.g. `Notes/Today.md`) — the display subtitle, and the
    /// exact `path` a portable `quoin://open` deep link carries. `nil` under the
    /// same containment rules as ``identifier(forDocumentPath:relativeTo:)``.
    /// Pure: no I/O.
    public static func relativePath(forDocumentPath documentPath: String, relativeTo rootPath: String) -> String? {
        guard let link = QuoinURLScheme.deepLink(forDocumentPath: documentPath, relativeTo: rootPath),
              let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
              !path.isEmpty
        else { return nil }
        return path
    }

    /// Resolve a stable identifier back to an absolute path inside `rootPath`,
    /// through the EXACT lexical confinement `quoin://` links use. `nil` for any
    /// identifier that escapes the root. Pure: no I/O.
    public static func documentPath(forIdentifier identifier: String, relativeTo rootPath: String) -> String? {
        QuoinURLScheme.resolvedPath(forRawPath: identifier, relativeTo: rootPath)
    }

    // MARK: - Attribute derivation

    /// Build the full indexed snapshot for a parsed document. `identifier` is
    /// the root-scoped absolute id (uniqueness key); `relativePath` is the
    /// display subtitle.
    public static func indexedDocument(
        for document: QuoinDocument,
        identifier: String,
        relativePath: String,
        filenameStem: String,
        snippetLimit: Int = defaultSnippetLimit,
        textContentLimit: Int = defaultTextContentLimit
    ) -> IndexedDocument {
        let body = bodyText(for: document)
        return IndexedDocument(
            identifier: identifier,
            title: title(for: document, filenameStem: filenameStem),
            relativePath: relativePath,
            headings: headings(for: document),
            keywords: keywords(for: document),
            snippet: truncate(body, limit: snippetLimit),
            textContent: truncate(body, limit: textContentLimit)
        )
    }

    /// Display title: the front-matter `title` field if present and non-empty,
    /// else the first heading in the outline, else the filename stem. The
    /// filename is the last resort so an untitled document is still findable by
    /// its file name.
    public static func title(for document: QuoinDocument, filenameStem: String) -> String {
        if let fromFrontMatter = frontMatterTitle(in: document.source) {
            return fromFrontMatter
        }
        for heading in document.outline {
            let trimmed = heading.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return filenameStem
    }

    /// Heading titles in document order, blank ones dropped.
    public static func headings(for document: QuoinDocument) -> [String] {
        document.outline
            .map { $0.title.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Front-matter values as search keywords: each scalar field's value, and
    /// each token of a complex (array / block-list) field, deduped case-
    /// insensitively while preserving first-seen spelling and order.
    public static func keywords(for document: QuoinDocument) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let trimSet = CharacterSet(charactersIn: " \t\"'-[]")
        func add(_ raw: String) {
            let token = raw.trimmingCharacters(in: trimSet)
            guard !token.isEmpty else { return }
            if seen.insert(token.lowercased()).inserted { result.append(token) }
        }
        for field in FrontMatterEditing.fields(in: document.source) {
            if !field.value.isEmpty {
                add(field.value)
            } else {
                // Complex field (array / flow collection / block list): split
                // its raw preview into tokens so `tags: [a, b]` and a `- a`
                // block list both become individual keywords.
                for piece in field.rawPreview.split(whereSeparator: {
                    $0 == "," || $0 == "\n" || $0 == "[" || $0 == "]"
                }) {
                    add(String(piece))
                }
            }
        }
        return result
    }

    /// A short prose snippet: the readable body text truncated on a grapheme
    /// boundary. Front matter, review endmatter, and the `[TOC]` marker are
    /// excluded (see ``bodyText(for:)``), so a snippet reads as content.
    public static func snippet(for document: QuoinDocument, limit: Int = defaultSnippetLimit) -> String {
        truncate(bodyText(for: document), limit: limit)
    }

    /// Readable body text: heading / paragraph / list / table / code / math
    /// text joined by single spaces, with front matter, review endmatter, raw
    /// HTML, and the `[TOC]` marker skipped. Whitespace runs are collapsed so
    /// the result is one clean line suitable for a Spotlight description or
    /// full-text field.
    public static func bodyText(for document: QuoinDocument) -> String {
        var parts: [String] = []
        collectText(document.blocks, into: &parts)
        let joined = parts.joined(separator: " ")
        // Collapse any run of whitespace/newlines to a single space.
        return joined.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .joined(separator: " ")
    }

    // MARK: - Stale-set reconciliation

    /// Identifiers that were indexed before but are absent from the current
    /// scan — the items to delete so a moved or removed file leaves no orphan.
    /// Sorted for deterministic behavior/tests.
    public static func staleIdentifiers(previouslyIndexed: Set<String>, current: Set<String>) -> [String] {
        previouslyIndexed.subtracting(current).sorted()
    }

    // MARK: - Persisted-root registry (bounded storage)

    /// LRU-touch a registry of persisted root paths and report which roots
    /// overflow a `limit`. The macOS glue persists one `[id: Date]` blob per
    /// distinct root ever opened; without a bound those blobs accumulate forever
    /// (a user opens many folders over a lifetime and none is pruned when a
    /// library is disconnected). This keeps at most `limit` roots' blobs:
    /// `rootPath` is moved to the most-recent end (deduped), and any roots that
    /// fall off the front are returned as `evicted` so the caller can delete
    /// their persisted maps. Pure: no I/O.
    ///
    /// Evicting a root's map only means the NEXT time that (least-recently-used)
    /// root is opened, its stale-set diff starts from empty — it re-indexes its
    /// current files fresh. Bounded, rare, and never a correctness hazard for an
    /// active library.
    public static func prunedRootRegistry(
        _ registry: [String], touching rootPath: String, limit: Int
    ) -> (registry: [String], evicted: [String]) {
        var next = registry.filter { $0 != rootPath }
        next.append(rootPath)
        guard limit > 0, next.count > limit else { return (next, []) }
        let overflow = next.count - limit
        let evicted = Array(next.prefix(overflow))
        next.removeFirst(overflow)
        return (next, evicted)
    }

    // MARK: - Internals

    /// Front-matter `title` field (case-insensitive key), trimmed, or nil.
    static func frontMatterTitle(in source: String) -> String? {
        for field in FrontMatterEditing.fields(in: source) where field.key.lowercased() == "title" {
            let raw = field.value.isEmpty ? field.rawPreview : field.value
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func collectText(_ blocks: [Block], into parts: inout [String]) {
        for block in blocks {
            switch block.kind {
            case .heading(_, let inlines, _):
                let text = inlines.plainText.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { parts.append(text) }
            case .paragraph(let inlines):
                let text = inlines.plainText.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { parts.append(text) }
            case .codeBlock(_, let code):
                if !code.isEmpty { parts.append(code) }
            case .mathBlock(let latex):
                if !latex.isEmpty { parts.append(latex) }
            case .table(let header, let rows, _):
                parts.append(header.map { $0.inlines.plainText }.joined(separator: " "))
                for row in rows {
                    parts.append(row.map { $0.inlines.plainText }.joined(separator: " "))
                }
            case .list(let items, _, _):
                for item in items { collectText(item.blocks, into: &parts) }
            case .blockQuote(let children), .callout(_, let children):
                collectText(children, into: &parts)
            case .mermaid, .frontMatter, .reviewEndmatter, .tableOfContents,
                 .thematicBreak, .htmlBlock:
                // Diagrams, metadata chips, the TOC marker, rules, and raw HTML
                // are not prose — indexing them would only add noise.
                break
            }
        }
    }

    /// Truncate to at most `limit` extended grapheme clusters, appending an
    /// ellipsis when it actually cut something. `String` indexing is grapheme-
    /// based, so this can NEVER split a grapheme — emoji, flags, and combining
    /// sequences stay whole.
    static func truncate(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[text.startIndex..<end]) + "…"
    }
}
