import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A tab's scroll + selection, stashed when its editor is torn down (a tab
/// switch) and restored when the editor is rebuilt, so switching tabs returns
/// you to exactly where you were reading (#22). The owning model outlives the
/// view in `OpenDocumentStore`, so it holds this across the switch.
///
/// Platform-free by content (`CGFloat` + `NSRange` are Foundation/CoreGraphics),
/// it lives at the QuoinRender target root — not the `AppKit/` subfolder — so
/// the shared editing view-model (macOS + iOS) can own it without importing an
/// AppKit view (iOS-shell extraction, ADR 0010, Phase 1).
public struct ViewportSnapshot: Equatable, Sendable {
    public var scrollY: CGFloat
    public var selection: NSRange
    public init(scrollY: CGFloat, selection: NSRange) {
        self.scrollY = scrollY
        self.selection = selection
    }
}
