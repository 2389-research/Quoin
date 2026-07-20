#if canImport(AppKit)
import AppKit

/// The macOS `EditorFeedback`: the system beep. The platform implementation of
/// the seam declared in `EditorFeedback.swift` (ADR 0010).
public struct SystemEditorFeedback: EditorFeedback {
    public init() {}
    public func beep() { NSSound.beep() }
}
#endif
