#if canImport(AppKit) || canImport(UIKit)
import Foundation
import ImageIO
import QuoinCore
import MermaidRender
import VinculumRender

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The old/new character ranges of a single incremental storage splice —
/// what changed between two renders, so the view can replace one span
/// instead of the whole attributed string.
public struct RenderSpliceHint: Sendable {
    public let oldRange: NSRange
    public let replacementRange: NSRange

    public init(oldRange: NSRange, replacementRange: NSRange) {
        self.oldRange = oldRange
        self.replacementRange = replacementRange
    }
}

public struct RenderStoragePatch {
    public let oldRange: NSRange
    public let replacement: NSAttributedString

    public init(oldRange: NSRange, replacement: NSAttributedString) {
        self.oldRange = oldRange
        self.replacement = replacement
    }
}

/// The reveal's styler configuration — ONE pure derivation
/// (`AttributedRenderer.revealStylerConfig(kind:slice:)`) shared by the
/// reveal render and the view-side caret-move restyle, so the two can never
/// drift (editor-modes plan, 3.3).
public struct RevealStylerConfig: Equatable, Sendable {
    /// False for verbatim/preview flavors: their markup IS the content.
    public let collapsesNonLiteralSpans: Bool
    /// True for INDENTED code only — no fences for the styler's per-match
    /// code guard to key on, so markdown styling is suppressed entirely.
    public let treatsSourceAsVerbatimCode: Bool

    public static let prose = RevealStylerConfig(
        collapsesNonLiteralSpans: true, treatsSourceAsVerbatimCode: false)
}

/// A rendered document: one attributed string for the whole document plus
/// the character range of every top-level block, which powers TOC jumps,
/// search navigation, and scroll anchoring across live reloads.
public struct RenderedDocument {
    public let attributed: NSAttributedString
    public let blockRanges: [BlockID: NSRange]
    /// When a block is active in the editor (syntax reveal), its literal
    /// source is rendered in place; this is that run's location and text.
    public let activeBlockID: BlockID?
    public let activeEditableRange: NSRange?
    public let activeSourceText: String?
    /// AppKit can use this to apply a bounded TextKit splice for simple
    /// active-block edits instead of scanning the whole rendered string.
    public let spliceHint: RenderSpliceHint?
    /// AppKit can apply these attributed replacements directly to live
    /// TextKit storage, in order. Used when the model has already proven a
    /// block-local change (an active-block edit, or an activate/deactivate
    /// flip) and rendering the whole document would be wasted work. Patches
    /// MUST be ordered by DESCENDING location so applying one never shifts
    /// the ranges of those still pending.
    public let storagePatches: [RenderStoragePatch]

    /// Convenience for the single-patch case (active-block edits).
    public var storagePatch: RenderStoragePatch? { storagePatches.first }

    /// Monotonic marker for "has this exact projection been applied to the
    /// live storage yet". `updateNSView` runs on every SwiftUI pass; without
    /// this, a patch-bearing projection would re-apply its patches on each
    /// pass and corrupt the storage (object identity of `attributed` can't
    /// distinguish patch generations — patches deliberately reuse it).
    public let revision: Int

    /// The storage length (UTF-16) the patches expect BEFORE application.
    /// Patches are diffs against a specific storage state; SwiftUI can
    /// coalesce rapid publishes so the view skips an intermediate patch
    /// revision — applying the next batch to that stale storage silently
    /// corrupts the projection (drifting caret mapping, keystrokes falling
    /// outside the editable range and being swallowed). On a length
    /// mismatch the view must ignore the patches and resync by splicing to
    /// `attributed`, which the model keeps authoritative.
    public let patchBaseLength: Int?

    /// The ACTIVE block's reveal styler configuration, derived ONCE
    /// (AttributedRenderer.revealStylerConfig) and carried here so the
    /// caret-move restyle consumes it VERBATIM instead of re-deriving it —
    /// two independent derivations synced by a single bool drifted for
    /// indented code (the T3 seam; editor-modes plan, 3.3). nil when no
    /// block is revealed.
    public let revealStyler: RevealStylerConfig?

    /// Compat: true when the revealed source styles fully verbatim (a
    /// default styler flipped mermaid source from mono-verbatim to
    /// markdown-styled proportional text on the first click).
    public var revealVerbatimCode: Bool {
        !(revealStyler ?? .prose).collapsesNonLiteralSpans
    }

    /// Side-by-side preview for the ACTIVE diagram/equation (ledger #6b):
    /// the artifact rendered as a floating panel beside the revealed
    /// source, refreshed every keystroke; `statusMessage` is non-nil while
    /// the mid-edit source doesn't parse (the last good render is shown).
    /// nil when no preview-anchored block is open.
    public let previewPanel: PreviewPanel?

    public struct PreviewPanel {
        public let image: PlatformImage
        public let statusMessage: String?
        public init(image: PlatformImage, statusMessage: String?) {
            self.image = image
            self.statusMessage = statusMessage
        }
    }

    public init(
        attributed: NSAttributedString,
        blockRanges: [BlockID: NSRange],
        activeBlockID: BlockID? = nil,
        activeEditableRange: NSRange? = nil,
        activeSourceText: String? = nil,
        spliceHint: RenderSpliceHint? = nil,
        storagePatch: RenderStoragePatch? = nil,
        storagePatches: [RenderStoragePatch] = [],
        revision: Int = 0,
        patchBaseLength: Int? = nil,
        previewPanel: PreviewPanel? = nil,
        revealStyler: RevealStylerConfig? = nil
    ) {
        self.attributed = attributed
        self.blockRanges = blockRanges
        self.activeBlockID = activeBlockID
        self.activeEditableRange = activeEditableRange
        self.activeSourceText = activeSourceText
        self.spliceHint = spliceHint
        self.storagePatches = storagePatch.map { [$0] } ?? storagePatches
        self.revision = revision
        self.patchBaseLength = patchBaseLength
        self.previewPanel = previewPanel
        self.revealStyler = revealStyler
    }

    public static let empty = RenderedDocument(attributed: NSAttributedString(), blockRanges: [:])
}

/// Renders a `QuoinDocument` into attributed text for TextKit 2.
///
/// Full native text rendering for all block types. Math typesets natively via
/// `MathImageRenderer` (Vinculum) and Mermaid via `MermaidRenderer`
/// (MermaidKit), each drawn as an attachment behind a theme seam, with a
/// styled source-card only as the failure fallback. Tables use measured tab
/// stops; the richer table attachment view is a later refinement.
public struct AttributedRenderer {

    public let theme: Theme
    /// Directory of the open document, for resolving relative image paths.
    public let baseURL: URL?
    /// Remote images are opt-in per document (local-only by default).
    public let loadsRemoteImages: Bool
    /// Fired (off-main) when an async-decoded image becomes available and
    /// the document should re-render to pick it up.
    public let onContentReady: (@Sendable () -> Void)?

    public init(
        theme: Theme = Theme(),
        baseURL: URL? = nil,
        loadsRemoteImages: Bool = false,
        onContentReady: (@Sendable () -> Void)? = nil
    ) {
        self.theme = theme
        self.baseURL = baseURL
        self.loadsRemoteImages = loadsRemoteImages
        self.onContentReady = onContentReady
    }

    /// Convenience for callers that don't keep a cache (exporters, tests).
    public func render(
        _ document: QuoinDocument,
        activeBlockID: BlockID? = nil,
        activeCaret: Int? = nil
    ) -> RenderedDocument {
        var throwaway: [BlockID: NSAttributedString] = [:]
        return render(document, activeBlockID: activeBlockID, activeCaret: activeCaret, cache: &throwaway)
    }

    /// A block's rendered fragment is a pure function of the block, so an
    /// unchanged block (same content-hashed `BlockID`) reuses its cached
    /// fragment instead of being rebuilt. This turns a keystroke's re-render
    /// from O(document) into O(changed blocks) — the whole-doc rebuild was the
    /// dominant per-keystroke cost. TOC is excluded because it reflects the
    /// document-wide outline, not just its own content.
    private func isCacheable(_ kind: BlockKind) -> Bool {
        if case .tableOfContents = kind { return false }
        return true
    }

    /// Convenience for hosts without preview retention (exporters, tests):
    /// a fresh reveal still renders its preview, but nothing is held across
    /// calls.
    public func render(
        _ document: QuoinDocument,
        activeBlockID: BlockID? = nil,
        activeCaret: Int? = nil,
        cache: inout [BlockID: NSAttributedString]
    ) -> RenderedDocument {
        var held: HeldPreview?
        return render(
            document, activeBlockID: activeBlockID, activeCaret: activeCaret,
            cache: &cache, heldPreview: &held)
    }

    public func render(
        _ document: QuoinDocument,
        activeBlockID: BlockID? = nil,
        activeCaret: Int? = nil,
        cache: inout [BlockID: NSAttributedString],
        heldPreview: inout HeldPreview?
    ) -> RenderedDocument {
        let output = NSMutableAttributedString()
        var blockRanges: [BlockID: NSRange] = [:]
        var activeEditableRange: NSRange?
        var activeSourceText: String?
        var revealConfig: RevealStylerConfig?
        var newCache: [BlockID: NSAttributedString] = [:]
        var tally = PhaseTrace.renderEnabled ? PhaseTrace.Tally() : nil

        for (index, block) in document.blocks.enumerated() {
            let start = output.length
            if block.id == activeBlockID,
               let slice = document.source.substring(in: block.range) {
                // Syntax reveal: the active block shows its literal source,
                // editable in place (led by a live preview for diagram/math
                // kinds). Only the caret's span reveals its delimiters
                // (handoff span-level rule). Never cached — its fragment
                // changes as the caret moves.
                let revealed = renderEditableSource(
                    slice, caretOffset: activeCaret, block: block,
                    document: document, heldPreview: &heldPreview)
                // editableRange.location is 0 by invariant (see
                // RevealedFragment): the editable source IS the fragment.
                activeEditableRange = NSRange(
                    location: start, length: revealed.editableRange.length)
                activeSourceText = slice
                revealConfig = Self.revealStylerConfig(kind: block.kind, slice: slice)
                output.append(revealed.attributed)
                tally?.add("reveal (active)", 0)
            } else if isCacheable(block.kind), let cached = cache[block.id] {
                newCache[block.id] = cached
                output.append(cached)
                tally?.add("cache hit", 0)
            } else {
                // A fragment awaiting async content (an image still decoding)
                // must NOT be cached: its BlockID is content-hash-stable, so a
                // cached placeholder would be returned forever — the decoded
                // image's re-render would hit the cache and never rebuild. The
                // fragment marks itself pending (QuoinAttribute.pendingContent).
                let built = PhaseTrace.timed { render(block: block, depth: 0, document: document) }
                let fragment = built.value
                tally?.add(Self.kindLabel(block.kind), built.ms)
                if isCacheable(block.kind), !fragmentHasPendingContent(fragment) {
                    newCache[block.id] = fragment
                }
                output.append(fragment)
            }
            if index < document.blocks.count - 1 {
                let nextKind = document.blocks[index + 1].kind
                output.append(separator(
                    after: block.kind, before: nextKind,
                    revealedSlice: block.id == activeBlockID ? activeSourceText : nil))
            }
            blockRanges[block.id] = NSRange(location: start, length: output.length - start)
        }

        // Footnotes gather at document end: 12/1.6 secondary, top hairline.
        if !document.footnotes.isEmpty {
            let base = output.length
            let (footnoteText, footnoteRanges) = renderFootnotes(document)
            output.append(footnoteText)
            for (id, range) in footnoteRanges {
                blockRanges[id] = NSRange(location: base + range.location, length: range.length)
            }
        }
        tally?.emit(activeBlockID == nil ? "render.cold (by block kind)" : "render (by block kind)")
        // Keep only fragments for blocks still present; drops removed blocks.
        cache = newCache
        return RenderedDocument(
            attributed: output,
            blockRanges: blockRanges,
            activeBlockID: activeBlockID,
            activeEditableRange: activeEditableRange,
            activeSourceText: activeSourceText,
            previewPanel: activeBlockID != nil ? Self.previewPanel(for: heldPreview) : nil,
            revealStyler: revealConfig
        )
    }

