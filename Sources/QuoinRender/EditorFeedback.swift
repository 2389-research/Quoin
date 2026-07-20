import Foundation

/// The tiny device-feedback seam the editing view-model needs, decoupled from
/// AppKit's `NSSound` so the view-model can move platform-free (iOS-shell
/// extraction, ADR 0010, Phase 1). macOS supplies `NSSound.beep()`
/// (`SystemEditorFeedback`); iOS will supply a haptic or a no-op.
public protocol EditorFeedback: Sendable {
    /// A rejection cue — an edit that couldn't apply, an unsupported drop.
    func beep()
}
