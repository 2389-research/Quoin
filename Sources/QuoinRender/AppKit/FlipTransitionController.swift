#if canImport(AppKit)
import AppKit

/// The embed-flip motion system (embed-editing brief, Phase 3): a
/// snapshot-overlay choreography that makes activate/deactivate flips read
/// as one continuous change instead of a hard cut.
///
/// Mechanism — cosmetic by construction: the REAL layout is applied
/// instantly (splice → pin → settle, exactly as before; nothing here writes
/// to storage or scroll position). Just before the splice, the current
/// pixels are frozen into an overlay covering the viewport; after the
/// settle pass the overlay is dismantled in slices that converge on the
/// real geometry:
///
/// - The old block's slice CROSSFADES out over the new block already laid
///   out beneath it (~170ms ease-out).
/// - Everything below the block SLIDES its true reflow distance (~240ms,
///   decelerating) — sliding the reflow rather than masking it, because the
///   reflow is real and animating a true layout change lets the eye track
///   what moved. Content above the pinned anchor never moves at all (the
///   viewport invariant), so it is never covered.
///
/// Keyed to the height delta: |Δh| ≤ 40pt is the habituated check-the-
/// render loop and stays INSTANT; Δh beyond half the viewport reads as
/// scrolling if slid, so it becomes a full-viewport crossfade; Reduce
/// Motion collapses everything to a 120ms crossfade; novel-scale documents
/// (no eager layout → estimated geometry) skip motion entirely.
///
/// Any user input or newer projection truncates to the end state
/// immediately, and a 500ms watchdog removes the cover unconditionally —
/// a stuck cover is the worst possible failure.
@MainActor
final class FlipTransitionController {

    /// What a given flip should do — pure math, unit-tested.
    enum Plan: Equatable {
        case none
        /// Full-viewport crossfade of the frozen cover.
        case crossfade(duration: TimeInterval)
        /// Block-region crossfade + below-content slide by `delta`.
        case slices(blockFade: TimeInterval, slide: TimeInterval, delta: CGFloat)
    }

    /// Decides the treatment from the flip's geometry. `expanding` marks a
    /// flip whose new content is taller (the incoming render needs a beat
    /// longer to be received — brief spec: 260/180 vs 240/170).
    static func plan(
        oldBlockHeight: CGFloat,
        newBlockHeight: CGFloat,
        viewportHeight: CGFloat,
        reduceMotion: Bool,
        documentLength: Int
    ) -> Plan {
        guard documentLength < 200_000, viewportHeight > 0 else { return .none }
        let delta = newBlockHeight - oldBlockHeight
        if abs(delta) <= 40 { return .none }
        if reduceMotion { return .crossfade(duration: 0.12) }
        if abs(delta) > viewportHeight / 2 { return .crossfade(duration: 0.20) }
        let expanding = delta > 0
        return .slices(
            blockFade: expanding ? 0.18 : 0.17,
            slide: expanding ? 0.26 : 0.24,
            delta: delta
        )
    }

    /// Overlay host: flipped so slice frames are plain viewport
    /// coordinates (y-down, like the text view), and transparent to
    /// clicks — frozen pixels must never eat input meant for the text.
    private final class OverlayContainer: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private weak var scrollView: NSScrollView?
    private weak var textView: QuoinTextView?
    private var container: OverlayContainer?
    private var overlays: [NSView] = []
    private var watchdog: DispatchWorkItem?
    private var scrollObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?

    private struct Capture {
        let image: CGImage
        /// Snapshot extent in viewport coordinates (starts at the viewport
        /// top; extends one overscan past its bottom so upward slides have
        /// pixels to reveal).
        let extent: CGRect
        let oldBlockRect: CGRect
        let scale: CGFloat
    }
    private var pending: Capture?

    init(scrollView: NSScrollView, textView: QuoinTextView) {
        self.scrollView = scrollView
        self.textView = textView
        // A live user scroll must truncate to the end state instantly —
        // frozen pixels under a moving viewport are a lie. (Not
        // boundsDidChange: the pin itself fires that.)
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        scrollView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
    }

    /// Freezes the current pixels. Call BEFORE the splice, in the same
    /// runloop turn — the cover and the splice then commit in one frame, so
    /// the splice, pin, and settle correction all happen invisibly under it
    /// (this also hides what used to be the flip's worst frame).
    func capture(oldBlockRect: CGRect) {
        cancel()
        guard let scrollView, let textView, textView.window != nil else { return }
        let clip = scrollView.contentView
        let visible = clip.documentVisibleRect
        // Overscan exists so an upward slide has pixels to reveal below
        // the viewport — and the slide delta is capped at viewport/2 (any
        // larger becomes a crossfade), so viewport/2 is exactly enough.
        // The old fixed 600pt over-rasterized short viewports (perf #9).
        let overscan: CGFloat = min(600, visible.height / 2)
        // Clamped to the document: caching a rect past the view's bounds
        // is undefined.
        let captureRect = CGRect(
            x: visible.minX, y: visible.minY,
            width: visible.width, height: visible.height + overscan
        ).intersection(textView.bounds)
        guard captureRect.width > 0, captureRect.height > 0,
              let rep = textView.bitmapImageRepForCachingDisplay(in: captureRect)
        else { return }
        textView.cacheDisplay(in: captureRect, to: rep)
        guard let image = rep.cgImage else { return }
        pending = Capture(
            image: image,
            extent: CGRect(x: 0, y: 0, width: captureRect.width, height: captureRect.height),
            oldBlockRect: oldBlockRect,
            scale: CGFloat(rep.pixelsWide) / max(1, captureRect.width)
        )
    }