    /// Stable short label for a block kind, used only by the
    /// `QUOIN_RENDER_PHASE_LOG` per-kind render breakdown.
    static func kindLabel(_ kind: BlockKind) -> String {
        switch kind {
        case .paragraph: return "paragraph"
        case .heading: return "heading"
        case .codeBlock: return "codeBlock"
        case .mermaid: return "mermaid"
        case .mathBlock: return "mathBlock"
        case .table: return "table"
        case .list: return "list"
        case .blockQuote: return "blockQuote"
        case .callout: return "callout"
        case .htmlBlock: return "htmlBlock"
        case .frontMatter: return "frontMatter"
        case .reviewEndmatter: return "reviewEndmatter"
        case .thematicBreak: return "thematicBreak"
        case .tableOfContents: return "tableOfContents"
        }
    }

    /// A revealed block's projection: the full fragment plus the range of
    /// the 1:1 editable source WITHIN it. INVARIANT (since the mermaid/math
    /// preview moved out of the text flow into the side panel):
    /// `editableRange.location` is ALWAYS 0 — the editable source starts at
    /// the fragment start; only the length is meaningful (it excludes any
    /// trailing separator). The old lead-with-inline-preview offset case is
    /// dead (editor-modes review finding 1; deleted in plan 3.4).
    public struct RevealedFragment {
        public let attributed: NSAttributedString
        public let editableRange: NSRange
    }

    /// The held last-good preview for the CURRENT editing session
    /// (preview-anchored reveal): while the open diagram/equation's source
    /// is mid-edit and unparseable, the previous successful render stays
    /// up — never blank, never flashing. SESSION state, owned by the model
    /// (one entry suffices: one active block at a time; the model resets it
    /// when a different block activates so a stale artifact can never
    /// appear over foreign source) and threaded through render passes as
    /// an explicit inout — the renderer holds no hidden mutable state
    /// (editor-modes plan, 1.1).
    public struct HeldPreview {
        public var key: String
        public var sourceText: String
        public var sliceText: String
        public var image: PlatformImage
        public var paused: Bool
    }

    public func renderEditableSourceFragment(
        _ slice: String, caretOffset: Int? = nil,
        block: Block? = nil, document: QuoinDocument? = nil,
        heldPreview: inout HeldPreview?
    ) -> RevealedFragment {
        renderEditableSource(
            slice, caretOffset: caretOffset, block: block, document: document,
            heldPreview: &heldPreview)
    }

    /// Convenience for hosts without preview retention (exporters, tests).
    public func renderEditableSourceFragment(
        _ slice: String, caretOffset: Int? = nil,
        block: Block? = nil, document: QuoinDocument? = nil
    ) -> RevealedFragment {
        var held: HeldPreview?
        return renderEditableSource(
            slice, caretOffset: caretOffset, block: block, document: document,
            heldPreview: &held)
    }

    /// Width reserved for the side-by-side preview panel (plus its gap):
    /// the revealed source's paragraphs take a matching tail indent.
    public static let previewPanelWidth: CGFloat = 320
    public static let previewPanelGap: CGFloat = 16

    /// The side-by-side panel payload for a held preview.
    public static func previewPanel(for held: HeldPreview?) -> RenderedDocument.PreviewPanel? {
        guard let held else { return nil }
        let noun = held.key == "math" ? "equation" : "diagram"
        return RenderedDocument.PreviewPanel(
            image: held.image,
            statusMessage: held.paused
                ? "⚠︎ \(noun) paused — showing the last good render" : nil
        )
    }

    /// True when `slice` is plausibly the SAME editing session as the held
    /// preview's slice: equal, or one contiguous edit apart, or mostly
    /// shared. Guards the flap-stick (ledger #6a) against leaking a held
    /// artifact onto an unrelated block when the renderer is used without
    /// the model's session resets (exporters, tests, sequential reveals).
    private static func heldPreviewApplies(_ held: HeldPreview?, toSlice slice: String) -> Bool {
        guard let held else { return false }
        let a = Array(slice.utf16), b = Array(held.sliceText.utf16)
        if a == b { return true }
        let shorter = min(a.count, b.count)
        let longer = max(a.count, b.count)
        guard longer > 0, shorter > 0 else { return false }
        var prefix = 0
        while prefix < shorter, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // One contiguous edit (typing, or a big selection replace), or
        // most of the text shared.
        return prefix + suffix >= shorter || Double(prefix + suffix) / Double(longer) >= 0.5
    }

    /// One block's READ fragment, exactly as the full render loop would
    /// produce it (blockID/embed tagging included) — so an activate/
    /// deactivate flip can patch a single block into live storage instead of
    /// re-rendering the document. `hasPendingContent` mirrors the cacheability
    /// rule: a fragment holding a still-decoding image must not be cached.
    public func renderReadFragment(
        _ block: Block, document: QuoinDocument
    ) -> (fragment: NSAttributedString, hasPendingContent: Bool) {
        let fragment = render(block: block, depth: 0, document: document)
        return (fragment, fragmentHasPendingContent(fragment))
    }

    /// Length of the separator the full render inserts between these two
    /// block kinds — deterministic from the kinds, which is what makes
    /// activation flips patchable (the flip never changes a block's kind,
    /// so the separator is untouched).
    public func separatorLength(after kind: BlockKind, before nextKind: BlockKind) -> Int {
        blockSeparator(after: kind, before: nextKind).length
    }

    /// THE single separator derivation (editor-modes plan, 3.1): every
    /// projection producer asks here for both the characters AND the clamp
    /// styling, so producers can never disagree by a line (the T1 drift
    /// class — three call sites used to recompute this independently).
    /// `revealedSlice` is the preceding block's source slice when that
    /// block is revealed (its trailing newline decides the clamp), nil when
    /// it renders normally.
    public func separator(
        after kind: BlockKind, before nextKind: BlockKind, revealedSlice: String?
    ) -> NSAttributedString {
        if let revealedSlice, Self.revealNeedsClampedSeparator(revealedSlice) {
            return clampedSeparator(after: kind, before: nextKind)
        }
        return blockSeparator(after: kind, before: nextKind)
    }

    /// Everything a host needs to apply a bounded ACTIVE-BLOCK edit (a
    /// keystroke in the revealed source) as one storage patch instead of a
    /// full re-render. Moved here from the app model (editor-modes plan,
    /// 3.2) so the equivalence corpus can prove the patch path against the
    /// full render headlessly.
    public struct ActiveBlockEditUpdate {
        public let storagePatch: RenderStoragePatch
        public let blockRanges: [BlockID: NSRange]
        public let activeEditableRange: NSRange
        public let activeSourceText: String
        /// The pre-edit active id (content-hashed ids change with content);
        /// the host evicts both ids from its fragment cache.
        public let oldActiveBlockID: BlockID
    }

    /// The per-keystroke fast path: re-renders JUST the active fragment and
    /// shifts every block range by the one delta. Returns nil whenever any
    /// validity condition fails — the caller falls back to the full render,
    /// which is always correct.
    public func activeBlockEditUpdate(
        oldDocument: QuoinDocument,
        oldRendered: RenderedDocument,
        oldActiveBlockID: BlockID?,
        newDocument: QuoinDocument,
        newActiveBlockID: BlockID?,
        caret: Int?,
        heldPreview: inout HeldPreview?
    ) -> ActiveBlockEditUpdate? {
        guard oldDocument.footnotes.isEmpty,
              newDocument.footnotes.isEmpty,
              oldDocument.blocks.count == newDocument.blocks.count,
              let oldActiveBlockID,
              let newActiveBlockID,
              let caret,
              let oldIndex = oldDocument.blocks.firstIndex(where: { $0.id == oldActiveBlockID }),
              let newIndex = newDocument.blocks.firstIndex(where: { $0.id == newActiveBlockID }),
              oldIndex == newIndex,
              oldRendered.activeEditableRange != nil,
              let oldBlockRange = oldRendered.blockRanges[oldActiveBlockID],
              let newSlice = newDocument.source.substring(in: newDocument.blocks[newIndex].range),
              isActiveBlockPatchable(oldDocument.blocks[oldIndex].kind),
              isActiveBlockPatchable(newDocument.blocks[newIndex].kind),
              // This patch replaces the fragment WITHOUT its separator, so
              // it is valid only when the separator the render loop WOULD
              // emit is identical before and after the edit — characters
              // AND styling. One derivation, one comparison: the
              // SeparatorPolicy output itself (plan 3.1). Any difference
              // falls back to the full render.
              separatorUnchangedAcrossEdit(
                  oldDocument: oldDocument, oldIndex: oldIndex,
                  newDocument: newDocument, newIndex: newIndex, newSlice: newSlice)
        else { return nil }

        let revealed = QuoinPerformanceTrace.measure(
            "render.activeBlockPatch.fragment",
            metadata: "block_utf8=\(newDocument.blocks[newIndex].range.length)"
        ) {
            renderEditableSourceFragment(
                newSlice, caretOffset: caret,
                block: newDocument.blocks[newIndex], document: newDocument,
                heldPreview: &heldPreview)
        }
        // The patch replaces the whole OLD fragment (block range minus its
        // trailing separator). The fragment IS the editable source (see
        // RevealedFragment's location-0 invariant); the mermaid/math live
        // preview lives in the SIDE PANEL, refreshed through heldPreview
        // above, not in the text flow.
        let sepLength = oldIndex < oldDocument.blocks.count - 1
            ? separatorLength(
                after: oldDocument.blocks[oldIndex].kind,
                before: oldDocument.blocks[oldIndex + 1].kind)
            : 0
        let oldFragmentLength = oldBlockRange.length - sepLength
        guard oldFragmentLength >= 0 else { return nil }
        let oldFragmentRange = NSRange(location: oldBlockRange.location, length: oldFragmentLength)
        let replacement = revealed.attributed
        let delta = replacement.length - oldFragmentLength

        var ranges: [BlockID: NSRange] = [:]
        for index in newDocument.blocks.indices {
            let newBlock = newDocument.blocks[index]
            let oldBlock = oldDocument.blocks[index]
            if index == newIndex {
                ranges[newBlock.id] = NSRange(
                    location: oldBlockRange.location,
                    length: oldBlockRange.length + delta
                )
            } else {
                guard oldBlock.id == newBlock.id,
                      let oldRange = oldRendered.blockRanges[oldBlock.id]
                else { return nil }
                let shift = index > newIndex ? delta : 0
                ranges[newBlock.id] = NSRange(
                    location: oldRange.location + shift,
                    length: oldRange.length
                )
            }
        }

        return ActiveBlockEditUpdate(
            storagePatch: RenderStoragePatch(oldRange: oldFragmentRange, replacement: replacement),
            blockRanges: ranges,
            // editableRange.location is 0 by invariant (RevealedFragment).
            activeEditableRange: NSRange(
                location: oldBlockRange.location,
                length: revealed.editableRange.length),
            activeSourceText: newSlice,
            oldActiveBlockID: oldActiveBlockID
        )
    }

    private func isActiveBlockPatchable(_ kind: BlockKind) -> Bool {
        switch kind {
        case .tableOfContents, .list, .blockQuote, .callout:
            return false
        default:
            return true
        }
    }

