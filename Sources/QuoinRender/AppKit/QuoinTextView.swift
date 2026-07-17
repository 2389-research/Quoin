#if canImport(AppKit)
import AppKit
import QuoinCore

// MARK: - Decorated text view

/// `NSTextView` subclass that draws block decorations — code canvases,
/// callout boxes, quote rules, diagram frames, chips, table rules — behind
/// the text. The renderer tags block ranges with `QuoinAttribute
/// .blockDecoration`; geometry comes from the laid-out fragment frames, so
/// the shapes track reflow exactly.
/// The open block's mode chrome — border, ✓ done chip, and label — derived
/// ONCE from the measured box, so they can never disagree (editor-modes
/// plan, Phase 2.2). Consumers (the draw pass, chip hit-testing, the
/// tooltip rect, the preview panel anchor, the accessibility element) all
/// read this one value.
struct EditingChrome: Equatable {
    /// The stroked accent frame (the measured union expanded 4pt).
    let borderRect: CGRect
    /// The ✓ done capsule at the frame's top-right.
    let chipRect: CGRect
    let accent: NSColor

    static let chipLabelText = "✓ done"
    static func chipLabel(accent: NSColor) -> NSAttributedString {
        NSAttributedString(string: chipLabelText, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: accent,
        ])
    }

    init(box: CGRect, accent: NSColor) {
        let rect = box.insetBy(dx: -4, dy: -4)
        borderRect = rect
        let size = Self.chipLabel(accent: accent).size()
        chipRect = CGRect(
            x: rect.maxX - size.width - 6 - 10,
            y: rect.minY + 5,
            width: size.width + 12,
            height: size.height + 4
        )
        self.accent = accent
    }
}

final class QuoinTextView: NSTextView {

    /// While a block is being edited, ⌘A selects ITS editable range, not
    /// the whole document. This must be an override — ⌘A is a MENU key
    /// equivalent that sends `selectAll:` straight to the view, never
    /// through the delegate's doCommandBy hook (live report, twice).
    var selectAllScope: (() -> NSRange?)?

    override func selectAll(_ sender: Any?) {
        if let scope = selectAllScope?() {
            setSelectedRange(scope)
            return
        }
        super.selectAll(sender)
    }

    /// Internal for tests (the incremental-maintenance equivalence check).
    var decorationRuns: [(range: NSRange, decoration: BlockDecoration)] = []
    private var runsAreStale = true

    /// One decoration run with its geometry, measured in the single
    /// per-draw measure pass (editor-modes plan, Phase 2.1): every
    /// consumer draws/derives from this snapshot instead of re-querying
    /// fragment frames itself. Viewport-scoped by construction — only
    /// visible(±slack) runs are measured, preserving TextKit 2's laziness.
    struct MeasuredRun {
        let range: NSRange
        let decoration: BlockDecoration
        /// Union of fragment frames (view coords), width-adjusted for
        /// full-width chrome.
        let box: CGRect
        /// Per-fragment frames (view coords) — table rules draw per line.
        let frames: [CGRect]
        /// Widest laid-out line, for chip-width fitting.
        let textWidth: CGFloat
    }
    /// The most recent measure pass's output. Internal for tests.
    private(set) var measuredRuns: [MeasuredRun] = []
    /// The open block's chrome, derived from the measured editingFrame run;
    /// nil when no block is open. Internal for tests.
    private(set) var editingChrome: EditingChrome?

    /// Set by the coordinator: a double-click landed on the character at
    /// this index. Returns true when it consumed the gesture (an embed flip)
    /// — the event must NOT fall through to super then: AppKit's word-select
    /// tracking would run while the flip replaces the text underneath it,
    /// and its indexes would resolve into the newly revealed source as a
    /// random selection ("double clicking selects random portions of the
    /// mermaid source").
    var onDoubleClick: ((Int) -> Bool)?

