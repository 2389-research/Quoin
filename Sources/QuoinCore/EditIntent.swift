import Foundation

/// How a single keystroke inside the active block's revealed source should be
/// applied. `ReaderCoordinator.shouldChangeTextIn` used to inline three
/// smart-pair branches (wrap / complete / type-over) plus a default, mixing
/// the *decision* with UTF-16→byte conversion and the text-system callback.
/// Classifying the keystroke into one pure value first keeps that method flat
/// and — because this type is platform-free and works purely in the active
/// source's UTF-16 space — makes the decision unit-testable without a text
/// view or an `NSTextStorage`.
///
/// All indices are UTF-16 offsets **relative to the active block's source
/// slice** (the same space `EditMapping` converts to bytes at the boundary).
public enum EditIntent: Equatable, Sendable {

    /// A pair delimiter typed over a non-empty selection wraps it
    /// (select `word`, press `*` → `*word*`). `range` is the selection;
    /// `text` is the wrapped replacement; `caret` lands just before the
    /// closing delimiter so continued typing stays inside the span.
    case wrapSelection(range: Range<Int>, text: String, caret: Int)

    /// An opening delimiter typed at an empty caret auto-closes the pair
    /// (press `*` → `**` with the caret between them). `range` is the empty
    /// affected range; `text` is the inserted pair; `caret` is inside it.
    case completePair(range: Range<Int>, text: String, caret: Int)

    /// A closing delimiter typed where its twin already sits steps over the
    /// existing character instead of doubling it. `range` covers that single
    /// existing closer, which is rewritten with itself to advance the caret.
    case typeOver(range: Range<Int>, closer: String)

    /// Everything else — a normal replacement (typing, paste, deletion) —
    /// applied as-is with default caret handling.
    case replace(range: Range<Int>, text: String)

    /// The uniform edit every case reduces to: the UTF-16 range to replace,
    /// the replacement text, and an optional caret offset **within `text`**
    /// (nil lets the caret fall at the natural end). The coordinator converts
    /// this triple to bytes once and hands it to the session — so the four
    /// cases above stay descriptive while the apply path stays single.
    public var edit: (range: Range<Int>, text: String, caret: Int?) {
        switch self {
        case let .wrapSelection(range, text, caret), let .completePair(range, text, caret):
            return (range, text, caret)
        case let .typeOver(range, closer):
            // Rewriting the closer with itself and landing the caret past it
            // is what "steps over" the existing delimiter.
            return (range, closer, closer.utf16.count)
        case let .replace(range, text):
            return (range, text, nil)
        }
    }

    /// Classifies a single keystroke in the active block's source.
    ///
    /// - Parameters:
    ///   - sourceText: the active block's raw markdown slice.
    ///   - range: the UTF-16 range the keystroke affects, relative to
    ///     `sourceText` (empty when it's a plain caret insertion).
    ///   - replacement: the text the keystroke would insert ("" for a
    ///     deletion, one character for a normal keypress, longer for a paste).
    ///
    /// The branches, in order (the originals from
    /// `ReaderCoordinator.shouldChangeTextIn`, now pure logic):
    ///
    ///  1. A single-character `replacement` over a **non-empty** `range` is a
    ///     wrap candidate (`SmartPairs.wrap`) → `.wrapSelection`.
    ///  2. A single-character `replacement` over an **empty** `range` is a
    ///     completion candidate (`SmartPairs.completion`): an empty `insert`
    ///     means the closer already sits at the caret → `.typeOver`; a
    ///     non-empty `insert` → `.completePair`.
    ///  3. Anything else → `.replace`. Smart pairs return nil inside code
    ///     context and for non-pair characters, so those fall through here.
    public static func classify(
        sourceText: String,
        range: Range<Int>,
        replacement: String
    ) -> EditIntent {
        let source = sourceText as NSString

        // Smart pairs only ever act on a single typed delimiter; a paste or a
        // deletion is always a plain replacement.
        if replacement.count == 1, let character = replacement.first {
            if range.isEmpty {
                // Empty caret: the keystroke may complete a pair or step over
                // an existing closer.
                if let completion = SmartPairs.completion(
                    typing: character, inText: sourceText, caretUTF16: range.lowerBound
                ) {
                    if completion.insert.isEmpty {
                        // Type-over: the closer already sits at the caret;
                        // rewrite that one character with itself.
                        let closerRange = range.lowerBound..<(range.lowerBound + 1)
                        let closer = source.substring(with: NSRange(location: range.lowerBound, length: 1))
                        return .typeOver(range: closerRange, closer: closer)
                    }
                    return .completePair(range: range, text: completion.insert, caret: completion.caretOffset)
                }
            } else {
                // Non-empty selection: the delimiter may wrap it.
                let selection = source.substring(with: NSRange(location: range.lowerBound, length: range.count))
                if let wrap = SmartPairs.wrap(
                    typing: character, selection: selection, inText: sourceText, selectionStartUTF16: range.lowerBound
                ) {
                    return .wrapSelection(range: range, text: wrap.insert, caret: wrap.caretOffset)
                }
            }
        }

        return .replace(range: range, text: replacement)
    }
}