    /// True when the render loop would emit an IDENTICAL separator (bytes
    /// and styling) after the active block before and after this edit —
    /// the per-keystroke patch's validity condition, asked of the single
    /// SeparatorPolicy derivation.
    private func separatorUnchangedAcrossEdit(
        oldDocument: QuoinDocument, oldIndex: Int,
        newDocument: QuoinDocument, newIndex: Int, newSlice: String
    ) -> Bool {
        let oldIsLast = oldIndex == oldDocument.blocks.count - 1
        let newIsLast = newIndex == newDocument.blocks.count - 1
        if oldIsLast || newIsLast { return oldIsLast && newIsLast }
        let oldSlice = oldDocument.source.substring(in: oldDocument.blocks[oldIndex].range) ?? ""
        let oldSeparator = separator(
            after: oldDocument.blocks[oldIndex].kind,
            before: oldDocument.blocks[oldIndex + 1].kind,
            revealedSlice: oldSlice)
        let newSeparator = separator(
            after: newDocument.blocks[newIndex].kind,
            before: newDocument.blocks[newIndex + 1].kind,
            revealedSlice: newSlice)
        return oldSeparator.isEqual(to: newSeparator)
    }

    /// Everything a host needs to apply an activate/deactivate flip as
    /// bounded storage patches instead of a full re-render.
    public struct ActivationFlipUpdate {
        /// Ordered by DESCENDING location, disjoint.
        public let storagePatches: [RenderStoragePatch]
        public let blockRanges: [BlockID: NSRange]
        public let activeEditableRange: NSRange?
        public let activeSourceText: String?
        /// The deactivated block's fresh read fragment, safe to cache
        /// (nil when it holds still-decoding async content).
        public let cacheableReadFragment: (id: BlockID, fragment: NSAttributedString)?
    }

    /// Computes the storage patches for an activation flip (`oldID` closes,
    /// `newID` opens; either may be nil). A flip changes only the flipped
    /// blocks' PROJECTION — the document is untouched — so at most two
    /// fragments change and everything else shifts. Returns nil when the
    /// projection state doesn't line up; the caller then does a full
    /// re-render, which is always correct.
    /// Convenience for hosts without preview retention (tests).
    public func activationFlipUpdate(
        document: QuoinDocument,
        current: RenderedDocument,
        from oldID: BlockID?,
        to newID: BlockID?,
        caret: Int?
    ) -> ActivationFlipUpdate? {
        var held: HeldPreview?
        return activationFlipUpdate(
            document: document, current: current, from: oldID, to: newID,
            caret: caret, heldPreview: &held)
    }

    public func activationFlipUpdate(
        document: QuoinDocument,
        current: RenderedDocument,
        from oldID: BlockID?,
        to newID: BlockID?,
        caret: Int?,
        heldPreview: inout HeldPreview?
    ) -> ActivationFlipUpdate? {
        // Footnote-bearing documents append footnote ranges after the block
        // loop; their bookkeeping isn't worth replicating here.
        guard document.footnotes.isEmpty, oldID != newID else { return nil }

        var patches: [(location: Int, patch: RenderStoragePatch, blockID: BlockID, newLength: Int, oldLength: Int)] = []
        var cacheable: (id: BlockID, fragment: NSAttributedString)?
        var activeSourceText: String?

        // Deactivation: the old editable run flips back to its read fragment,
        // and its separator (clamped during the reveal) back to normal. The
        // patch spans fragment + separator so both projections stay
        // reproducible from either path.
        if let oldID {
            guard let editableRange = current.activeEditableRange,
                  current.activeBlockID == oldID,
                  let blockIndex = document.blocks.firstIndex(where: { $0.id == oldID }),
                  let oldBlockRange = current.blockRanges[oldID],
                  // The editable source sits INSIDE the block's fragment.
                  editableRange.location >= oldBlockRange.location,
                  NSMaxRange(editableRange) <= NSMaxRange(oldBlockRange)
            else { return nil }
            let block = document.blocks[blockIndex]
            let (fragment, pending) = renderReadFragment(block, document: document)
            if !pending { cacheable = (oldID, fragment) }
            let replacement = NSMutableAttributedString(attributedString: fragment)
            if blockIndex < document.blocks.count - 1 {
                replacement.append(separator(
                    after: block.kind, before: document.blocks[blockIndex + 1].kind,
                    revealedSlice: nil))
            }
            patches.append((
                location: oldBlockRange.location,
                patch: RenderStoragePatch(oldRange: oldBlockRange, replacement: replacement),
                blockID: oldID, newLength: replacement.length, oldLength: oldBlockRange.length
            ))
        }

        // Activation: the new block's read fragment flips to editable source.
        var newEditableRangeInFragment = NSRange(location: 0, length: 0)
        if let newID {
            guard let blockIndex = document.blocks.firstIndex(where: { $0.id == newID }),
                  let blockRange = current.blockRanges[newID],
                  let slice = document.source.substring(in: document.blocks[blockIndex].range)
            else { return nil }
            let block = document.blocks[blockIndex]
            // The patch spans fragment + separator: the separator's
            // CHARACTERS are constant (range bookkeeping depends on that),
            // but a revealed slice that ends with its own newline needs the
            // separator clamped to near-zero height or it lays out as a
            // phantom empty paragraph the reading projection never shows.
            let revealed = renderEditableSourceFragment(
                slice, caretOffset: caret, block: block, document: document,
                heldPreview: &heldPreview)
            let replacement = NSMutableAttributedString(attributedString: revealed.attributed)
            if blockIndex < document.blocks.count - 1 {
                let nextKind = document.blocks[blockIndex + 1].kind
                replacement.append(separator(
                    after: block.kind, before: nextKind, revealedSlice: slice))
            }
            patches.append((
                location: blockRange.location,
                patch: RenderStoragePatch(oldRange: blockRange, replacement: replacement),
                blockID: newID, newLength: replacement.length, oldLength: blockRange.length
            ))
            activeSourceText = slice
            newEditableRangeInFragment = revealed.editableRange
        }

        guard !patches.isEmpty else { return nil }
        patches.sort { $0.location > $1.location }
        if patches.count == 2, NSMaxRange(patches[1].patch.oldRange) > patches[0].patch.oldRange.location {
            return nil
        }

        // Shift every block range by the deltas of patches located before it.
        var ranges: [BlockID: NSRange] = [:]
        ranges.reserveCapacity(current.blockRanges.count)
        for (blockID, range) in current.blockRanges {
            var location = range.location
            var length = range.length
            for entry in patches {
                let delta = entry.newLength - entry.oldLength
                if entry.blockID == blockID {
                    length += delta
                } else if entry.location < range.location {
                    location += delta
                }
            }
            ranges[blockID] = NSRange(location: location, length: length)
        }
        var activeEditableRange: NSRange?
        if let newID, let newRange = ranges[newID] {
            // editableRange.location is 0 by invariant (see RevealedFragment).
            activeEditableRange = NSRange(
                location: newRange.location, length: newEditableRangeInFragment.length)
        }

        return ActivationFlipUpdate(
            storagePatches: patches.map(\.patch),
            blockRanges: ranges,
            activeEditableRange: activeEditableRange,
            activeSourceText: activeSourceText,
            cacheableReadFragment: cacheable
        )
    }

    /// The inter-block separator. Boxed blocks (callouts, code, tables,
    /// diagrams, the front-matter chip) get extra air so two adjacent cards
    /// never touch borders; the separator sits outside either block's
    /// decoration range, so this widens the external gap without padding the
    /// box interiors. A heading hugs the card it introduces, so the extra air
    /// is added only after a card, or before a card not introduced by a heading.
    private func blockSeparator(after currentKind: BlockKind, before nextKind: BlockKind) -> NSAttributedString {
        let separator = NSMutableAttributedString(string: "\n", attributes: bodyAttributes())
        let currentIsHeading: Bool = { if case .heading = currentKind { return true } else { return false } }()
        if isCard(currentKind) || (isCard(nextKind) && !currentIsHeading) {
            // A genuine short empty paragraph guarantees the external gap.
            // Paragraph-spacing on the plain separator alone is unreliable —
            // that newline terminates the previous paragraph and inherits its
            // style — so append a dedicated low spacer line instead.
            var spacer = bodyAttributes()
            spacer[.font] = PlatformFont.systemFont(ofSize: 14)
            let spacerStyle = NSMutableParagraphStyle()
            spacerStyle.lineHeightMultiple = 1
            spacerStyle.paragraphSpacing = 0
            spacer[.paragraphStyle] = spacerStyle
            separator.append(NSAttributedString(string: "\n", attributes: spacer))
        }
        return separator
    }

    /// The footnote section appended at document end (12/1.6 secondary text
    /// under a top hairline). Returns the rendered run plus each footnote's
    /// first-block range *relative to the run's start*; the caller offsets
    /// them by the append position.
    private func renderFootnotes(_ document: QuoinDocument) -> (NSAttributedString, [BlockID: NSRange]) {
        let output = NSMutableAttributedString()
        var ranges: [BlockID: NSRange] = [:]
        output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
        output.append(renderThematicBreak())
        for footnote in document.footnotes {
            output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            let start = output.length
            var marker = bodyAttributes()
            marker[.font] = PlatformFont.systemFont(ofSize: 12, weight: .semibold)
            marker[.foregroundColor] = theme.accent
            output.append(NSAttributedString(string: "\(footnote.index). ", attributes: marker))
            for block in footnote.blocks {
                let body = NSMutableAttributedString(attributedString: render(block: block, depth: 0, document: document))
                let full = NSRange(location: 0, length: body.length)
                body.addAttribute(.font, value: PlatformFont.systemFont(ofSize: 12), range: full)
                body.addAttribute(.foregroundColor, value: theme.secondaryTextColor, range: full)
                output.append(body)
            }
            // ↩ returns to the footnote's FIRST reference (the coordinator
            // finds it by its `footnoteID` tag — same string, range lookup).
            if let backURL = QuoinLink.footnoteBackURL(id: footnote.id) {
                var back = bodyAttributes()
                back[.font] = PlatformFont.systemFont(ofSize: 12)
                back[.foregroundColor] = theme.accent
                back[.link] = backURL
                #if canImport(AppKit)
                back[.toolTip] = "Back to reference"
                #endif
                output.append(NSAttributedString(string: " ↩", attributes: back))
            }
            // The whole definition (marker, body, backlink) wears the id so
            // reference clicks and hover peeks resolve its exact range.
            output.addAttribute(
                QuoinAttribute.footnoteDefinitionID, value: footnote.id,
                range: NSRange(location: start, length: output.length - start))
            if let firstBlock = footnote.blocks.first {
                ranges[firstBlock.id] = NSRange(location: start, length: output.length - start)
            }
        }
        return (output, ranges)
    }

    /// The active block's raw markdown, styled for in-place editing:
    /// content approximates its rendered look, delimiters stay visible at
    /// 35% ink mono (syntax reveal), and the character mapping stays 1:1.
    ///
    /// Layout preservation is the point of in-place editing: the revealed
    /// source must keep the block's VERTICAL SKELETON — spacing between
    /// hard-break lines, list-item gaps and indents, a heading's air, the
    /// trailing paragraph gap — so entering and leaving edit mode doesn't
    /// reflow the page. For text-family blocks that means transplanting the
    /// READ fragment's paragraph styles onto the source line by line (the
    /// same text alignment that maps clicks to carets finds each source
    /// line's rendered anchor). Embed blocks (code, mermaid, math, table)
    /// keep tuned constants instead: re-rendering a diagram per keystroke
    /// just to copy its one paragraph style would defeat the render cache.
    private func renderEditableSource(
        _ slice: String, caretOffset: Int? = nil,
        block: Block? = nil, document: QuoinDocument? = nil,
        heldPreview: inout HeldPreview?
    ) -> RevealedFragment {
        // ONE derivation, shared with the view-side caret-move restyle via
        // RenderedDocument.revealStyler (editor-modes plan, 3.3).
        let config = Self.revealStylerConfig(kind: block?.kind, slice: slice)
        var styler = MarkdownSourceStyler(theme: theme)
        styler.collapsesNonLiteralSpans = config.collapsesNonLiteralSpans
        styler.treatsSourceAsVerbatimCode = config.treatsSourceAsVerbatimCode
        let styled = NSMutableAttributedString(
            attributedString: styler.style(slice, caretOffset: caretOffset))
        guard styled.length > 0 else {
            return RevealedFragment(attributed: styled, editableRange: NSRange(location: 0, length: 0))
        }

        if let block, let document {
            switch block.kind {
            case .paragraph, .heading, .list, .blockQuote, .callout, .thematicBreak, .table:
                let read = render(block: block, depth: 0, document: document)
                transplantParagraphStyles(from: read, onto: styled, source: slice)
                compressInteriorBlankLines(in: styled, caretOffset: caretOffset)
                clampTrailingNewlinePhantom(in: styled, caretOffset: caretOffset)
                return assembleRevealedFragment(source: styled, block: block, heldPreview: &heldPreview)
            default:
                break
            }
        }

        // Fallback (embed kinds, or no block context): mirror the code
        // canvas's line metrics and the body's trailing gap.
        applyFallbackMetrics(to: styled, kind: block?.kind)
        return assembleRevealedFragment(source: styled, block: block, heldPreview: &heldPreview)
    }

