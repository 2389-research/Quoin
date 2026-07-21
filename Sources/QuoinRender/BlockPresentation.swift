import Foundation
import QuoinCore

/// How an EDITING block styles its revealed source (editor-modes design §2).
/// The flavor is a pure function of the block's kind — the caret plays no
/// part in it (the caret governs intra-block span reveal only, as a styler
/// parameter; see the view-owned caret contract in editor-modes-plan §1.3).
public enum EditingFlavor: Equatable, Sendable {
    /// Markdown-styled source; delimiters reveal only where the caret sits
    /// (paragraph, heading, list, quote, callout, table, thematic break).
    case prose
    /// Raw source, zero markdown styling (code, HTML, front matter).
    case verbatim
    /// Verbatim source PLUS a side-panel live artifact, last-good held
    /// while the source is unparseable (mermaid, math).
    case preview

    /// THE flavor table — the single place a block kind maps to a reveal
    /// style. Every reveal decision consults this, never the raw kind.
    public static func of(_ kind: BlockKind) -> EditingFlavor {
        switch kind {
        case .diagram, .mathBlock:
            return .preview
        case .codeBlock, .htmlBlock, .frontMatter, .reviewEndmatter:
            return .verbatim
        default:
            return .prose
        }
    }
}

/// One block's presentation state: the minimal, complete description of how
/// it is currently shown (editor-modes design §2). Exactly one block can be
/// `.editing` at a time — an invariant, not an accident.
public enum BlockPresentation: Equatable, Sendable {
    case rendered
    /// `chrome`: whether the open block draws the accent frame + ✓ done
    /// chip. Kind-derived (the embed set + front matter); prose reveals are
    /// deliberately chrome-free — the caret IS the mode there. (At render
    /// time a held preview panel can force chrome on a kind-flapped block;
    /// that disjunct is runtime retention state, not presentation.)
    case editing(flavor: EditingFlavor, chrome: Bool)
}

/// The whole document's presentation, computed ONCE per projection by
/// `presentation(for:activeBlockID:)` and read by every consumer — renderer,
/// styler pass, decoration layer, chrome. Compact by construction: one
/// active block means one non-`.rendered` entry.
public struct PresentationMap: Equatable, Sendable {
    public let activeBlockID: BlockID?
    private let activePresentation: BlockPresentation

    public subscript(id: BlockID) -> BlockPresentation {
        id == activeBlockID ? activePresentation : .rendered
    }

    /// The active block's presentation, or nil when nothing is editing.
    public var active: BlockPresentation? {
        activeBlockID != nil ? activePresentation : nil
    }

    /// The active block's flavor, or nil when nothing is editing.
    public var activeFlavor: EditingFlavor? {
        if case .editing(let flavor, _) = active { return flavor }
        return nil
    }

    init(activeBlockID: BlockID?, activePresentation: BlockPresentation) {
        self.activeBlockID = activeBlockID
        self.activePresentation = activePresentation
    }

    public static let allRendered = PresentationMap(
        activeBlockID: nil, activePresentation: .rendered)
}

/// THE single derivation of presentation from document + activation state.
/// Pure — callable from the model (projection changes) and the view (the
/// caret-move styler pass), guaranteed to agree.
public func presentation(
    for document: QuoinDocument,
    activeBlockID: BlockID?
) -> PresentationMap {
    guard let activeBlockID,
          let block = document.block(withID: activeBlockID) else {
        return .allRendered
    }
    return PresentationMap(
        activeBlockID: activeBlockID,
        activePresentation: .editing(
            flavor: .of(block.kind),
            chrome: presentationShowsChrome(block.kind)
        )
    )
}

/// Kinds whose OPEN state shows the editing frame + ✓ done chip: the embed
/// set (double-click / edit-chip activated) plus front matter. Mirrors the
/// original `isEmbedEditingKind`.
func presentationShowsChrome(_ kind: BlockKind) -> Bool {
    switch kind {
    case .codeBlock, .diagram, .mathBlock, .table, .htmlBlock,
         .tableOfContents, .frontMatter, .reviewEndmatter:
        return true
    default:
        return false
    }
}