    /// The drawn `✓ done` chip's frame (view coordinates), recorded by the
    /// editingFrame decoration pass each draw; nil when no block is open.
    /// The chip is decoration ink, not a text run (the revealed source is
    /// 1:1 with the file), so clicks are hit-tested here, before AppKit's
    /// caret placement can see them — and its tooltip is a view tooltip
    /// rect, re-registered whenever the drawn frame moves.
    private(set) var doneChipRect: CGRect? {
        didSet {
            guard doneChipRect != oldValue else { return }
            if let tag = doneChipToolTipTag {
                removeToolTip(tag)
                doneChipToolTipTag = nil
            }
            if let rect = doneChipRect {
                doneChipToolTipTag = addToolTip(
                    rect.insetBy(dx: -8, dy: -7), owner: Self.doneChipToolTipText, userData: nil)
            }
        }
    }
    private var doneChipToolTipTag: NSView.ToolTipTag?
    // addToolTip does not retain its owner; keep the string alive.
    private static let doneChipToolTipText = "Done Editing (⌘↩ or esc)" as NSString
    /// Single click on the ✓ done chip: commit and close the open block.
    var onDoneChipClick: (() -> Void)?

    /// Right-click: lets the coordinator prepend block-aware items
    /// (Edit Source / Copy Markdown Source) to the standard text menu.
    var onContextMenu: ((Int, NSMenu) -> Void)?

    /// Smart paste (idea #4): the coordinator turns URLs-over-selection
    /// into links and tabular text into tables; returning false falls
    /// through to the ordinary paste pipeline.
    var onSmartPaste: (() -> Bool)?

    /// Image paste (#24): a clipboard image (screenshot, copied bitmap, or
    /// copied image file) is written into the library and referenced with
    /// `![](assets/…)`. Returning true means the image was handled, so the
    /// plain-text paste (which would drop nothing useful) is skipped.
    var onPasteImage: (() -> Bool)?

    override func paste(_ sender: Any?) {
        if onPasteImage?() == true { return }
        if onSmartPaste?() == true { return }
        super.paste(sender)
    }

