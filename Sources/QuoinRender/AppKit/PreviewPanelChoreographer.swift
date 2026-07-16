#if canImport(AppKit)
import AppKit

/// The live preview panel's presentation brain (ledger #6b refinement):
/// a PURE decision table — injected clock, no timers, no views — that
/// turns the raw per-draw stream of (image, paused, revision) into calm,
/// Apple-grade presentation. Synthesized from the three-expert panel
/// (docs/design/embed-editing-ux.md §6b refinement):
///
/// - GOOD NEWS IS INSTANT: every successful render swaps in immediately.
///   The engine is ms-fast; latency IS the product, and the morphing
///   artifact is the feedback (Keynote-inspector class, not
///   Xcode-Previews class). Renders are never debounced.
/// - MOTION ONLY WHERE IT INFORMS: swaps inside typing cadence
///   (< `cadenceWindow` since the last swap) are hard cuts — crossfades
///   at typing speed smear and ghost. An ISOLATED swap whose size
///   changed, and the FIRST swap after a paused episode (the resume the
///   user must not blink-miss — change-blindness), dissolve via a ghost
///   of the outgoing image (120ms).
/// - BAD NEWS IS PATIENT: brokenness is admitted only after
///   `pausedGracePeriod` of TYPING IDLE while invalid — the grace timer
///   resets on every revision change, so mid-word transits through
///   invalid states never flash anything. Recovery clears the badge
///   synchronously with the fixing keystroke.
/// - DEDUPE: identical inputs produce `.none` — the panel re-evaluates on
///   every draw pass (caret blinks, scrolls), and none of that may touch
///   layers or layout.
struct PreviewPanelChoreographer {

    struct Input {
        let image: NSImage
        let paused: Bool
        /// The projection revision — advances with every edit; the paused
        /// grace timer keys typing-idle off it.
        let revision: Int
    }

    enum ImageTreatment: Equatable {
        /// Nothing changed — do not touch the view.
        case none
        /// First presentation after absence: fade the panel in (140ms),
        /// unless a flip cover owns the entrance.
        case appear
        /// Cadence or same-size swap: direct assignment, zero animation.
        case instant
        /// Isolated size-changed swap, or resume-from-paused: truth lands
        /// instantly; a ghost of the outgoing image fades out over it.
        case dissolve
    }

    struct Plan: Equatable {
        var treatment: ImageTreatment
        /// Whether the paused badge is visible after this plan.
        var showsPausedBadge: Bool
        /// The image to present (nil with `.none` when nothing changes).
        var image: NSImage?
        /// Ask the caller to re-evaluate after this many seconds (the
        /// badge decision is pending on idle time).
        var recheckAfter: TimeInterval?
    }

    /// Typing-idle required before admitting brokenness.
    var pausedGracePeriod: TimeInterval = 0.5
    /// Swaps closer together than this are typing cadence: hard cuts.
    var cadenceWindow: TimeInterval = 0.5
    /// Fitted-size delta below which an isolated swap still hard-cuts.
    var sizeDeltaThreshold: CGFloat = 6

    // Presented state.
    private var presentedImage: NSImage?
    private var lastSwapAt: TimeInterval = -.greatestFiniteMagnitude
    private var lastRevision: Int?
    private var idleInvalidSince: TimeInterval?
    private var badgeAdmitted = false

    /// The panel disappeared (block closed) — forget everything.
    mutating func reset() {
        presentedImage = nil
        lastSwapAt = -.greatestFiniteMagnitude
        lastRevision = nil
        idleInvalidSince = nil
        badgeAdmitted = false
    }

    mutating func plan(for input: Input, at now: TimeInterval) -> Plan {
        // Paused bookkeeping: the grace timer starts at the LAST keystroke
        // while invalid — every revision change resets it, so the badge
        // appears only when the user stops typing on broken source.
        var recheck: TimeInterval?
        var badge: Bool
        if input.paused {
            if input.revision != lastRevision || idleInvalidSince == nil {
                idleInvalidSince = now
            }
            let since = idleInvalidSince ?? now
            if now - since >= pausedGracePeriod {
                badge = true
            } else {
                badge = false
                recheck = pausedGracePeriod - (now - since)
            }
        } else {
            idleInvalidSince = nil
            badge = false
        }
        lastRevision = input.revision

        // Image swaps: instant compute, choreographed presentation.
        let treatment: ImageTreatment
        var image: NSImage?
        if presentedImage == nil {
            treatment = .appear
            image = input.image
            presentedImage = input.image
            lastSwapAt = now
        } else if input.image !== presentedImage {
            let resuming = badgeAdmitted && !input.paused
            let inCadence = now - lastSwapAt < cadenceWindow
            let previousSize = presentedImage?.size ?? .zero
            let sizeChanged =
                abs(input.image.size.width - previousSize.width) > sizeDeltaThreshold
                || abs(input.image.size.height - previousSize.height) > sizeDeltaThreshold
            if resuming {
                // The resume must be perceivable — a hard cut after a
                // paused episode is blink-missable.
                treatment = .dissolve
            } else if inCadence {
                treatment = .instant
            } else {
                treatment = sizeChanged ? .dissolve : .instant
            }
            image = input.image
            presentedImage = input.image
            lastSwapAt = now
        } else {
            treatment = .none
        }

        badgeAdmitted = badge
        return Plan(
            treatment: treatment,
            showsPausedBadge: badge,
            image: image,
            recheckAfter: recheck
        )
    }
}
#endif
