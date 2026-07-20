import Foundation

/// The pure, platform-free rules behind Quoin's onboarding and Help surfaces
/// (#13): which curated documents ship in the app bundle, which of them are
/// offered as first-run sample content, and — given what a folder already
/// holds — whether to offer the seed and exactly which files to place.
///
/// The curated MARKDOWN itself lives in bundled resource files under
/// `App/macOS/Resources/` (never string literals in code), so writers can edit
/// the teaching content without touching Swift and the docs stay real,
/// round-trippable markdown. This seam owns only the DECISIONS about those
/// files, so they are unit-testable on Linux CI without AppKit, a live
/// `Bundle`, or the filesystem — the `LibraryModel` wrapper in the app shell is
/// a thin adapter that copies the chosen resources into the library.
///
/// Everything here is local-only by construction: it names bundled files and
/// filters against on-disk names. It never reaches the network, an account, or
/// any remote content.
public enum LibrarySeeding {

    /// One curated document shipped in the app bundle.
    public struct BundledDocument: Equatable, Sendable, Identifiable {
        /// Bundle resource base name (no extension) — the `.md` file under
        /// `App/macOS/Resources/`.
        public let resource: String
        /// On-disk file name (INCLUDING the `.md` extension) the document is
        /// written as when materialized into a library.
        public let filename: String
        /// Label for the Help-menu entry that opens this document.
        public let menuTitle: String
        /// One-line description of what the document teaches (for docs/AX).
        public let blurb: String

        public var id: String { resource }

        public init(resource: String, filename: String, menuTitle: String, blurb: String) {
            self.resource = resource
            self.filename = filename
            self.menuTitle = menuTitle
            self.blurb = blurb
        }
    }

    // MARK: - The curated set

    /// A short welcome note that teaches by being edited — the first document
    /// a brand-new user sees.
    public static let welcome = BundledDocument(
        resource: "WelcomeToQuoin",
        filename: "Welcome to Quoin.md",
        menuTitle: "Welcome to Quoin",
        blurb: "A short, editable tour of the editor.")

    /// The full Markdown reference: every block type Quoin renders, live.
    public static let markdownGuide = BundledDocument(
        resource: "MarkdownGuide",
        filename: "Markdown Guide.md",
        menuTitle: "Markdown Guide",
        blurb: "Every Markdown element Quoin renders, with live examples.")

    /// Quoin-specific extensions: review marks, front matter, math/diagram
    /// fences, highlights, HTML comments.
    public static let extensions = BundledDocument(
        resource: "QuoinExtensions",
        filename: "Quoin Extensions.md",
        menuTitle: "Quoin Extensions",
        blurb: "Review marks, front matter, and math/diagram fences.")

    /// The keyboard cheat sheet — every shortcut in one table.
    public static let shortcuts = BundledDocument(
        resource: "KeyboardShortcuts",
        filename: "Keyboard Shortcuts.md",
        menuTitle: "Keyboard Shortcuts",
        blurb: "Every keyboard shortcut, grouped by task.")

    /// Privacy and local-only behavior — where files live and what never
    /// leaves the Mac.
    public static let privacy = BundledDocument(
        resource: "PrivacyAndFiles",
        filename: "Privacy & Your Files.md",
        menuTitle: "Privacy & Your Files",
        blurb: "Local-only, plain-file, no-account behavior.")

    /// Export behavior — Markdown, HTML, PDF, print.
    public static let export = BundledDocument(
        resource: "ExportGuide",
        filename: "Exporting Documents.md",
        menuTitle: "Exporting Documents",
        blurb: "How Export and Print work, and what you get.")

    /// The full list of bundled documents reachable from the Help menu, in
    /// menu order. Every entry MUST have a matching resource file in the app
    /// bundle (`GuideConformanceTests` pins this).
    public static let helpSet: [BundledDocument] = [
        welcome, markdownGuide, extensions, shortcuts, privacy, export,
    ]

    /// The curated set offered as first-run sample content: a small, coherent
    /// pair — the welcome note plus the Markdown guide — dropped into the
    /// chosen library so the first screen is a real rendered document. Kept
    /// deliberately small; the rest of `helpSet` is reachable on demand from
    /// the Help menu.
    public static let sampleSet: [BundledDocument] = [welcome, markdownGuide]

    // MARK: - Decisions

    /// Whether to OFFER the first-run sample seed for a freshly chosen library.
    ///
    /// The offer appears only when the folder holds NONE of the sample
    /// documents yet — so a folder already seeded (or one a returning user
    /// declined and later re-declined by deleting) is never nagged, and a real
    /// notes folder that happens to share one sample's name is treated as
    /// already seeded rather than offered a colliding copy.
    public static func shouldOfferSeed(
        existingFileNames: Set<String>,
        from set: [BundledDocument] = sampleSet
    ) -> Bool {
        !set.contains { existingFileNames.contains($0.filename) }
    }

    /// The documents to actually place when the user accepts the seed: the
    /// sample set MINUS any whose on-disk name is already taken. Never
    /// overwrites an existing file — a same-named document a user already has
    /// wins, and only the missing pieces are added.
    public static func documentsToPlace(
        existingFileNames: Set<String>,
        from set: [BundledDocument] = sampleSet
    ) -> [BundledDocument] {
        set.filter { !existingFileNames.contains($0.filename) }
    }
}