    /// Link hover (idea #8): reports the URL under the pointer (nil when
    /// the pointer leaves links) so the coordinator can peek internal
    /// anchor targets. Throttled by character index.
    var onLinkHover: ((URL?, NSRect) -> Void)?
    private var hoverTracking: NSTrackingArea?
    private var lastHoverIndex = -1

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
            self.hoverTracking = nil
        }
        guard onLinkHover != nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let onLinkHover else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard index != lastHoverIndex else { return }
        lastHoverIndex = index
        guard index >= 0,
              let storage = textContentStorage?.textStorage,
              index < storage.length,
              let url = storage.attribute(.link, at: index, effectiveRange: nil) as? URL
        else {
            onLinkHover(nil, .zero)
            return
        }
        onLinkHover(url, NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        lastHoverIndex = -1
        onLinkHover?(nil, .zero)
    }

    /// The drawn editing frame's box (text-view coordinates), reported
    /// when it CHANGES — nil when no block is open. The side-by-side
    /// preview panel positions itself against it. Deduped (ledger perf
    /// #10): every drawBackground pass used to fire an async dispatch;
    /// now one fires only when the rect actually differs from the last
    /// report. Panel-content changes with an unchanged frame are covered
    /// by the coordinator's projection-change refresh.
    var onEditingFrameGeometry: ((CGRect?) -> Void)?
    /// The last geometry pushed to the coordinator, so an unchanged frame
    /// isn't re-reported. `.unreported` distinguishes "nothing sent yet"
    /// from `.reported(nil)` ("sent: no open block").
    private enum LastFrameReport: Equatable {
        case unreported
        case reported(CGRect?)
    }
    private var lastReportedEditingFrame: LastFrameReport = .unreported

    private func reportEditingFrameGeometry(_ rect: CGRect?) {
        guard onEditingFrameGeometry != nil, lastReportedEditingFrame != .reported(rect) else { return }
        lastReportedEditingFrame = .reported(rect)
        // Mutating the view hierarchy mid-draw is illegal — next turn.
        DispatchQueue.main.async { [weak self] in
            self?.onEditingFrameGeometry?(rect)
        }
    }

    /// Ambient paused status: while the live preview is paused (admitted),
    /// the editing frame's stroke turns this color instead of the accent.
    /// Set by the coordinator; changes as a cut, never a fade.
    var editingFrameTintOverride: NSColor?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if index >= 0 {
            onContextMenu?(index, menu)
        }
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        let clipBefore = enclosingScrollView?.contentView.bounds.origin.y ?? -1
        if event.clickCount == 1, let chip = doneChipRect {
            let point = convert(event.locationInWindow, from: nil)
            // ≥28pt effective hit target around the small caption.
            if chip.insetBy(dx: -8, dy: -7).contains(point) {
                onDoneChipClick?()
                return
            }
        }
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            if index >= 0, onDoubleClick?(index) == true {
                // Embed flip: consume the event — no word-select tracking
                // over text that is about to be replaced.
                return
            }
            // Fall through to super so text blocks still get word-select.
        }
        super.mouseDown(with: event)
        let clipAfter = enclosingScrollView?.contentView.bounds.origin.y ?? -1
        QuoinPerformanceTrace.log(
            "click.mouseDown", startedAt: DispatchTime.now().uptimeNanoseconds,
            metadata: "clipBefore=\(Int(clipBefore)) clipAfter=\(Int(clipAfter)) moved=\(Int(clipAfter - clipBefore)) clicks=\(event.clickCount)")
    }

    /// Every draw is a SETTLED draw: finish the viewport's layout before any
    /// pixel is painted, so decorations read settled fragment positions, not
    /// estimates that predate a reflow. Revealing a delimiter flips its font
    /// (1pt↔full), which reflows the block and moves every FOLLOWING
    /// fragment's y-origin; `.ensuresLayout` during run enumeration only lays
    /// out the enumerated run's own fragments, and a layout forced mid-draw
    /// can't expand the already-committed dirty rect — so a draw against
    /// unsettled predecessors left boxes behind their text with no repaint
    /// scheduled ("box lags text"). Settling here is the editor's "measure
    /// phase": on settled content `layoutViewport()` is a no-op; when it does
    /// move geometry it invalidates display and the next draw settles again
    /// (terminates — geometry is then fixed), both before pixels appear. This
    /// also covers resize reflow (`setFrameSize` → draw) for free.
    override func viewWillDraw() {
        QuoinPerformanceTrace.measure("draw.settleViewport") {
            settleViewportPreservingCaretLine()
        }
        super.viewWillDraw()
    }

    /// The settle must OBEY the viewport invariant it exists to serve: on
    /// large documents (no eager whole-document layout) `layoutViewport()`
    /// can resolve estimated heights ABOVE the viewport, shifting every
    /// document Y — which would silently move the line the caret is on,
    /// undoing a caret pin that ran a moment earlier (proved by
    /// CaretLineAnchorTests.testCaretPinSurvivesSettleOnHugeDocument: a
    /// 169pt jump). So: measure the caret line's screen position, settle,
    /// and scroll by exactly the drift so the caret's line stays put. Only
    /// an ON-SCREEN caret line is preserved — compensating for an off-screen
    /// caret would yank the viewport away from what the user is reading.
    private func settleViewportPreservingCaretLine() {
        guard let layoutManager = textLayoutManager else { return }
        // Width reflow (#65): a pending anchor from setFrameSize wins — it
        // was captured in the OLD geometry, before the rewrap.
        if let anchor = widthReflowAnchor {
            widthReflowAnchor = nil
            restoreWidthAnchor(anchor, layoutManager: layoutManager)
            return
        }
        let clip = enclosingScrollView?.contentView
        let before = caretLineScreenY(clip: clip)
        layoutManager.textViewportLayoutController.layoutViewport()
        guard let clip, let before,
              let after = caretLineScreenY(clip: clip),
              abs(after - before) > 0.5 else { return }
        let target = max(0, clip.bounds.origin.y + (after - before))
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    // MARK: - Width-reflow anchoring (#65)

    /// A width change rewraps every line and moves every fragment — the
    /// caret-line settle preserves nothing in reading mode (caret absent or
    /// offscreen), so closing a sidebar or ending a window resize scrolled
    /// the visible content away (live report: "great while the mouse is
    /// held, wild on mouse-up"). The anchor is captured in OLD geometry at
    /// setFrameSize — the caret line when visible, else the top visible
    /// line — and the next settled draw scrolls it back to its exact
    /// screen position. Re-captured per frame, so animated sidebar
    /// toggles hold the line through the whole animation.
    private var widthReflowAnchor: (location: Int, screenY: CGFloat)?

    private func captureWidthAnchor() -> (location: Int, screenY: CGFloat)? {
        guard let clip = enclosingScrollView?.contentView,
              let layoutManager = textLayoutManager,
              let contentStorage = textContentStorage else { return nil }
        if let y = caretLineScreenY(clip: clip) {
            return (selectedRange().location, y)
        }
        guard let viewport = layoutManager.textViewportLayoutController.viewportRange
        else { return nil }
        var anchor: (Int, CGFloat)?
        layoutManager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            let y = frame.minY + self.textContainerOrigin.y - clip.bounds.origin.y
            if y + frame.height > 0 {
                let location = contentStorage.offset(
                    from: contentStorage.documentRange.location,
                    to: fragment.rangeInElement.location)
                anchor = (location, y)
                return false
            }
            return true
        }
        return anchor
    }

    private func restoreWidthAnchor(
        _ anchor: (location: Int, screenY: CGFloat), layoutManager: NSTextLayoutManager
    ) {
        layoutManager.textViewportLayoutController.layoutViewport()
        guard let clip = enclosingScrollView?.contentView,
              let contentStorage = textContentStorage,
              anchor.location <= (contentStorage.textStorage?.length ?? 0),
              let docLocation = contentStorage.location(
                contentStorage.documentRange.location, offsetBy: anchor.location)
        else { return }
        layoutManager.ensureLayout(for: NSTextRange(location: docLocation))
        guard let fragment = layoutManager.textLayoutFragment(for: docLocation) else { return }
        let after = fragment.layoutFragmentFrame.minY + textContainerOrigin.y - clip.bounds.origin.y
        let drift = after - anchor.screenY
        guard abs(drift) > 0.5 else { return }
        let target = max(0, clip.bounds.origin.y + drift)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        enclosingScrollView?.reflectScrolledClipView(clip)
        // The scroll changed the viewport — settle the new extent before
        // pixels appear (same terminating argument as the caret settle).
        layoutManager.textViewportLayoutController.layoutViewport()
    }

    /// Screen-space y of the line containing the caret, or nil when the
    /// caret's line is off-screen or geometry is unavailable. Deliberately
    /// does NOT force layout — it reads whatever geometry exists, because
    /// it's used to measure the settle's own effect.
    private func caretLineScreenY(clip: NSClipView?) -> CGFloat? {
        guard let clip,
              let layoutManager = textLayoutManager,
              let contentStorage = textContentStorage else { return nil }
        let location = selectedRange().location
        guard location >= 0, location <= (contentStorage.textStorage?.length ?? 0),
              let docLocation = contentStorage.location(contentStorage.documentRange.location, offsetBy: location),
              let fragment = layoutManager.textLayoutFragment(for: docLocation)
        else { return nil }
        let y = fragment.layoutFragmentFrame.minY + textContainerOrigin.y - clip.bounds.origin.y
        guard y >= -fragment.layoutFragmentFrame.height, y <= clip.bounds.height else { return nil }
        return y
    }

    func invalidateDecorations() {
        runsAreStale = true
        needsDisplay = true
    }

    /// Redraw with the CURRENT runs — for attribute-only restyles (syntax
    /// reveal flipping delimiter fonts as the caret moves): the run ranges
    /// are unchanged, only their geometry moved, and geometry is read fresh
    /// from the laid-out fragments at draw time. A full `invalidate` here
    /// re-enumerated the whole document's attributes on every caret move.
    func redrawDecorations() {
        needsDisplay = true
    }

    /// Incremental alternative to `invalidateDecorations()` for a bounded
    /// storage edit: drops runs the edit touched, shifts the rest by the
    /// length delta, and rescans ONLY the replaced range. A full rescan
    /// enumerates the whole document's attributes (~170 ms at novel length)
    /// — per keystroke, that was the render layer's last document-scale
    /// cost.
    func noteStorageEdit(oldRange: NSRange, newLength: Int) {
        guard !runsAreStale, let storage = textContentStorage?.textStorage else {
            invalidateDecorations()
            return
        }
        let delta = newLength - oldRange.length
        let oldEnd = NSMaxRange(oldRange)

        // Partition: untouched runs before / after the edit; runs overlapping
        // it widen the rescan window (a run can start before the patched
        // fragment — dropping it without rescanning its full extent would
        // orphan the prefix).
        var before: [(range: NSRange, decoration: BlockDecoration)] = []
        var after: [(range: NSRange, decoration: BlockDecoration)] = []
        var scanStart = oldRange.location
        var scanEndOld = oldEnd
        for run in decorationRuns {
            if NSMaxRange(run.range) <= oldRange.location {
                before.append(run)
            } else if run.range.location >= oldEnd {
                after.append((NSRange(location: run.range.location + delta,
                                      length: run.range.length), run.decoration))
            } else {
                scanStart = min(scanStart, run.range.location)
                scanEndOld = max(scanEndOld, NSMaxRange(run.range))
            }
        }

        var middle: [(range: NSRange, decoration: BlockDecoration)] = []
        let scanEnd = min(max(scanStart, scanEndOld + delta), storage.length)
        if scanStart >= 0, scanEnd > scanStart {
            storage.enumerateAttribute(
                QuoinAttribute.blockDecoration,
                in: NSRange(location: scanStart, length: scanEnd - scanStart)
            ) { value, range, _ in
                if let decoration = value as? BlockDecoration {
                    middle.append((range, decoration))
                }
            }
        }

        decorationRuns = before + middle + after
        needsDisplay = true
    }

    // Any live layout change (viewport re-layout after estimates resolve)
    // must redraw decorations, or boxes lag behind their text. A WIDTH
    // change also captures the reflow anchor (in the old geometry) that
    // the next settled draw restores (#65).
    override func setFrameSize(_ newSize: NSSize) {
        if abs(newSize.width - frame.width) > 0.5 {
            widthReflowAnchor = captureWidthAnchor() ?? widthReflowAnchor
        }
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    func refreshRunsIfNeeded() {
        guard runsAreStale, let storage = textContentStorage?.textStorage else { return }
        runsAreStale = false
        decorationRuns.removeAll()
        storage.enumerateAttribute(
            QuoinAttribute.blockDecoration,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            if let decoration = value as? BlockDecoration {
                decorationRuns.append((range, decoration))
            }
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        measureVisibleRuns()
        for run in measuredRuns {
            guard run.box.insetBy(dx: -8, dy: -8).intersects(rect) else { continue }
            draw(run)
        }
    }

    /// The chip must sit ON TOP of the glyphs: it lived in drawBackground
    /// once, where a long unwrapped code line reaching the frame's top-right
    /// painted straight over it (editor-modes review, Seam 5). The border
    /// stays behind the text (background); only the chip rides above.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let chrome = editingChrome,
              chrome.chipRect.insetBy(dx: -8, dy: -8).intersects(dirtyRect),
              let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // ✓ done wears the same chip shape as its siblings (‹/› edit,
        // ⧉ copy): capsule fill, radius 6, 2×6 padding.
        context.addPath(CGPath(
            roundedRect: chrome.chipRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.setFillColor(chrome.accent.withAlphaComponent(0.12).cgColor)
        context.fillPath()
        EditingChrome.chipLabel(accent: chrome.accent)
            .draw(at: CGPoint(x: chrome.chipRect.minX + 6, y: chrome.chipRect.minY + 2))
    }

    /// The measure pass (editor-modes plan, Phase 2.1): ONE geometry query
    /// per draw produces the snapshot every consumer reads — the draw pass,
    /// the chip's hit-test/tooltip, the preview panel anchor, and the
    /// accessibility element. Nothing else touches fragment frames for
    /// block chrome. Internal for tests (DecorationGeometryTests).
    func measureVisibleRuns() {
        refreshRunsIfNeeded()
        measuredRuns.removeAll(keepingCapacity: true)
        defer { deriveEditingChrome() }
        guard !decorationRuns.isEmpty,
              let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager
        else { return }

        // Cull to the viewport BEFORE computing geometry: enumerating a
        // run's fragments with .ensuresLayout forces layout, so iterating
        // every decorated block in the document laid out the whole file on
        // each draw — TextKit 2's viewport laziness, defeated by its own
        // decorations. The character-range test is cheap and generous
        // (±4096 characters of slack around the viewport range).
        var visible: NSRange?
        if let viewport = layoutManager.textViewportLayoutController.viewportRange {
            let start = contentManager.offset(from: contentManager.documentRange.location,
                                              to: viewport.location)
            let end = contentManager.offset(from: contentManager.documentRange.location,
                                            to: viewport.endLocation)
            let slack = 4096
            let lower = max(0, start - slack)
            visible = NSRange(location: lower, length: end + slack - lower)
        }

        let origin = textContainerOrigin
        for run in decorationRuns {
            if let visible, NSIntersectionRange(run.range, visible).length == 0,
               run.range.length > 0 {
                continue
            }
            guard let textRange = nsTextRange(run.range, in: contentManager) else { continue }

            var frames: [CGRect] = []
            var textWidth: CGFloat = 0
            layoutManager.enumerateTextLayoutFragments(
                from: textRange.location,
                options: [.ensuresLayout]
            ) { fragment in
                if fragment.rangeInElement.location.compare(textRange.endLocation) != .orderedAscending {
                    return false
                }
                frames.append(fragment.layoutFragmentFrame)
                for line in fragment.textLineFragments {
                    textWidth = max(textWidth, line.typographicBounds.width)
                }
                return true
            }
            guard var union = frames.first else { continue }
            for frame in frames.dropFirst() { union = union.union(frame) }

            // Full-width chrome spans the text column regardless of how
            // wide the laid-out lines happen to be.
            if let container = textContainer {
                switch run.decoration.kind {
                case .codeCanvas, .callout, .diagramFrame, .editingFrame:
                    // Full-width chrome starts at the card's own text
                    // column: nested cards (code in a quote, a diagram in
                    // a list item) carry the accumulated nesting inset —
                    // x = 0 made them break out of their container.
                    union.origin.x = run.decoration.leadingInset
                    union.size.width = container.size.width - run.decoration.leadingInset
                default:
                    break
                }
            }

            measuredRuns.append(MeasuredRun(
                range: run.range,
                decoration: run.decoration,
                box: union.offsetBy(dx: origin.x, dy: origin.y),
                frames: frames.map { $0.offsetBy(dx: origin.x, dy: origin.y) },
                textWidth: textWidth
            ))
        }
    }

    /// Chrome derivation from the snapshot — border, chip, tooltip, panel
    /// anchor all from one box. Cleared from the RUN list, not the dirty
    /// rect: a partial redraw that misses the chip must not disable a chip
    /// that is still on screen.
    private func deriveEditingChrome() {
        let frameRun = measuredRuns.first {
            if case .editingFrame = $0.decoration.kind { return true }
            return false
        }
        // The run LIST (unculled) decides existence; the measured run
        // (viewport-scoped) decides geometry. An open block scrolled far
        // off-screen keeps its chrome state but reports no geometry.
        let openBlockExists = decorationRuns.contains {
            if case .editingFrame = $0.decoration.kind { return true }
            return false
        }
        guard openBlockExists else {
            editingChrome = nil
            doneChipRect = nil
            reportEditingFrameGeometry(nil)
            return
        }
        guard let frameRun,
              case .editingFrame(let accent) = frameRun.decoration.kind else { return }
        let chrome = EditingChrome(box: frameRun.box, accent: accent)
        editingChrome = chrome
        doneChipRect = chrome.chipRect
        reportEditingFrameGeometry(chrome.borderRect)
    }

    private func draw(_ run: MeasuredRun) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let decoration = run.decoration
        let box = run.box
        let frames = run.frames
        let textWidth = run.textWidth

        switch decoration.kind {
        case .codeCanvas(let fill):
            let rect = box.insetBy(dx: 0, dy: -2)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.setFillColor(fill.cgColor)
            context.fillPath()

        case .callout(let color):
            // Symmetric interior padding that clears the last line's
            // descenders; external separation between adjacent cards comes
            // from the widened block separator, not a one-sided bulge here.
            let rect = box.insetBy(dx: 0, dy: -5)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.setFillColor(color.withAlphaComponent(0.05).cgColor)
            context.fillPath()
            context.addPath(CGPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                cornerWidth: 7.5, cornerHeight: 7.5, transform: nil
            ))
            context.setStrokeColor(color.withAlphaComponent(0.15).cgColor)
            context.setLineWidth(1)
            context.strokePath()

        case .quoteRule(let color):
            // box.minX is the indented text's left edge; the rule sits in the
            // gutter to its left so glyphs never overlap the bar.
            let bar = CGRect(x: box.minX - 14, y: box.minY + 3, width: 3, height: box.height - 6)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.setFillColor(color.cgColor)
            context.fillPath()

        case .diagramFrame(let color):
            let rect = box.insetBy(dx: 0, dy: -4)
            context.addPath(CGPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                cornerWidth: 8, cornerHeight: 8, transform: nil
            ))
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1)
            context.strokePath()

        case .chip(let fill):
            let rect = CGRect(
                x: box.minX,
                y: box.minY + 1,
                width: min(textWidth + 16, box.width),
                height: box.height - 2
            )
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.setFillColor(fill.cgColor)
            context.fillPath()

        case .editingFrame(let accent):
            // The open block's mode chrome: 1.5pt frame, geometry from the
            // shared EditingChrome (derived in the measure pass — the chip,
            // tooltip, panel anchor, and AX element read the SAME value).
            // Drawn ink only — the revealed source under it stays 1:1 with
            // the file. The stroke turns amber while the live preview is
            // paused (ambient status at the locus's edge). The ✓ done chip
            // draws in draw(_:), ABOVE the glyphs (review Seam 5).
            let stroke = editingFrameTintOverride ?? accent
            let rect = EditingChrome(box: box, accent: accent).borderRect
            context.addPath(CGPath(
                roundedRect: rect.insetBy(dx: 0.75, dy: 0.75),
                cornerWidth: 8, cornerHeight: 8, transform: nil
            ))
            context.setStrokeColor(stroke.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1.5)
            context.strokePath()

        case .tableRules(let width, let header, let body):
            let lineWidth = min(width + 24, box.width)
            for (index, frame) in frames.enumerated() {
                let y = frame.maxY - (index == 0 ? 0.75 : 0.5)
                context.setStrokeColor((index == 0 ? header : body).cgColor)
                context.setLineWidth(index == 0 ? 1.5 : 1)
                context.move(to: CGPoint(x: frame.minX, y: y))
                context.addLine(to: CGPoint(x: frame.minX + lineWidth, y: y))
                context.strokePath()
            }
        }
    }

    // MARK: - Accessibility (editor-modes plan, Phase 2.3)

    /// The ✓ done chip is drawn ink with private hit-testing — invisible to
    /// VoiceOver until given a real accessibility element. Rebuilt on each
    /// query from the current chrome so its frame tracks reflow.
    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        if let chrome = editingChrome, let window {
            let element = DoneChipAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("Done editing")
            element.setAccessibilityHelp("Commits the block and returns it to its rendered form")
            element.setAccessibilityParent(self)
            let windowRect = convert(chrome.chipRect, to: nil)
            element.setAccessibilityFrame(window.convertToScreen(windowRect))
            element.onPress = { [weak self] in self?.onDoneChipClick?() }
            children.append(element)
        }
        return children
    }

    // MARK: - Structure rotors (accessibility structure, #10)

    /// Retains the search delegates: `NSAccessibilityCustomRotor` holds its
    /// `itemSearchDelegate` weakly, so the view must own them.
    private lazy var headingRotorDelegate = StructureRotorDelegate(owner: self)
    private lazy var landmarkRotorDelegate = StructureRotorDelegate(owner: self)

    /// The rotors' item lists are cached and only rescanned when the storage
    /// actually changed, so VoiceOver's per-keystroke queries don't each run
    /// an O(n) full-storage `enumerateAttribute` (#10 perf). Invalidated by
    /// observing the text storage's edit notification.
    private var rotorItemsStale = true
    private weak var observedRotorStorage: NSTextStorage?
    private var rotorStorageObserver: NSObjectProtocol?

    deinit {
        if let token = rotorStorageObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Exposes two VoiceOver custom rotors so a listener can navigate by
    /// document structure instead of arrowing through every line:
    ///   • **Headings** (`.heading`) — jump heading to heading (VO-U).
    ///   • **Landmarks** — flick through the other structural blocks (code,
    ///     table, list, callout, quote, diagram, math, …), each announced with
    ///     its `BlockAccessibility` label ("Table, 3 columns, 4 rows").
    /// Either rotor is dropped when the document has none of its kind.
    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        var rotors = super.accessibilityCustomRotors()
        refreshRotorItemsIfNeeded()
        if !headingRotorDelegate.items.isEmpty {
            rotors.append(NSAccessibilityCustomRotor(
                rotorType: .heading, itemSearchDelegate: headingRotorDelegate))
        }
        if !landmarkRotorDelegate.items.isEmpty {
            rotors.append(NSAccessibilityCustomRotor(
                label: "Landmarks", itemSearchDelegate: landmarkRotorDelegate))
        }
        return rotors
    }

    /// Rescans the storage for rotor items only when it changed since the last
    /// scan (or the storage itself was swapped). One pass populates both
    /// rotors.
    private func refreshRotorItemsIfNeeded() {
        let storage = textContentStorage?.textStorage
        if storage !== observedRotorStorage {
            if let token = rotorStorageObserver {
                NotificationCenter.default.removeObserver(token)
                rotorStorageObserver = nil
            }
            observedRotorStorage = storage
            if let storage {
                // queue nil → synchronous delivery on the (main) posting
                // thread, so a query right after an edit never reads a stale
                // list.
                rotorStorageObserver = NotificationCenter.default.addObserver(
                    forName: NSTextStorage.didProcessEditingNotification,
                    object: storage, queue: nil
                ) { [weak self] _ in self?.rotorItemsStale = true }
            }
            rotorItemsStale = true
        }
        guard rotorItemsStale else { return }
        rotorItemsStale = false
        scanRotorItems(from: storage)
    }

    private func scanRotorItems(from storage: NSTextStorage?) {
        guard let storage, storage.length > 0 else {
            headingRotorDelegate.items = []
            landmarkRotorDelegate.items = []
            return
        }
        var headings: [StructureRotor.Item] = []
        var landmarks: [StructureRotor.Item] = []
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(QuoinAttribute.headingLevel, in: full) { value, range, _ in
            guard let level = (value as? NSNumber)?.intValue else { return }
            // A title-less heading renders as a lone zero-width space (see
            // AttributedRenderer.renderHeading) purely so it has a navigable
            // position — strip it so the spoken label reads "Heading level N".
            let title = storage.attributedSubstring(from: range).string
                .replacingOccurrences(of: "\u{200B}", with: "")
            headings.append(StructureRotor.Item(
                location: range.location, length: range.length,
                label: BlockAccessibility.headingAnnouncement(level: level, title: title)))
        }
        storage.enumerateAttribute(QuoinAttribute.blockAccessibilityLabel, in: full) { value, range, _ in
            guard let label = value as? String else { return }
            landmarks.append(StructureRotor.Item(
                location: range.location, length: range.length, label: label))
        }
        headingRotorDelegate.items = headings.sorted { $0.location < $1.location }
        landmarkRotorDelegate.items = landmarks.sorted { $0.location < $1.location }
    }

}

