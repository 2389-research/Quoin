import Foundation

/// Re-anchors a task-checkbox toggle when the file shifted on disk between
/// the render the user clicked and the write.
///
/// A toggle is dispatched by a bare byte offset (`quoin-task://toggle?offset=N`),
/// which is only meaningful against the document that produced that render. If
/// disk moved under us, that offset can land on a *different* task marker and
/// silently toggle the wrong box. `TaskLocator` captures the intended task's
/// identity from the viewed document, then proves it still exists — uniquely —
/// in the fresh parse before the caller allows the write.
public enum TaskLocator {

    /// A task's identity, independent of byte position: the literal label
    /// text on the marker's line, plus its ordinal among all task markers in
    /// document order. Together these survive edits *elsewhere* in the file.
    public struct IntendedTask: Equatable, Sendable {
        public let label: String
        public let ordinal: Int

        public init(label: String, ordinal: Int) {
            self.label = label
            self.ordinal = ordinal
        }
    }

    /// Every task marker in the document, in source order, paired with the
    /// single-line label that follows it. Recurses into nested lists,
    /// blockquotes, and callouts so a checkbox buried in a quoted list is
    /// found too.
    static func tasks(in document: QuoinDocument) -> [(range: ByteRange, label: String)] {
        let bytes = Array(document.source.utf8)

        func label(after marker: ByteRange) -> String {
            let start = min(marker.upperBound, bytes.count)
            var end = start
            while end < bytes.count, bytes[end] != UInt8(ascii: "\n") { end += 1 }
            return String(decoding: bytes[start..<end], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
        }

        var out: [(range: ByteRange, label: String)] = []
        func walk(_ blocks: [Block]) {
            for block in blocks {
                switch block.kind {
                case let .list(items, _, _):
                    for item in items {
                        if let range = item.taskMarkerRange {
                            out.append((range, label(after: range)))
                        }
                        walk(item.blocks)
                    }
                case let .blockQuote(children):
                    walk(children)
                case let .callout(_, children):
                    walk(children)
                default:
                    break
                }
            }
        }
        walk(document.blocks)
        return out
    }

    /// Resolve the task the user actually clicked, from the document that
    /// produced that render. Returns `nil` when the offset matches no task
    /// marker — i.e. the click was already stale against its own render.
    public static func identify(offset: Int, in document: QuoinDocument) -> IntendedTask? {
        let all = tasks(in: document)
        guard let ordinal = all.firstIndex(where: { $0.range.offset == offset }) else {
            return nil
        }
        return IntendedTask(label: all[ordinal].label, ordinal: ordinal)
    }

    /// Re-anchor `intended` to a marker range in `fresh`. Deliberately
    /// conservative: it succeeds only when the intended task is provably
    /// present and unambiguous, so a shifted file never toggles the wrong box.
    ///
    /// - A single task shares the label → relocate (position moved, identity
    ///   intact — the common "someone inserted a task above" case).
    /// - Among several same-label tasks, exactly one also kept its ordinal →
    ///   relocate to it (duplicate labels pinned by position).
    /// - Otherwise (deleted, or ambiguous) → `nil`; the caller refuses.
    public static func relocate(_ intended: IntendedTask, in fresh: QuoinDocument) -> ByteRange? {
        let all = tasks(in: fresh)
        let sameLabel = all.enumerated().filter { $0.element.label == intended.label }
        if sameLabel.count == 1 {
            return sameLabel[0].element.range
        }
        let sameOrdinal = sameLabel.filter { $0.offset == intended.ordinal }
        if sameOrdinal.count == 1 {
            return sameOrdinal[0].element.range
        }
        return nil
    }
}
