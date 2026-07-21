#if canImport(AppKit)
import AppKit

/// The side-by-side live preview for an open diagram/equation (ledger
/// #6b): a floating panel hosted INSIDE the text view at the editing
/// frame's right edge. Click-transparent — the caret and all editing
/// stay in the source; the panel is presentation only.
///
/// Presentation is PLAN-DRIVEN (`PreviewPanelChoreographer`); design and
/// motion per the three-expert synthesis (docs/design/embed-editing-ux.md
/// §6b refinement):
/// - The panel wears the diagram's own chrome (hairline stroke, radius 8)
///   — it IS the artifact, not a new UI element.
/// - The image scale LOCKS per session (steady frame: the node you're
///   watching must not drift as the bounding box changes per keystroke);
///   isolated size changes re-fit via the ghost dissolve.
/// - The paused badge is a capsule OVERLAY (bottom-trailing, fixed to the
///   panel corner) — it never steals image height; the artifact stays at
///   full opacity (a dimmed diagram reads as broken, and it isn't).
/// - The panel's entire motion vocabulary is DISSOLVE, ≤150ms; frame
///   changes always snap (the drawn frame chrome cannot animate — an
///   animated panel against snapped ink would tear).
final class PreviewPanelView: NSView {

    private let imageView = NSImageView()
    private let badge = NSView()
    private let badgeIcon = NSImageView()
    private let badgeLabel = NSTextField(labelWithString: "Preview paused")
    private var badgeVisible = false
    private var ghost: NSImageView?
    private var generation = 0
    /// Session-locked display scale (steady frame).
    private var lockedScale: CGFloat?
    /// The image size the `lockedScale` was fitted to. When a live edit grows
    /// (or shrinks) the diagram, the size changes and we must re-fit — otherwise
    /// the stale scale lets a widening diagram overflow the panel and clip.
    private var lastFittedImageSize: CGSize?

    static let interiorPadding: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        // Scale INTO the frame we compute (locked scale × native size,
        // same aspect): .scaleNone drew wide charts at native size and
        // the panel mask cropped them to confetti (field report).
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        addSubview(imageView)