    /// Runs the choreography for the settled post-flip geometry. Call AFTER
    /// the splice + pin (the animation itself starts on the next runloop
    /// turn, behind the pin's settle pass, so it converges on REAL
    /// geometry, never estimates).
    /// Overrides the system Reduce Motion setting; tests pin it (CI
    /// runners report Reduce Motion ON, which silently switches the plan).
    var reduceMotionOverride: Bool?

    func run(newBlockRect: CGRect, documentLength: Int) {
        guard let capture = pending else { return }
        pending = nil
        guard let scrollView else { return }
        let reduceMotion = reduceMotionOverride
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let plan = Self.plan(
            oldBlockHeight: capture.oldBlockRect.height,
            newBlockHeight: newBlockRect.height,
            viewportHeight: scrollView.contentView.bounds.height,
            reduceMotion: reduceMotion,
            documentLength: documentLength
        )
        guard plan != .none else { return }

        // Mount the cover NOW (same transaction as the splice — no naked
        // frame), animate on the next turn (after the settle pass).
        switch plan {
        case .none:
            return
        case .crossfade(let duration):
            guard let cover = makeSlice(capture: capture, sliceRect: CGRect(
                x: 0, y: 0,
                width: capture.extent.width,
                height: scrollView.contentView.bounds.height
            )) else { return }
            mount([cover])
            DispatchQueue.main.async { [weak self] in
                self?.fade(cover, duration: duration)
            }
        case .slices(let blockFade, let slide, let delta):
            let blockSlice = makeSlice(capture: capture, sliceRect: capture.oldBlockRect)
            let belowTop = capture.oldBlockRect.maxY
            let belowSlice = makeSlice(capture: capture, sliceRect: CGRect(
                x: 0, y: belowTop,
                width: capture.extent.width,
                height: capture.extent.height - belowTop
            ))
            let mounted = [blockSlice, belowSlice].compactMap { $0 }
            guard !mounted.isEmpty else { return }
            mount(mounted)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let blockSlice { self.fade(blockSlice, duration: blockFade) }
                if let belowSlice { self.slideAndRemove(belowSlice, by: delta, duration: slide) }
            }
        }

        // Unconditional epilogue: whatever happens, the cover comes off.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.cancel() }
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// True while a frozen cover is mounted — subordinate motion (the
    /// preview panel) must present directly under it; the cover owns the
    /// transition.
    var isCovering: Bool { container != nil }

    /// Truncate to the end state: remove every overlay immediately.
    func cancel() {
        pending = nil
        watchdog?.cancel()
        watchdog = nil
        for overlay in overlays { overlay.removeFromSuperview() }
        overlays.removeAll()
        container?.removeFromSuperview()
        container = nil
    }

    // MARK: - Overlay machinery

    /// A frozen-pixel slice, positioned over the same region it was
    /// captured from. `sliceRect` is in viewport coordinates.
    ///
    /// Displayed with NSImageView on a CGImage crop — deliberately NOT
    /// manual `layer.contents` + `contentsRect`: raw-contents orientation
    /// on macOS depends on the layer tree's flip state in ways that
    /// differed between a standalone probe and the real AppKit backing-
    /// layer tree (a mirrored overlay shipped twice during development —
    /// FlipTransitionFidelityTests holds the compositor-level regression
    /// net). CGImage cropping is raster-space (row 0 = capture top) and
    /// NSImageView displays upright in any hierarchy, flipped or not.
    private func makeSlice(capture: Capture, sliceRect: CGRect) -> NSView? {
        let clipped = sliceRect.intersection(capture.extent)
        guard !clipped.isEmpty, clipped.height >= 1 else { return nil }
        let scale = capture.scale
        guard let cropped = capture.image.cropping(to: CGRect(
            x: clipped.minX * scale,
            y: clipped.minY * scale,
            width: clipped.width * scale,
            height: clipped.height * scale
        )) else { return nil }

        let view = NSImageView(frame: clipped)
        view.image = NSImage(cgImage: cropped, size: clipped.size)
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        return view
    }

    private func mount(_ views: [NSView]) {
        guard let scrollView else { return }
        let container = OverlayContainer(frame: scrollView.contentView.frame)
        // Explicitly layer-backed: the slices ARE layers (contents +
        // contentsRect); without a backing layer on the host they simply
        // don't composite — layer-backing must never depend on what the
        // surrounding window happens to use.
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        for view in views { container.addSubview(view) }
        scrollView.addSubview(container)
        self.container = container
        overlays = views
    }

    private func removeOverlay(_ view: NSView) {
        view.removeFromSuperview()
        overlays.removeAll { $0 === view }
        if overlays.isEmpty {
            container?.removeFromSuperview()
            container = nil
            watchdog?.cancel()
            watchdog = nil
        }
    }

    private func fade(_ view: NSView, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak view] in
            MainActor.assumeIsolated {
                guard let self, let view else { return }
                self.removeOverlay(view)
            }
        })
    }

    private func slideAndRemove(_ view: NSView, by delta: CGFloat, duration: TimeInterval) {
        var target = view.frame
        target.origin.y += delta
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            // The brief's decelerating curve (0.2, 0.0, 0.0, 1.0): fast
            // out of the gate, settles asymptotically — text never
            // overshoots.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.0, 0.0, 1.0)
            view.animator().frame = target
        }, completionHandler: { [weak self, weak view] in
            MainActor.assumeIsolated {
                guard let self, let view else { return }
                self.removeOverlay(view)
            }
        })
    }
}
#endif