    /// Combines the styled source with its editing-mode chrome:
    ///
    /// - SIDE-BY-SIDE PREVIEW (mermaid/math, ledger #6b): the artifact
    ///   never enters the text flow — it renders as a floating panel the
    ///   view layer hosts beside the source (`activePreviewPanel()`),
    ///   refreshed here every keystroke; the source paragraphs take a
    ///   matching tail indent. Unparseable mid-edit source keeps the last
    ///   GOOD render with a status message IN the panel — no text-flow
    ///   height ever changes with validity, and the preview sticks even
    ///   when the half-edited source stops parsing as its own kind
    ///   (slice-lineage guarded).
    /// - EMBED editing chrome: accent frame + drawn ✓ done chip as a
    ///   decoration over the whole fragment — never a text run; the
    ///   source region stays 1:1 with the file, reported precisely by
    ///   `editableRange`. Prose reveal stays chrome-free (the caret IS
    ///   the mode there).
    private func assembleRevealedFragment(
        source styled: NSMutableAttributedString, block: Block?,
        heldPreview: inout HeldPreview?
    ) -> RevealedFragment {
        let panelShowing = Self.updatePreviewPanel(
            for: block?.kind, slice: styled.string, theme: theme, held: &heldPreview)
        if panelShowing {
            // Make room for the panel: source wraps left of it.
            mutateParagraphStyles(in: styled, range: NSRange(location: 0, length: styled.length)) { style, _ in
                style.tailIndent = -(Self.previewPanelWidth + Self.previewPanelGap)
            }
        }
        let editableRange = NSRange(location: 0, length: styled.length)
        if let block, presentationShowsChrome(block.kind) || panelShowing {
            styled.addAttribute(
                QuoinAttribute.blockDecoration,
                value: BlockDecoration(kind: .editingFrame(accent: theme.accent)),
                range: NSRange(location: 0, length: styled.length)
            )
        }
        return RevealedFragment(attributed: styled, editableRange: editableRange)
    }

    /// Refreshes the held preview for the active reveal; returns whether a
    /// panel is showing for this fragment. Unchanged source reuses the
    /// held image (no re-render on caret moves); fresh source re-renders;
    /// unparseable source holds the last good image, paused; a kind flap
    /// holds it too when the slice is one edit away (lineage guard — a
    /// held artifact must never leak onto an unrelated block).
    private static func updatePreviewPanel(
        for kind: BlockKind?, slice: String, theme: Theme,
        held: inout HeldPreview?
    ) -> Bool {
        let key: String
        let sourceText: String
        switch kind {
        case .mermaid(let source):
            key = "mermaid"
            sourceText = source
        case .mathBlock(let latex):
            key = "math"
            sourceText = latex
        default:
            // Kind flap mid-edit: stick with the held panel (paused) while
            // the slice is recognizably the same editing session.
            if var flapped = held, heldPreviewApplies(held, toSlice: slice) {
                flapped.paused = true
                flapped.sliceText = slice
                held = flapped
                return true
            }
            return false
        }

        if let current = held, current.key == key, current.sourceText == sourceText,
           !current.paused {
            return true // unchanged source: reuse, no re-render
        }
        let fresh: NSAttributedString? = switch kind {
        case .mermaid(let source):
            MermaidRenderer.attachmentString(source: source, theme: theme.diagramTheme)
        case .mathBlock(let latex):
            MathImageRenderer.attachmentString(
                latex: latex, display: true, mathTheme: theme.mathTheme, baseSize: theme.bodySize)
        default:
            nil
        }
        if let fresh, let image = attachmentImage(in: fresh) {
            held = HeldPreview(
                key: key, sourceText: sourceText, sliceText: slice,
                image: image, paused: false)
            return true
        }
        if var paused = held, paused.key == key, heldPreviewApplies(held, toSlice: slice) {
            paused.paused = true
            paused.sliceText = slice
            held = paused
            return true
        }
        return false
    }

