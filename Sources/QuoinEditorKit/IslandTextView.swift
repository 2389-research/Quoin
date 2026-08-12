#if canImport(AppKit)
import AppKit

/// Phase 3, Task 1: the `NSTextView` subclass hosted by `BlockEditorCell` — the
/// responder seam for the editable island.
///
/// Two responder-level behaviours flow through here (NOT delegate methods, so a
/// subclass does not clobber `BlockEditorCell`'s `ChangeForwarder` delegate):
///
/// - **Blur** (`resignFirstResponder`): fires `onResignFirstResponder` before
///   deferring to `super`, so the controller can flush + swap the row back to
///   read-only when the island loses first responder (a click outside it, or the
///   window handing first responder to another view).
/// - **Return / Backspace** (`doCommand(by:)`): routes `insertNewline:` and
///   `deleteBackward:` through the optional `onInsertNewline` / `onDeleteBackward`
///   hooks. A hook returning `true` CONSUMES the command (structural op handled
///   the keystroke — `super` is NOT called); a `nil` or `false` hook falls
///   through to native behaviour. Those two hooks are DECLARED now and wired in
///   Tasks 5/7 (Return-splits-block, Backspace-at-start-merges); for this task
///   they default `nil`, i.e. fully native newline/delete.
@MainActor
public final class IslandTextView: NSTextView {

    /// Fired when this text view is about to resign first responder (blur). The
    /// controller installs `{ [weak self] in self?.deactivate() }`.
    public var onResignFirstResponder: (() -> Void)?

    /// Return-key seam (Task 5). Return `true` to consume the newline (a
    /// structural op handled it); `nil`/`false` → native `insertNewline:`.
    public var onInsertNewline: (() -> Bool)?

    /// Backspace seam (Task 7). Return `true` to consume the delete (a structural
    /// op handled it); `nil`/`false` → native `deleteBackward:`.
    public var onDeleteBackward: (() -> Bool)?

    public override func resignFirstResponder() -> Bool {
        onResignFirstResponder?()
        return super.resignFirstResponder()
    }

    public override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSTextView.insertNewline(_:)):
            if onInsertNewline?() == true { return }   // consumed by a structural op
        case #selector(NSResponder.deleteBackward(_:)):
            if onDeleteBackward?() == true { return }  // consumed by a structural op
        default:
            break
        }
        super.doCommand(by: selector)
    }
}
#endif