/// Feeds a structure rotor (Headings or Landmarks). Holds the current items
/// (set by `QuoinTextView.scanRotorItems`) and answers next/previous queries
/// through the pure `StructureRotor.result` navigator, so the direction /
/// filter logic is tested without a text system.
private final class StructureRotorDelegate: NSObject, NSAccessibilityCustomRotorItemSearchDelegate {
    private weak var owner: NSTextView?
    fileprivate var items: [StructureRotor.Item] = []

    init(owner: NSTextView) {
        self.owner = owner
    }

    func rotor(
        _ rotor: NSAccessibilityCustomRotor,
        resultFor parameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let owner else { return nil }
        let direction: StructureRotor.Direction
        switch parameters.searchDirection {
        case .next: direction = .next
        case .previous: direction = .previous
        @unknown default: return nil
        }
        guard let hit = StructureRotor.result(
            items: items,
            currentLocation: parameters.currentItem?.targetRange.location,
            direction: direction,
            filter: parameters.filterString
        ) else { return nil }

        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: owner)
        result.targetRange = NSRange(location: hit.location, length: hit.length)
        result.customLabel = hit.label
        return result
    }
}

/// AX proxy for the drawn ✓ done chip: pressable by VoiceOver, routed to
/// the same close path as a physical click.
private final class DoneChipAccessibilityElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
#endif