    private static func attachmentImage(in attributed: NSAttributedString) -> PlatformImage? {
        var image: PlatformImage?
        attributed.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: attributed.length)
        ) { value, _, stop in
            if let attachment = value as? NSTextAttachment, let found = attachment.image {
                image = found
                stop.pointee = true
            }
        }
        return image
    }

    /// A slice ending in a newline with NO separator after it (the
    /// document's last block) lays out a phantom empty final line from its
    /// own terminator. The phantom's metrics come from the terminator
    /// character's attributes, so clamping just that character collapses
    /// the phantom without touching the last content line. Harmless when a
    /// separator follows (the separator clamp handles that case).
    private func clampTrailingNewlinePhantom(
        in styled: NSMutableAttributedString, caretOffset: Int?
    ) {
        let text = styled.string as NSString
        guard text.length > 0,
              text.character(at: text.length - 1) == UInt16(UnicodeScalar("\n").value)
        else { return }
        if let caretOffset, caretOffset >= text.length { return }
        mutateParagraphStyles(in: styled, range: NSRange(location: text.length - 1, length: 1)) { style, _ in
            style.maximumLineHeight = 2
            style.minimumLineHeight = 0
            style.lineHeightMultiple = 1
            style.paragraphSpacing = 0
        }
    }

    /// Source blank lines (a loose list's item separators, the gaps inside
    /// a structured blockquote) render as FULL empty lines (~33pt each)
    /// where the reading projection shows a ~12pt paragraph gap — revealing
    /// a loose list grew it by a line per item (measured +194pt; the
    /// reported viewport churn). Compress each interior blank line to the
    /// paragraph-gap height — unless the caret is ON it, where it opens to
    /// full height for editing.
    private func compressInteriorBlankLines(
        in styled: NSMutableAttributedString, caretOffset: Int?
    ) {
        let text = styled.string as NSString
        var location = 0
        var previousNonBlankSpacing: CGFloat = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(line) }
            // Blank = just the terminator (or whitespace-only).
            let content = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard content.isEmpty, line.length > 0 else {
                if line.length > 0, styled.length > line.location {
                    previousNonBlankSpacing = (styled.attribute(
                        .paragraphStyle, at: line.location, effectiveRange: nil)
                        as? NSParagraphStyle)?.paragraphSpacing ?? 0
                }
                continue
            }
            if let caretOffset, caretOffset >= line.location, caretOffset <= NSMaxRange(line) { continue }
            // The blank row's height: when the PREVIOUS line's transplanted
            // style already carries the inter-item gap (loose lists), the
            // blank source line is the SAME gap in source form — collapsing
            // it to a sliver keeps the reveal's skeleton equal to reading
            // mode (live report: edit mode spread list items ~2x). Only a
            // gap-less predecessor keeps the full spacing-height row.
            let rowHeight = previousNonBlankSpacing > 0 ? 2 : theme.paragraphSpacing
            previousNonBlankSpacing = 0
            mutateParagraphStyles(in: styled, range: line) { style, _ in
                style.maximumLineHeight = rowHeight
                style.minimumLineHeight = 0
                style.lineHeightMultiple = 1
                style.paragraphSpacing = 0
                style.paragraphSpacingBefore = 0
            }
        }
    }

    /// True when an active block's revealed slice ends with its own newline
    /// — the block separator that FOLLOWS it then forms an empty paragraph
    /// of its own (a phantom ~40pt line the rendered projection never
    /// shows; list ranges end this way). The separator's characters must
    /// stay (all range bookkeeping assumes constant separators), so the
    /// separator is instead styled to near-zero height while the block is
    /// revealed.
    /// Public because patch producers must agree with the render loop on
    /// clamp state: the per-keystroke patch replaces the fragment WITHOUT its
    /// separator, so it must bail to a full render when an edit flips this —
    /// the separator's characters are constant, but its style isn't.
    public static func revealNeedsClampedSeparator(_ slice: String) -> Bool {
        slice.hasSuffix("\n")
    }

    /// THE reveal styler configuration for a block (editor-modes plan, 3.3):
    /// the flavor table decides span collapsing; INDENTED code (no fences
    /// for the styler's per-match code guard to key on — its content styled
    /// as markdown: bold text, LIVE links hijacking clicks; ledger #5)
    /// additionally suppresses all markdown styling. The kind is the truth:
    /// no fence in the slice → fully verbatim.
    public static func revealStylerConfig(kind: BlockKind?, slice: String) -> RevealStylerConfig {
        let flavor = kind.map(EditingFlavor.of) ?? .prose
        var treatsAsVerbatimCode = false
        if case .codeBlock = kind {
            let head = slice.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" })
            treatsAsVerbatimCode = !head.hasPrefix("```") && !head.hasPrefix("~~~")
        }
        return RevealStylerConfig(
            collapsesNonLiteralSpans: flavor == .prose,
            treatsSourceAsVerbatimCode: treatsAsVerbatimCode)
    }

    /// The block separator with ONLY ITS FIRST newline styled to near-zero
    /// height (same characters throughout). The revealed slice's own
    /// trailing newline turns the separator's first newline into a phantom
    /// empty paragraph the reading projection never shows — but a wide
    /// separator's REMAINING newlines are real spacing the reading
    /// projection DOES show, and clamping those made reveals shorter than
    /// their reading form (the ratchet caught thematic breaks at −80pt).
    func clampedSeparator(after kind: BlockKind, before nextKind: BlockKind) -> NSAttributedString {
        let separator = NSMutableAttributedString(
            attributedString: blockSeparator(after: kind, before: nextKind))
        guard separator.length > 0 else { return separator }
        mutateParagraphStyles(in: separator, range: NSRange(location: 0, length: 1)) { style, _ in
            style.maximumLineHeight = 2
            style.minimumLineHeight = 0
            style.paragraphSpacing = 0
            style.paragraphSpacingBefore = 0
            style.lineHeightMultiple = 1
        }
        return separator
    }

    /// Copies each rendered line's paragraph style onto the corresponding
    /// source line. Source lines with no rendered counterpart (fences,
    /// blank lines) inherit the style at their alignment boundary — their
    /// neighbor's.
    private func transplantParagraphStyles(
        from read: NSAttributedString,
        onto styled: NSMutableAttributedString,
        source: String
    ) {
        guard read.length > 0 else { return }
        let text = styled.string as NSString
        let full = NSRange(location: 0, length: text.length)
        var lineRanges: [NSRange] = []
        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            lineRanges.append(line)
            location = NSMaxRange(line)
            if line.length == 0 { break }
        }
        guard !lineRanges.isEmpty else { return }

        let anchors = EditMapping.renderedOffsets(
            forSourceOffsets: lineRanges.map(\.location),
            renderedText: read.string,
            sourceText: source
        )
        for (line, anchor) in zip(lineRanges, anchors) {
            let clampedAnchor = min(max(0, anchor), read.length - 1)
            guard let style = read.attribute(.paragraphStyle, at: clampedAnchor, effectiveRange: nil)
                as? NSParagraphStyle else { continue }
            let clamped = NSRange(location: line.location,
                                  length: min(line.length, full.length - line.location))
            guard clamped.length > 0 else { continue }
            styled.addAttribute(.paragraphStyle, value: style, range: clamped)
        }
    }

    /// Tuned constants for blocks whose read fragment shouldn't be rebuilt
    /// per keystroke (diagram/code canvases): code-canvas line height,
    /// tight interior, body trailing gap.
    private func applyFallbackMetrics(to styled: NSMutableAttributedString, kind: BlockKind?) {
        let text = styled.string as NSString
        let full = NSRange(location: 0, length: text.length)
        var lastParagraph = full
        text.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            if range.length > 0 { lastParagraph = range }
        }
        mutateParagraphStyles(in: styled, range: full) { style, _ in
            style.lineHeightMultiple = 1.6   // code canvas metric (12/1.6)
            style.paragraphSpacing = 0
        }
        mutateParagraphStyles(in: styled, range: lastParagraph) { style, _ in
            style.paragraphSpacing = theme.paragraphSpacing
        }
        // The canvas sets its body in the 12pt code face; the styler's
        // 14pt body face made every revealed code line ~2pt taller — ~60pt
        // across a long block. Only the base-font runs are retargeted (the
        // styler's own token/delimiter fonts stay).
        let baseFont = theme.bodyFont()
        styled.enumerateAttribute(.font, in: full) { value, range, _ in
            if let font = value as? PlatformFont, font == baseFont {
                styled.addAttribute(.font, value: theme.codeBlockFont(), range: range)
            }
        }
    }

    /// Mutates a copy of each effective paragraph style run within `range`.
    private func mutateParagraphStyles(
        in output: NSMutableAttributedString, range: NSRange,
        _ mutate: (NSMutableParagraphStyle, NSRange) -> Void
    ) {
        guard range.length > 0, range.location < output.length else { return }
        let clamped = NSRange(location: range.location,
                              length: min(range.length, output.length - range.location))
        output.enumerateAttribute(.paragraphStyle, in: clamped) { value, runRange, _ in
            let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            mutate(style, runRange)
            output.addAttribute(.paragraphStyle, value: style, range: runRange)
        }
    }

    // MARK: - Blocks

    /// Blocks drawn as a bordered/filled card, which need extra external air
    /// so two adjacent ones never share a border line.
    private func isCard(_ kind: BlockKind) -> Bool {
        switch kind {
        case .codeBlock, .mermaid, .table, .callout, .frontMatter, .htmlBlock:
            return true
        default:
            return false
        }
    }

    private func render(block: Block, depth: Int, document: QuoinDocument) -> NSAttributedString {
        let content: NSAttributedString
        switch block.kind {
        case .heading(let level, let inlines, _):
            content = renderHeading(level: level, inlines: inlines)
        case .paragraph(let inlines):
            content = renderInlines(inlines, base: bodyAttributes())
        case .codeBlock(let language, let code):
            content = renderCodeBlock(language: language, code: code)
        case .mermaid(let source):
            content = renderMermaidFallback(source: source)
        case .mathBlock(let latex):
            content = renderMathBlockFallback(latex: latex)
        case .table(let header, let rows, let alignments):
            content = renderTable(header: header, rows: rows, alignments: alignments)
        case .list(let items, let ordered, let start):
            content = renderList(items: items, ordered: ordered, start: start, depth: depth, document: document)
        case .blockQuote(let children):
            content = renderBlockQuote(children: children, depth: depth, document: document)
        case .callout(let kind, let children):
            content = renderCallout(kind: kind, children: children, depth: depth, document: document)
        case .frontMatter(let yaml):
            content = renderFrontMatterFields(yaml: yaml)
        case .reviewEndmatter:
            // The endmatter is NOT rendered at all: the Review panel (tab,
            // badge, cards, history) is its entire UI. v1 rendered the
            // condensed YAML (redlined 2026-07-14), v2 a summary chip
            // (redlined 2026-07-15: "shouldn't be literally rendered in
            // the document" — the caret could even land inside it). An
            // empty run keeps the block's range in the projection maps so
            // byte-lossless round-trip and block bookkeeping are untouched.
            content = NSAttributedString(string: "", attributes: bodyAttributes())
        case .tableOfContents:
            content = renderTOC(outline: document.outline)
        case .thematicBreak:
            content = renderThematicBreak()
        case .htmlBlock(let html):
            // An HTML COMMENT is metadata, not code: render it as a faint
            // literal line, never a code canvas (live redline 2026-07-15 —
            // `<!-- section_id: … -->` blocks dressed up as html snippets).
            let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->"),
               let closer = trimmed.range(of: "-->"),
               // Only a PURE comment block: a comment followed by markup
               // is real HTML and keeps the code canvas.
               closer.upperBound == trimmed.endIndex {
                var attributes = bodyAttributes()
                attributes[.font] = theme.inlineCodeFont()
                attributes[.foregroundColor] = theme.secondaryTextColor.withAlphaComponent(0.6)
                let style = paragraphStyle()
                style.paragraphSpacing = 4
                style.lineBreakMode = .byTruncatingTail
                attributes[.paragraphStyle] = style
                content = NSAttributedString(string: trimmed, attributes: attributes)
            } else {
                content = renderCodeBlock(language: "html", code: html)
            }
        }

        let tagged = NSMutableAttributedString(attributedString: content)
        let whole = NSRange(location: 0, length: tagged.length)
        tagged.addAttribute(QuoinAttribute.blockID, value: block.id.description, range: whole)
        // Embed blocks flip to source on double-click, not single click, so a
        // click to admire a rendered diagram/table doesn't turn it into code.
        // The TOC is one too: its rendered form is the full linked outline
        // but its source is one `[TOC]` line — a single click that activated
        // it collapsed hundreds of points of links around the caret (the
        // reported "click an item in the list and everything shifts wildly");
        // its links must navigate, not flip.
        switch block.kind {
        case .codeBlock, .mermaid, .mathBlock, .table, .htmlBlock, .tableOfContents:
            tagged.addAttribute(QuoinAttribute.embedBlock, value: NSNumber(value: true), range: whole)
        default:
            break
        }
        // Resolve the code body's caret-mapping marker to the real source
        // offset: the rendered body is 1:1 with the source content, which sits
        // after the opening fence line in the block's source slice. HTML
        // blocks render through the same code canvas and resolve too (their
        // body IS the slice, offset 0) — the unresolved -1 sentinel used to
        // leak into their caret hints, one character early.
        if isBodyTaggedKind(block.kind),
           let slice = document.source.substring(in: block.range) {
            let sliceNS = slice as NSString
            tagged.enumerateAttribute(QuoinAttribute.embedSourceStart, in: whole) { value, range, _ in
                guard (value as? NSNumber)?.intValue == -1 else { return }
                let bodyText = tagged.attributedSubstring(from: range).string
                let found = sliceNS.range(of: bodyText)
                if found.location != NSNotFound {
                    tagged.addAttribute(QuoinAttribute.embedSourceStart,
                                        value: NSNumber(value: found.location), range: range)
                } else {
                    tagged.removeAttribute(QuoinAttribute.embedSourceStart, range: range)
                }
            }
        }
        return tagged
    }

    /// Kinds whose rendered body carries the 1:1 `embedSourceStart` marker
    /// (they render through the code canvas).
    private func isBodyTaggedKind(_ kind: BlockKind) -> Bool {
        switch kind {
        case .codeBlock, .htmlBlock: return true
        default: return false
        }
    }

    private func renderHeading(level: Int, inlines: [Inline]) -> NSAttributedString {
        var attributes = bodyAttributes()
        attributes[.font] = theme.headingFont(level: level)
        // H1–H3 in full ink; H4–H6 at 55% per the element spec.
        attributes[.foregroundColor] = level <= 3 ? theme.ink : theme.secondaryTextColor
        let style = paragraphStyle()
        let spacing = theme.headingSpacing(level: level)
        style.lineHeightMultiple = theme.headingLineHeightMultiple(level: level)
        style.paragraphSpacingBefore = spacing.above
        style.paragraphSpacing = spacing.below
        attributes[.paragraphStyle] = style
        return renderInlines(inlines, base: attributes)
    }

    private func renderCodeBlock(language: String?, code: String) -> NSAttributedString {
        // Code canvas is #1E2430 in BOTH appearances (handoff rule). The
        // canvas itself is a block decoration drawn by the reader view; the
        // text carries a header row (language chip + copy button) and the
        // highlighted code, single-spaced.
        let output = NSMutableAttributedString()

        let headerStyle = paragraphStyle()
        headerStyle.alignment = .right
        headerStyle.paragraphSpacingBefore = 8
        headerStyle.paragraphSpacing = 2
        headerStyle.firstLineHeadIndent = 12
        headerStyle.headIndent = 12
        headerStyle.tailIndent = -12
        var chip = bodyAttributes()
        chip[.font] = theme.captionFont()
        chip[.foregroundColor] = PlatformColor.white.withAlphaComponent(0.45)
        chip[.paragraphStyle] = headerStyle
        if let language, !language.isEmpty {
            output.append(NSAttributedString(string: "\(language)    ", attributes: chip))
        }
        // `‹/›` promises source (which is the truth), never a pencil
        // (which promises direct manipulation) — embed-editing brief.
        var edit = chip
        if let url = QuoinLink.editURL {
            edit[.link] = url
        }
        #if canImport(AppKit)
        edit[.toolTip] = "Edit Source (⌘↩)" as NSString
        #endif
        output.append(NSAttributedString(string: "‹/› edit    ", attributes: edit))
        var copy = chip
        copy[QuoinAttribute.copySource] = code
        if let url = QuoinLink.copyURL {
            copy[.link] = url
        }
        #if canImport(AppKit)
        copy[.toolTip] = "Copy Code" as NSString
        #endif
        output.append(NSAttributedString(string: "⧉ copy\n", attributes: copy))

        var attributes = bodyAttributes()
        attributes[.font] = theme.codeBlockFont()
        attributes[.foregroundColor] = theme.codeText
        let style = paragraphStyle()
        style.lineHeightMultiple = 1.6
        style.firstLineHeadIndent = 12
        style.headIndent = 12
        style.tailIndent = -12
        // One visual block: code lines are paragraphs but must not inherit
        // the body's inter-paragraph gap.
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        attributes[.paragraphStyle] = style
        let body = NSMutableAttributedString(string: code, attributes: attributes)

        // Native syntax highlighting: six token colors per the design spec.
        // Character indices align with UTF-16 only for BMP text, so map each
        // character offset to its UTF-16 offset. Prefix sums make every token's
        // range O(1) instead of re-summing the string prefix per token.
        let chars = Array(code)
        var utf16Offsets = [Int](repeating: 0, count: chars.count + 1)
        for i in 0..<chars.count { utf16Offsets[i + 1] = utf16Offsets[i] + String(chars[i]).utf16.count }
        for token in SyntaxHighlighter.highlight(code: code, language: language) {
            let lower = token.range.lowerBound
            let upper = min(token.range.upperBound, chars.count)
            let nsRange = NSRange(location: utf16Offsets[lower], length: utf16Offsets[upper] - utf16Offsets[lower])
            guard nsRange.location + nsRange.length <= body.length else { continue }
            body.addAttribute(.foregroundColor, value: codeTokenColor(token.kind), range: nsRange)
        }

        // Bottom padding inside the canvas: the last code paragraph carries it.
        padLastLine(in: body, spacing: 8)
        // Marker: this run is the code body, 1:1 with the block's source
        // content. render(block:) resolves it to the real source offset so a
        // click can land the caret precisely when the block flips to source.
        body.addAttribute(QuoinAttribute.embedSourceStart, value: NSNumber(value: -1),
                          range: NSRange(location: 0, length: body.length))
        output.append(body)

        output.addAttribute(
            QuoinAttribute.blockDecoration,
            value: BlockDecoration(kind: .codeCanvas(fill: theme.codeSurface)),
            range: NSRange(location: 0, length: output.length)
        )
        return output
    }

    /// Front matter renders as a FIELD GRID — the #59 field grid (redlined
    /// 2026-07-15: the one-line "a · b · c" soup was unreadable). Key column
    /// at a fixed tab stop; values wrap aligned under themselves; nested YAML
    /// lines render as raw mono continuations. The trailing `‹/› edit`
    /// affordance keeps the reveal discoverable.
    private func renderFrontMatterFields(yaml: String) -> NSAttributedString {
        let keyColumn: CGFloat = 96
        let output = NSMutableAttributedString()

        func rowStyle() -> NSMutableParagraphStyle {
            let style = paragraphStyle()
            style.lineHeightMultiple = 1.25
            style.paragraphSpacing = 2
            style.firstLineHeadIndent = 8
            style.headIndent = keyColumn
            style.tailIndent = -8
            style.tabStops = [NSTextTab(textAlignment: .left, location: keyColumn)]
            style.lineBreakMode = .byWordWrapping
            return style
        }
        var keyAttributes = bodyAttributes()
        keyAttributes[.font] = PlatformFont.systemFont(ofSize: 10, weight: .semibold)
        keyAttributes[.foregroundColor] = theme.tertiaryTextColor
        keyAttributes[.kern] = 0.5
        var valueAttributes = bodyAttributes()
        valueAttributes[.font] = theme.captionFont()
        valueAttributes[.foregroundColor] = theme.secondaryTextColor
        var rawAttributes = valueAttributes
        rawAttributes[.font] = theme.inlineCodeFont()
        rawAttributes[.foregroundColor] = theme.tertiaryTextColor

        var first = true
        for rawLine in yaml.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if !first { output.append(NSAttributedString(string: "\n")) }
            first = false
            let style = rowStyle()
            let indented = line.hasPrefix(" ") || line.hasPrefix("\t")
            if !indented, let colon = trimmed.firstIndex(of: ":"),
               trimmed[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                let key = String(trimmed[..<colon]).uppercased()
                let value = String(trimmed[trimmed.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                var keyed = keyAttributes
                keyed[.paragraphStyle] = style
                output.append(NSAttributedString(string: key + "\t", attributes: keyed))
                var valued = valueAttributes
                valued[.paragraphStyle] = style
                output.append(NSAttributedString(string: value, attributes: valued))
            } else {
                // Nested/odd line: raw continuation in the value column.
                var raw = rawAttributes
                raw[.paragraphStyle] = style
                output.append(NSAttributedString(string: "\t" + trimmed, attributes: raw))
            }
        }
        if output.length == 0 {
            // Empty front matter: keep a single faint marker line.
            var attributes = rawAttributes
            attributes[.paragraphStyle] = rowStyle()
            output.append(NSAttributedString(string: "front matter", attributes: attributes))
        }

        // Air inside the chip: first row's top, last row's bottom.
        mutateParagraphStyles(in: output, range: NSRange(location: 0, length: 1)) { style, _ in
            style.paragraphSpacingBefore = 6
        }
        // Trailing `‹/› edit` on the last row, same grammar as everywhere.
        var edit = valueAttributes
        if let url = QuoinLink.editURL {
            edit[.link] = url
        }
        #if canImport(AppKit)
        edit[.toolTip] = "Edit Source (⌘↩)" as NSString
        #endif
        output.append(NSAttributedString(string: "   ·   ‹/› edit", attributes: edit))
        padLastLine(in: output, spacing: theme.paragraphSpacing)
        output.addAttribute(
            QuoinAttribute.blockDecoration,
            value: BlockDecoration(kind: .chip(fill: theme.inlineCodeFill)),
            range: NSRange(location: 0, length: output.length))
        return output
    }

    private func renderCallout(kind: CalloutKind, children: [Block], depth: Int, document: QuoinDocument) -> NSAttributedString {
        let semantic: PlatformColor
        let symbol: String
        switch kind {
        case .note: semantic = .systemBlue; symbol = "ℹ︎"
        case .tip: semantic = .systemGreen; symbol = "✓"
        case .important: semantic = .systemPurple; symbol = "❯"
        case .warning: semantic = .systemOrange; symbol = "⚠︎"
        case .caution, .danger: semantic = .systemRed; symbol = "✕"
        }

        let output = NSMutableAttributedString()
        var title = bodyAttributes()
        title[.font] = PlatformFont.systemFont(ofSize: 12.5, weight: .semibold)
        title[.foregroundColor] = semantic
        let titleStyle = paragraphStyle()
        titleStyle.paragraphSpacingBefore = 8
        titleStyle.paragraphSpacing = 4
        title[.paragraphStyle] = titleStyle
        output.append(NSAttributedString(string: "\(symbol) \(kind.title)\n", attributes: title))

        for (index, child) in children.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            }
            output.append(render(block: child, depth: depth + 1, document: document))
        }
        let full = NSRange(location: 0, length: output.length)
        // Nested cards (code, diagrams) keep their own decoration — the
        // callout box is applied around them, not over them (a blanket
        // add replaced the child's canvas with the box; ledger #1 family).
        var cardRanges: [NSRange] = []
        output.enumerateAttribute(QuoinAttribute.blockDecoration, in: full) { value, range, _ in
            if value != nil { cardRanges.append(range) }
        }
        output.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? paragraphStyle()
            style.firstLineHeadIndent += 12
            style.headIndent += 12
            style.tailIndent = -12
            output.addAttribute(.paragraphStyle, value: style, range: range)
        }
        for card in cardRanges {
            output.enumerateAttribute(QuoinAttribute.blockDecoration, in: card) { value, range, _ in
                guard let decoration = value as? BlockDecoration else { return }
                output.addAttribute(
                    QuoinAttribute.blockDecoration,
                    value: decoration.inset(by: 12),
                    range: range
                )
            }
        }
        // Bottom padding inside the box: the last paragraph carries it.
        padLastLine(in: output, spacing: 8)
        // Rounded 4% tint + 15% border in the semantic color, drawn as a
        // block decoration by the reader view — on the NON-card runs only.
        var cursor = 0
        for card in cardRanges.sorted(by: { $0.location < $1.location }) {
            if card.location > cursor {
                output.addAttribute(
                    QuoinAttribute.blockDecoration,
                    value: BlockDecoration(kind: .callout(color: semantic)),
                    range: NSRange(location: cursor, length: card.location - cursor)
                )
            }
            cursor = max(cursor, NSMaxRange(card))
        }
        if cursor < output.length {
            output.addAttribute(
                QuoinAttribute.blockDecoration,
                value: BlockDecoration(kind: .callout(color: semantic)),
                range: NSRange(location: cursor, length: output.length - cursor)
            )
        }
        return output
    }

    private func renderTOC(outline: [HeadingInfo]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, heading) in outline.enumerated() {
            var attributes = bodyAttributes()
            attributes[.foregroundColor] = theme.linkColor
            attributes[.link] = QuoinLink.anchorURL(slug: heading.slug) as Any
            let style = paragraphStyle()
            style.paragraphSpacing = 2
            style.firstLineHeadIndent = CGFloat(max(0, heading.level - 1)) * 16
            style.headIndent = style.firstLineHeadIndent
            attributes[.paragraphStyle] = style
            output.append(NSAttributedString(
                string: heading.title + (index < outline.count - 1 ? "\n" : ""),
                attributes: attributes
            ))
        }
        return output
    }

    /// VoiceOver labels for attachment-rendered embeds — a diagram or
    /// equation must never read as an unnamed image.
    private func labelAttachmentImages(in attributed: NSMutableAttributedString, description: String) {
        #if canImport(AppKit)
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            (value as? NSTextAttachment)?.image?.accessibilityDescription = description
        }
        #endif
    }

    /// The `‹/› edit` affordance for attachment embeds: a right-aligned
    /// caption line above the artifact (inside its frame), quiet at
    /// secondary ink — the visible invitation the brief calls for on
    /// blocks whose rendered form hides that they ARE markdown.
    private func editChipLine(spacingBefore: CGFloat, rightTabAt width: CGFloat? = nil) -> NSAttributedString {
        var attributes = bodyAttributes()
        attributes[.font] = theme.captionFont()
        attributes[.foregroundColor] = theme.secondaryTextColor
        if let url = QuoinLink.editURL {
            attributes[.link] = url
        }
        #if canImport(AppKit)
        attributes[.toolTip] = "Edit Source (⌘↩)" as NSString
        #endif
        let style = paragraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = 2
        let text: String
        if let width {
            // Right-aligned at the CONTENT's right edge (a table narrower
            // than the column), not the column margin.
            style.tabStops = [NSTextTab(textAlignment: .right, location: width, options: [:])]
            text = "\t‹/› edit\n"
        } else {
            style.alignment = .right
            style.firstLineHeadIndent = 8
            style.headIndent = 8
            style.tailIndent = -8
            text = "‹/› edit\n"
        }
        attributes[.paragraphStyle] = style
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func renderMermaidFallback(source: String) -> NSAttributedString {
        // Native rendering via MermaidKit; unparseable sources keep the
        // styled-source fallback.
        if let native = MermaidRenderer.attachmentString(source: source, theme: theme.diagramTheme) {
            let output = NSMutableAttributedString()
            output.append(editChipLine(spacingBefore: theme.paragraphSpacing))
            let attachment = NSMutableAttributedString(attributedString: native)
            // Scale an oversized diagram down to the content column so it sits
            // inside its frame instead of poking out the right edge.
            attachment.refitImageAttachmentsToContentWidth()
            labelAttachmentImages(in: attachment, description: "Mermaid diagram")
            let style = paragraphStyle()
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = theme.paragraphSpacing
            attachment.addAttribute(.paragraphStyle, value: style,
                                    range: NSRange(location: 0, length: attachment.length))
            output.append(attachment)
            output.addAttributes([
                QuoinAttribute.diagramSource: source,
                QuoinAttribute.blockDecoration: BlockDecoration(kind: .diagramFrame(color: theme.hairline)),
            ], range: NSRange(location: 0, length: output.length))
            return output
        }

        return renderSourceCard(
            language: "mermaid", code: source,
            sourceKey: QuoinAttribute.diagramSource, source: source,
            caption: "mermaid · this diagram type isn't natively rendered yet"
        )
    }

    private func renderMathBlockFallback(latex: String) -> NSAttributedString {
        // A definition-only block (`$$\newcommand{\R}{…}$$`) has no visible
        // output — show an unobtrusive chip naming the count instead of an
        // empty box. Definitions apply document-wide (collected at parse).
        if MathMacros.isDefinitionOnly(latex, table: MathMacroTable()) {
            let count = MathMacros.collectDefinitions(from: "$$" + latex + "$$").count
            var attrs = bodyAttributes()
            attrs[.font] = theme.captionFont()
            attrs[.foregroundColor] = theme.secondaryTextColor
            attrs[QuoinAttribute.mathSource] = latex
            let noun = count == 1 ? "macro" : "macros"
            return NSAttributedString(
                string: "  ⋯ \(count) \(noun) defined", attributes: attrs)
        }

        // Display math: natively typeset, centered, 16pt above/below per the
        // element spec. Unsupported LaTeX keeps the styled-source fallback.
        if let native = MathImageRenderer.attachmentString(
            latex: latex, display: true, mathTheme: theme.mathTheme, baseSize: theme.bodySize
        ) {
            let output = NSMutableAttributedString()
            output.append(editChipLine(spacingBefore: 16))
            let attachment = NSMutableAttributedString(attributedString: native)
            // A wide equation (big matrix, long alignment) scales down to fit
            // the column rather than overflowing.
            attachment.refitImageAttachmentsToContentWidth()
            labelAttachmentImages(in: attachment, description: "Math equation")
            let style = paragraphStyle()
            style.alignment = .center
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = 16
            attachment.addAttribute(.paragraphStyle, value: style,
                                    range: NSRange(location: 0, length: attachment.length))
            output.append(attachment)
            output.addAttribute(QuoinAttribute.mathSource, value: latex,
                                range: NSRange(location: 0, length: output.length))
            return output
        }

        // Unsupported LaTeX: the same tidy source-card treatment as an
        // unrenderable mermaid diagram — a dark canvas with a caption — so
        // degradation reads as intentional, never as a broken half-render.
        // The caption NAMES the offending commands when it can.
        return renderSourceCard(
            language: "latex", code: latex,
            sourceKey: QuoinAttribute.mathSource, source: latex,
            caption: Self.mathFallbackCaption(for: latex)
        )
    }

    /// "math · \substack, \xcancel aren't natively typeset yet" when the
    /// degradation traces to specific commands; a generic line otherwise
    /// (e.g. a nesting-limit or delimiter degradation with no named leaf).
    static func mathFallbackCaption(for latex: String) -> String {
        let commands = MathParser.unsupportedCommands(in: MathParser.parse(latex))
        guard !commands.isEmpty else {
            return "math · this LaTeX isn't natively typeset yet"
        }
        let verb = commands.count == 1 ? "isn't" : "aren't"
        return "math · \(commands.joined(separator: ", ")) \(verb) natively typeset yet"
    }

    /// The shared fallback for content we can't render natively (an
    /// unsupported mermaid dialect or LaTeX): a code canvas of the raw source
    /// tagged with its `sourceKey`, plus a muted caption explaining the
    /// degradation. The tag covers only the card, not the caption — matching
    /// how the native paths tag their runs — so a later engine can find and
    /// replace exactly the source region.
    private func renderSourceCard(
        language: String,
        code: String,
        sourceKey: NSAttributedString.Key,
        source: String,
        caption: String
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: renderCodeBlock(language: language, code: code))
        output.addAttribute(sourceKey, value: source, range: NSRange(location: 0, length: output.length))
        var captionAttributes = bodyAttributes()
        captionAttributes[.font] = theme.captionFont()
        captionAttributes[.foregroundColor] = theme.secondaryTextColor
        output.append(NSAttributedString(string: "\n" + caption, attributes: captionAttributes))
        return output
    }

    private func renderTable(header: [TableCell], rows: [[TableCell]], alignments: [TableAlignment]) -> NSAttributedString {
        // M1 table rendering: measured tab stops. The column geometry (widths,
        // alignment inference, tab stops) is a pure computation over the cells
        // — extracted into TableLayout — leaving this method to emit the rows.
        let bodyFont = theme.bodyFont()
        let headerFont = boldVariant(of: bodyFont)
        let columnGap: CGFloat = 24
        guard let layout = TableLayout.compute(
            header: header, rows: rows, alignments: alignments,
            bodyFont: bodyFont, headerFont: headerFont,
            columnGap: columnGap, maxColumnWidth: theme.maxContentWidth / 2,
            measure: { text, font in (text as NSString).size(withAttributes: [.font: font]).width }
        ) else { return NSAttributedString() }

        let style = paragraphStyle()
        style.tabStops = layout.tabStops
        style.defaultTabInterval = columnGap
        style.lineHeightMultiple = 1.2
        style.paragraphSpacing = 5
        style.paragraphSpacingBefore = 3

        func renderRow(_ cells: [TableCell], font: PlatformFont, color: PlatformColor) -> NSAttributedString {
            let row = NSMutableAttributedString()
            var attributes = bodyAttributes()
            attributes[.font] = font
            attributes[.foregroundColor] = color
            attributes[.paragraphStyle] = style
            for (i, cell) in cells.enumerated() {
                var cellAttributes = attributes
                if layout.isNumeric[min(i, layout.columnCount - 1)] {
                    cellAttributes[.font] = PlatformFont.monospacedDigitSystemFont(
                        ofSize: font.pointSize,
                        weight: font == headerFont ? .semibold : .regular
                    )
                }
                row.append(renderInlines(cell.inlines, base: cellAttributes))
                if i < cells.count - 1 {
                    row.append(NSAttributedString(string: "\t", attributes: attributes))
                }
            }
            return row
        }

        let output = NSMutableAttributedString()
        // Edit chip in the band above the table, aligned to the table's own
        // right edge. Kept OUT of the tableRules decoration range: the rule
        // drawer treats the range's first line fragment as the header row
        // (1.5pt rule), which must stay the actual header.
        output.append(editChipLine(spacingBefore: 3, rightTabAt: layout.totalWidth))
        let rulesStart = output.length
        output.append(renderRow(header, font: headerFont, color: theme.textColor))
        for row in rows {
            output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            output.append(renderRow(row, font: bodyFont, color: theme.textColor))
        }
        // Header 1.5pt rule + body hairlines, drawn by the reader view.
        output.addAttribute(
            QuoinAttribute.blockDecoration,
            value: BlockDecoration(kind: .tableRules(
                width: layout.totalWidth,
                header: theme.quoteRule,
                body: theme.tableRule
            )),
            range: NSRange(location: rulesStart, length: output.length - rulesStart)
        )
        return output
    }

    private func renderList(items: [QuoinCore.ListItem], ordered: Bool, start: Int, depth: Int, document: QuoinDocument) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            }
            output.append(renderListItem(item, ordinal: ordered ? start + index : nil, depth: depth, document: document))
        }
        return output
    }

    private func renderListItem(_ item: QuoinCore.ListItem, ordinal: Int?, depth: Int, document: QuoinDocument) -> NSAttributedString {
        let indent = CGFloat(depth + 1) * 22
        let style = paragraphStyle()
        style.firstLineHeadIndent = indent - 22
        style.headIndent = indent
        style.paragraphSpacing = theme.paragraphSpacing * 0.35

        var markerAttributes = bodyAttributes()
        markerAttributes[.paragraphStyle] = style

        let output = NSMutableAttributedString()

        // The marker: checkbox, ordinal, or bullet.
        if let task = item.task {
            var checkbox = markerAttributes
            checkbox[.foregroundColor] = theme.linkColor
            if let offset = item.taskMarkerRange?.offset, let url = QuoinLink.taskURL(markerOffset: offset) {
                checkbox[.link] = url
                checkbox[QuoinAttribute.taskMarkerOffset] = NSNumber(value: offset)
            }
            let glyph = task == .checked ? "☑" : "☐"
            output.append(NSAttributedString(string: glyph + "  ", attributes: checkbox))
        } else if let ordinal {
            output.append(NSAttributedString(string: "\(ordinal).  ", attributes: markerAttributes))
        } else {
            output.append(NSAttributedString(string: "•  ", attributes: markerAttributes))
        }

        // Item content: first paragraph flows inline after the marker, any
        // further blocks (nested lists, paragraphs, cards) follow on their
        // own lines, aligned under the item's TEXT column — a continuation
        // paragraph that reused the marker line's hanging indent started
        // at x = 0 and read as a stray paragraph between bullets
        // (ledger #2).
        let continuationStyle = paragraphStyle()
        continuationStyle.firstLineHeadIndent = indent
        continuationStyle.headIndent = indent
        continuationStyle.paragraphSpacing = theme.paragraphSpacing * 0.35

        for (blockIndex, block) in item.blocks.enumerated() {
            if blockIndex > 0 {
                output.append(NSAttributedString(string: "\n", attributes: markerAttributes))
            }
            switch block.kind {
            case .paragraph(let inlines):
                var attributes = bodyAttributes()
                attributes[.paragraphStyle] = blockIndex == 0 ? style : continuationStyle
                if item.task == .checked {
                    // Done rows strike and fade to 40% per the element spec.
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.foregroundColor] = theme.ink.withAlphaComponent(0.4)
                    attributes[.strikethroughColor] = theme.ink.withAlphaComponent(0.4)
                }
                output.append(renderInlines(inlines, base: attributes))
            case .list(let nested, let nestedOrdered, let nestedStart):
                output.append(renderList(items: nested, ordered: nestedOrdered, start: nestedStart, depth: depth + 1, document: document))
            default:
                // A card child (code, diagram, quote) nests under the item:
                // indent its text and its chrome together (ledger #2).
                let childStart = output.length
                output.append(render(block: block, depth: depth + 1, document: document))
                indentCard(in: output,
                           range: NSRange(location: childStart, length: output.length - childStart),
                           by: indent)
            }
        }
        return output
    }

    /// Nests a card child one level deeper: bumps its paragraph indents
    /// AND its decoration's leading inset by `delta`, so the canvas/box/
    /// frame moves with its text instead of breaking out to x = 0
    /// (ledger #1/#2). Composes across levels — each container adds its
    /// own delta.
    private func indentCard(in output: NSMutableAttributedString, range: NSRange, by delta: CGFloat) {
        output.enumerateAttribute(.paragraphStyle, in: range) { value, styleRange, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? paragraphStyle()
            style.firstLineHeadIndent += delta
            style.headIndent += delta
            output.addAttribute(.paragraphStyle, value: style, range: styleRange)
        }
        output.enumerateAttribute(QuoinAttribute.blockDecoration, in: range) { value, decorationRange, _ in
            guard let decoration = value as? BlockDecoration else { return }
            output.addAttribute(
                QuoinAttribute.blockDecoration,
                value: decoration.inset(by: delta),
                range: decorationRange
            )
        }
    }

    private func renderBlockQuote(children: [Block], depth: Int, document: QuoinDocument) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, child) in children.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            }
            output.append(render(block: child, depth: depth + 1, document: document))
        }
        let full = NSRange(location: 0, length: output.length)

        // A nested card (code block, diagram, table, callout) already carries
        // its own blockDecoration and styling. The quote's italic / recolor /
        // indent passes and its full-range quote-rule overwrite must skip those
        // ranges, or the child loses its canvas and renders as bare, italicised,
        // muted monospace. Collect the card ranges, then style only the gaps.
        var cardRanges: [NSRange] = []
        output.enumerateAttribute(QuoinAttribute.blockDecoration, in: full) { value, range, _ in
            if value != nil { cardRanges.append(range) }
        }
        func intersectsCard(_ range: NSRange) -> Bool {
            cardRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        // Text runs are the parts of `full` not covered by any card.
        var textRuns: [NSRange] = []
        var cursor = 0
        for card in cardRanges.sorted(by: { $0.location < $1.location }) {
            if card.location > cursor {
                textRuns.append(NSRange(location: cursor, length: card.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(card))
        }
        if cursor < full.length {
            textRuns.append(NSRange(location: cursor, length: full.length - cursor))
        }

        output.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            guard !intersectsCard(range) else { return }
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? paragraphStyle()
            style.firstLineHeadIndent += 16
            style.headIndent += 16
            output.addAttribute(.paragraphStyle, value: style, range: range)
        }
        // Cards nest INSIDE the quote: same 16pt push, applied to their
        // indents and their chrome's leading inset together — the italic/
        // recolor passes still skip them (a card keeps its own styling),
        // but geometry must follow the container (ledger #1).
        for card in cardRanges {
            indentCard(in: output, range: card, by: 16)
        }
        // Element spec: pad-left 16, italic, 55% ink, 3pt rule at the left
        // edge (drawn as a block decoration by the reader view).
        output.enumerateAttribute(.font, in: full) { value, range, _ in
            guard !intersectsCard(range) else { return }
            // Inline code carries its own monospace font + fill; italicising it
            // shifts the baseline off the surrounding quote text. Leave it be.
            if output.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil { return }
            let font = value as? PlatformFont ?? theme.bodyFont()
            output.addAttribute(.font, value: italicVariant(of: font), range: range)
        }
        for run in textRuns {
            output.addAttribute(.foregroundColor, value: theme.secondaryTextColor, range: run)
            output.addAttribute(
                QuoinAttribute.blockDecoration,
                value: BlockDecoration(kind: .quoteRule(color: theme.quoteRule)),
                range: run
            )
        }
        return output
    }

    private func renderThematicBreak() -> NSAttributedString {
        // 1px hairline @12% ink, 20 above/below. Drawn as a line of box
        // glyphs until the block decoration pass draws a true rule.
        var attributes = bodyAttributes()
        attributes[.foregroundColor] = theme.hairline
        attributes[.font] = PlatformFont.systemFont(ofSize: 8)
        let style = paragraphStyle()
        style.alignment = .center
        style.paragraphSpacingBefore = 20
        style.paragraphSpacing = 20
        attributes[.paragraphStyle] = style
        return NSAttributedString(string: String(repeating: "─", count: 60), attributes: attributes)
    }

    // MARK: - Inlines

    private func renderInlines(_ inlines: [Inline], base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for inline in inlines {
            output.append(renderInline(inline, attributes: base))
        }
        return output
    }

    private func renderInline(_ inline: Inline, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        switch inline {
        case .text(let text):
            return NSAttributedString(string: text, attributes: attributes)

        case .code(let code):
            var attrs = attributes
            attrs[.font] = theme.inlineCodeFont()
            attrs[.backgroundColor] = theme.inlineCodeFill
            return NSAttributedString(string: code, attributes: attrs)

        case .emphasis(let children):
            var attrs = attributes
            attrs[.font] = italicVariant(of: attrs[.font] as? PlatformFont ?? theme.bodyFont())
            return renderInlines(children, base: attrs)

        case .strong(let children):
            // Bold text is full ink (#1D1D1F) per the element spec.
            var attrs = attributes
            attrs[.font] = boldVariant(of: attrs[.font] as? PlatformFont ?? theme.bodyFont())
            attrs[.foregroundColor] = theme.ink
            return renderInlines(children, base: attrs)

        case .strikethrough(let children):
            // 45% ink per the element spec.
            var attrs = attributes
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.foregroundColor] = theme.ink.withAlphaComponent(0.45)
            return renderInlines(children, base: attrs)

        case .link(let destination, let children):
            // Accent text with a 35%-alpha accent underline.
            var attrs = attributes
            attrs[.foregroundColor] = theme.linkColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.underlineColor] = theme.linkColor.withAlphaComponent(0.35)
            if let destination {
                if destination.hasPrefix("#") {
                    attrs[.link] = QuoinLink.anchorURL(slug: String(destination.dropFirst())) as Any
                } else if let url = URL(string: destination) {
                    attrs[.link] = url
                }
            }
            return renderInlines(children, base: attrs)

        case .image(let source, let alt):
            return renderImage(source: source, alt: alt, attributes: attributes)

        case .math(let latex):
            // Natively typeset inline math, baseline-aligned with the text;
            // unsupported LaTeX degrades to marked styled source (PRD rule).
            if let native = MathImageRenderer.attachmentString(
                latex: latex, display: false, mathTheme: theme.mathTheme, baseSize: theme.bodySize
            ) {
                let output = NSMutableAttributedString(attributedString: native)
                var carried = attributes
                carried[QuoinAttribute.mathSource] = latex
                carried.removeValue(forKey: .font)
                output.addAttributes(carried, range: NSRange(location: 0, length: output.length))
                return output
            }
            var attrs = attributes
            attrs[.font] = theme.inlineCodeFont()
            attrs[.foregroundColor] = theme.secondaryTextColor
            attrs[QuoinAttribute.mathSource] = latex
            // Name the culprit on hover — inline has no room for a caption.
            // NSToolTip is AppKit-only; iOS just shows the dimmed source.
            #if canImport(AppKit)
            attrs[.toolTip] = Self.mathFallbackCaption(for: latex)
            #endif
            return NSAttributedString(string: latex, attributes: attrs)

        case .highlight(let children, let color):
            // Pill highlight in the span's palette color (⇧⌘H cycles it).
            var attrs = attributes
            attrs[.backgroundColor] = (Theme.Highlight(rawValue: color.rawValue) ?? .lime).color
            attrs[.foregroundColor] = theme.textColor
            return renderInlines(children, base: attrs)

        case .footnoteReference(let id, let index):
            // Superscript accent marker, linked to its definition at the
            // document tail (click jumps, hover peeks). The id tag is the
            // ↩ backlink's landing target — the coordinator scans for it.
            var attrs = attributes
            attrs[.font] = PlatformFont.systemFont(ofSize: theme.bodySize * 0.75)
            attrs[.foregroundColor] = theme.accent
            attrs[.baselineOffset] = theme.bodySize * 0.33
            attrs[QuoinAttribute.footnoteID] = id
            if let url = QuoinLink.footnoteURL(id: id) {
                attrs[.link] = url
            }
            return NSAttributedString(string: "\(index)", attributes: attrs)

        case .suggestion(let kind, let markRange, _):
            // CriticMarkup marks (docs/design/suggestions.md, S1 read-only):
            // pending suggestions render as tracked changes — never silently
            // collapsed (RDFM normative rule). Accept/reject chips arrive in
            // S2; the reveal shows the literal mark syntax.
            func tagged(_ rendered: NSAttributedString) -> NSAttributedString {
                let output = NSMutableAttributedString(attributedString: rendered)
                output.addAttribute(
                    QuoinAttribute.suggestionRange,
                    value: NSValue(range: NSRange(location: markRange.offset, length: markRange.length)),
                    range: NSRange(location: 0, length: output.length))
                return output
            }
            switch kind {
            case .insertion(let children):
                var attrs = attributes
                attrs[.backgroundColor] = theme.suggestionInsertFill
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[.underlineColor] = theme.suggestionInsertInk.withAlphaComponent(0.5)
                return tagged(renderInlines(children, base: attrs))
            case .deletion(let children):
                var attrs = attributes
                attrs[.backgroundColor] = theme.suggestionDeleteFill
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.foregroundColor] = theme.ink.withAlphaComponent(0.55)
                return tagged(renderInlines(children, base: attrs))
            case .substitution(let old, let new):
                let output = NSMutableAttributedString()
                var oldAttrs = attributes
                oldAttrs[.backgroundColor] = theme.suggestionDeleteFill
                oldAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                oldAttrs[.foregroundColor] = theme.ink.withAlphaComponent(0.55)
                output.append(renderInlines(old, base: oldAttrs))
                var arrowAttrs = attributes
                arrowAttrs[.foregroundColor] = theme.secondaryTextColor
                output.append(NSAttributedString(string: " → ", attributes: arrowAttrs))
                var newAttrs = attributes
                newAttrs[.backgroundColor] = theme.suggestionInsertFill
                newAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                newAttrs[.underlineColor] = theme.suggestionInsertInk.withAlphaComponent(0.5)
                output.append(renderInlines(new, base: newAttrs))
                return tagged(output)
            case .comment(let text):
                // Annotation, not document text: a compact bubble chip. The
                // full comment shows in the tooltip; S2 gives it a real UI.
                var attrs = attributes
                attrs[.font] = PlatformFont.systemFont(ofSize: theme.bodySize * 0.8)
                attrs[.foregroundColor] = theme.suggestionCommentInk
                attrs[.backgroundColor] = theme.suggestionCommentFill
                #if canImport(AppKit)
                attrs[.toolTip] = text as NSString
                #endif
                let label = text.count <= 24 ? text : String(text.prefix(23)) + "…"
                return tagged(NSAttributedString(string: " 💬 \(label) ", attributes: attrs))
            case .highlight(let children):
                var attrs = attributes
                attrs[.backgroundColor] = theme.suggestionHighlightFill
                attrs[.foregroundColor] = theme.textColor
                return tagged(renderInlines(children, base: attrs))
            }

        case .softBreak:
            return NSAttributedString(string: " ", attributes: attributes)

        case .lineBreak:
            return NSAttributedString(string: "\n", attributes: attributes)

        case .html(let raw):
            var attrs = attributes
            attrs[.font] = theme.inlineCodeFont()
            attrs[.foregroundColor] = theme.secondaryTextColor
            return NSAttributedString(string: raw, attributes: attrs)
        }
    }

    // MARK: - Images

    private func renderImage(source: String?, alt: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        func placeholder(_ label: String) -> NSAttributedString {
            var attrs = attributes
            attrs[.font] = theme.inlineCodeFont()
            attrs[.foregroundColor] = theme.secondaryTextColor
            attrs[.backgroundColor] = theme.inlineCodeFill
            return NSAttributedString(string: " ▢ \(label) ", attributes: attrs)
        }

        guard let source, !source.isEmpty else { return placeholder(alt.isEmpty ? "image" : alt) }

        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            // Local-only policy: remote images are placeholders unless the
            // user opts in for this document (opt-in fetch arrives with the
            // async image pipeline in M2a).
            return placeholder("remote image: \(source)")
        }

        let fileURL: URL
        if source.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: source)
        } else if let baseURL {
            fileURL = baseURL.appendingPathComponent(source).standardizedFileURL
        } else {
            return placeholder(alt.isEmpty ? source : alt)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return placeholder("missing image: \(source)")
        }
        // Async decode: first render shows a quiet placeholder; the decoded
        // image arrives via onContentReady → re-render. The pending flag keeps
        // this placeholder fragment out of the block cache so that re-render
        // actually rebuilds it (a cached placeholder would stick forever).
        guard let image = AsyncImageStore.shared.image(
            at: fileURL,
            maxDimension: theme.maxContentWidth * 2,
            onReady: onContentReady ?? {}
        ) else {
            let marked = NSMutableAttributedString(
                attributedString: placeholder(alt.isEmpty ? "loading image…" : alt)
            )
            marked.addAttribute(QuoinAttribute.pendingContent, value: NSNumber(value: true),
                                range: NSRange(location: 0, length: marked.length))
            return marked
        }

        let attachment = NSTextAttachment()
        let scale = min(1, theme.maxContentWidth / max(image.size.width, 1))
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0, y: 0,
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let output = NSMutableAttributedString(attachment: attachment)
        output.addAttributes(attributes, range: NSRange(location: 0, length: output.length))
        return output
    }


    // MARK: - Attribute helpers

    /// True when a rendered fragment contains an async placeholder still
    /// waiting on content (a decoding image tagged `pendingContent`). Such
    /// fragments are dropped from the cache so the decoded image rebuilds.
    private func fragmentHasPendingContent(_ fragment: NSAttributedString) -> Bool {
        var pending = false
        fragment.enumerateAttribute(
            QuoinAttribute.pendingContent,
            in: NSRange(location: 0, length: fragment.length)
        ) { value, _, stop in
            if value != nil { pending = true; stop.pointee = true }
        }
        return pending
    }

    private func bodyAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: theme.bodyFont(),
            .foregroundColor: theme.textColor,
            .paragraphStyle: paragraphStyle(),
        ]
    }

    /// Maps a highlighter token kind to its Graphite code color.
    private func codeTokenColor(_ kind: SyntaxTokenKind) -> PlatformColor {
        switch kind {
        case .keyword: return Theme.CodeToken.keyword
        case .function: return Theme.CodeToken.function
        case .type: return Theme.CodeToken.type
        case .comment: return Theme.CodeToken.comment
        case .string: return Theme.CodeToken.string
        case .number: return Theme.CodeToken.number
        }
    }

    private func paragraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = theme.bodyLineHeightMultiple
        style.paragraphSpacing = theme.paragraphSpacing
        return style
    }

    /// Adds bottom padding inside a boxed block (code canvas, callout box) by
    /// widening the last line's `paragraphSpacing`. Reads the last line's
    /// effective paragraph style so it preserves the caller's line metrics and
    /// indents; a no-op on an empty string or a line without a paragraph style.
    private func padLastLine(in output: NSMutableAttributedString, spacing: CGFloat) {
        let text = output.string as NSString
        guard text.length > 0 else { return }
        let lastLine = text.lineRange(for: NSRange(location: text.length - 1, length: 0))
        guard let style = (output.attribute(.paragraphStyle, at: lastLine.location, effectiveRange: nil)
            as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
        style.paragraphSpacing = spacing
        output.addAttribute(.paragraphStyle, value: style, range: lastLine)
    }

    private func boldVariant(of font: PlatformFont) -> PlatformFont {
        #if canImport(AppKit)
        return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        #else
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(.traitBold)
        ) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    private func italicVariant(of font: PlatformFont) -> PlatformFont {
        #if canImport(AppKit)
        return NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        #else
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(.traitItalic)
        ) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }
}

#if canImport(AppKit)
public typealias PlatformImage = NSImage
#else
public typealias PlatformImage = UIImage
#endif
#endif
