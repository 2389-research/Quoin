import Foundation

/// A human-readable label for an undoable action, shown in the Edit menu as
/// "Undo Typing" / "Redo Move Block" (macOS HIG: the Undo/Redo items name the
/// action they will reverse). The value is the action noun only; the menu
/// prepends the localized "Undo "/"Redo " prefix.
///
/// Most edits carry no explicit intent and are classified from their SHAPE
/// (see ``inferred(replacementIsInsert:replacementCount:deletedCount:)``):
/// genuine single-character typing reads as `.typing`, everything else as the
/// generic `.edit`. Intentful commands (Move Block, Resolve Suggestion, Edit
/// Properties…) pass their name explicitly so the menu can be specific.
public enum UndoActionName: String, Sendable, Equatable, CaseIterable {
    case typing = "Typing"
    case edit = "Edit"
    case moveBlock = "Move Block"
    case duplicateBlock = "Duplicate Block"
    case deleteBlock = "Delete Block"
    case editTable = "Edit Table"
    case structure = "Formatting"
    case replace = "Replace"
    case append = "Append"
    case suggestion = "Resolve Suggestion"
    case bulkSuggestion = "Resolve All Suggestions"
    case comment = "Comment"
    case suggestedEdit = "Suggested Edit"
    case highlight = "Highlight"
    case properties = "Edit Properties"

    /// The noun shown after "Undo "/"Redo " in the menu.
    public var menuTitle: String { rawValue }

    /// The name for an edit that arrived with no explicit intent. A
    /// single-character insert or delete — the granularity a person types or
    /// backspaces at — reads as `.typing`; anything larger (a paste, a
    /// selection replacement, a multi-line splice) is a generic `.edit`.
    ///
    /// Whitespace is deliberately NOT special-cased here: pressing space is
    /// still "Typing", even though the undo COALESCER treats whitespace as a
    /// group boundary (that governs grouping granularity, not the name).
    public static func inferred(
        replacementIsInsert: Bool, replacementCount: Int, deletedCount: Int
    ) -> UndoActionName {
        let isSingleInsert = replacementIsInsert && replacementCount == 1 && deletedCount == 0
        let isSingleDelete = replacementCount == 0 && deletedCount == 1
        return (isSingleInsert || isSingleDelete) ? .typing : .edit
    }
}