        badge.wantsLayer = true
        badge.layer?.cornerRadius = 11
        badge.layer?.borderWidth = 0.5
        badgeIcon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Paused")
        badgeIcon.contentTintColor = .systemYellow
        badgeLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        badgeLabel.textColor = .secondaryLabelColor
        badge.addSubview(badgeIcon)
        badge.addSubview(badgeLabel)
        badge.isHidden = true
        badge.alphaValue = 0
        addSubview(badge)
        applyChromeColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    // Internal layout in top-origin coordinates, matching the host text view.
    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeColors()
    }

    private func applyChromeColors() {
        // Same clothes as the closed diagram's frame (theme hairline).
        layer?.borderColor = NSColor.separatorColor.cgColor
        badge.layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.85).cgColor
        badge.layer?.borderColor = NSColor.separatorColor.cgColor
    }

    /// Applies one choreographer plan. `frameBox` is the drawn editing
    /// frame in text-view coordinates. `suppressAnimation` covers Reduce
    /// Motion, a mounted flip cover (the cover owns the transition), and
    /// live scrolls.
    func apply(
        _ plan: PreviewPanelChoreographer.Plan,
        in frameBox: CGRect,
        panelWidth: CGFloat,
        statusMessage: String?,
        suppressAnimation: Bool
    ) {
        generation += 1
        let currentGeneration = generation

        if let image = plan.image, plan.treatment != .none {
            // Steady frame: lock the display scale on first presentation;
            // appear/dissolve swaps re-lock. ALSO re-lock when the image size
            // changed — a live edit that widens the diagram must re-fit, else it
            // overflows the panel at the stale scale and clips (#42).
            if lockedScale == nil || plan.treatment == .appear || plan.treatment == .dissolve
                || image.size != lastFittedImageSize {
                lockedScale = Self.fitScale(
                    for: image.size,
                    maxWidth: panelWidth - Self.interiorPadding * 2,
                    maxHeight: Self.maxImageHeight(frameBox: frameBox))
                lastFittedImageSize = image.size
            }
        }
        let target = Self.panelFrame(
            editingFrame: frameBox, panelWidth: panelWidth,
            imageSize: (plan.image ?? imageView.image)?.size ?? .zero,
            scale: lockedScale ?? 1)

        switch plan.treatment {
        case .none:
            // Tracking reposition only (reflow moved the frame): snap.
            if frame != target, imageView.image != nil {
                frame = target
                layoutContents()
            }
        case .appear:
            removeGhost()
            imageView.image = plan.image
            frame = target
            layoutContents()
            if suppressAnimation {
                alphaValue = 1
            } else {
                alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    animator().alphaValue = 1
                }
            }
        case .instant:
            removeGhost()
            imageView.image = plan.image
            frame = target
            layoutContents()
        case .dissolve:
            // Truth lands instantly; a ghost of the outgoing artifact
            // fades over it (isolated size change / resume-from-paused).
            removeGhost()
            let outgoing = imageView.image
            imageView.image = plan.image
            frame = target
            layoutContents()
            if !suppressAnimation, let outgoing {
                let ghostView = NSImageView(frame: bounds)
                ghostView.image = outgoing
                ghostView.imageScaling = .scaleProportionallyDown
                ghostView.imageAlignment = .alignTopLeft
                ghostView.wantsLayer = true
                addSubview(ghostView, positioned: .above, relativeTo: imageView)
                ghost = ghostView
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    ghostView.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    guard let self, self.generation == currentGeneration || true else { return }
                    if self.ghost === ghostView {
                        ghostView.removeFromSuperview()
                        self.ghost = nil
                    }
                })
                // Watchdog: a stuck ghost is the panel's stuck-cover.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.ghost === ghostView else { return }
                    ghostView.removeFromSuperview()
                    self.ghost = nil
                }
            }
        }

        setBadge(visible: plan.showsPausedBadge, suppressAnimation: suppressAnimation)
        badge.toolTip = statusMessage
        isHidden = false
    }

    /// Block closed (or breakpoint hide): instant — when a flip cover is
    /// up it carries the exit; without one, a lingering panel would float
    /// over the fresh inline artifact.
    func dismiss() {
        removeGhost()
        lockedScale = nil
        isHidden = true
    }

    private func removeGhost() {
        ghost?.removeFromSuperview()
        ghost = nil
    }

    private func setBadge(visible: Bool, suppressAnimation: Bool) {
        guard visible != badgeVisible else { return }
        badgeVisible = visible
        if visible {
            layoutBadge()
            badge.isHidden = false
            if suppressAnimation {
                badge.alphaValue = 1
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    badge.animator().alphaValue = 1
                }
            }
        } else {
            // Good news is instant.
            badge.isHidden = true
            badge.alphaValue = 0
        }
    }

    private func layoutContents() {
        guard let image = imageView.image else { return }
        let scale = lockedScale ?? 1
        let size = CGSize(width: image.size.width * scale,
                          height: image.size.height * scale)
        // Steady anchor: top-LEADING — the edge nearest the reading flow
        // holds still; growth extends away from the source column.
        imageView.frame = CGRect(
            x: Self.interiorPadding, y: Self.interiorPadding,
            width: size.width, height: size.height)
        if badgeVisible { layoutBadge() }
    }

    private func layoutBadge() {
        badgeLabel.sizeToFit()
        let iconSize: CGFloat = 12
        let width = 10 + iconSize + 5 + badgeLabel.frame.width + 10
        let height: CGFloat = 22
        // Fixed to the PANEL's corner (never the image's) so its position
        // is independent of artifact size.
        badge.frame = CGRect(
            x: bounds.width - width - 8,
            y: bounds.height - height - 8,
            width: width, height: height)
        badgeIcon.frame = CGRect(x: 10, y: (height - iconSize) / 2,
                                 width: iconSize, height: iconSize)
        badgeLabel.frame.origin = CGPoint(
            x: 10 + iconSize + 5,
            y: (height - badgeLabel.frame.height) / 2)
    }

    // MARK: - Pure geometry (unit-tested)

    static func maxImageHeight(frameBox: CGRect) -> CGFloat {
        max(24, frameBox.height - 26 - 10 - interiorPadding * 2)
    }

    static func fitScale(for size: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(1, maxWidth / size.width, maxHeight / size.height)
    }

    /// Where the panel sits for a given editing frame and artifact size.
    /// The trailing inset (4pt from the frame's drawn edge) plus the
    /// renderer's tail indent yields the specified 16pt gutter between
    /// the wrapped source and the panel's stroke.
    static func panelFrame(
        editingFrame: CGRect, panelWidth: CGFloat, imageSize: CGSize, scale: CGFloat
    ) -> CGRect {
        let chipClearance: CGFloat = 26
        let height = imageSize.height * scale + interiorPadding * 2
        let maxHeight = max(24, editingFrame.height - chipClearance - 10)
        return CGRect(
            x: editingFrame.maxX - panelWidth - 4,
            y: editingFrame.minY + chipClearance,
            width: panelWidth,
            height: min(max(24, height), maxHeight))
    }
}
#endif
