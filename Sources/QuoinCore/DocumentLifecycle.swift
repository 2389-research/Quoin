/// The document lifecycle's close-time decision, as a pure function of
/// authoritative state. Keeping this in one place is what makes discard and
/// final-flush provably mutually exclusive: a document is discarded (never
/// saved) ONLY when it is a scratch doc, effectively empty, and the last
/// reference — every other case keeps and saves. A backing file is deleted only
/// for that same discard case, so a delete can never race a live session or a
/// pending write to a real document.
public enum DocumentLifecycle {
    public struct CloseState: Equatable, Sendable {
        public let isScratch: Bool
        public let isEmpty: Bool
        public let isLastReference: Bool
        public init(isScratch: Bool, isEmpty: Bool, isLastReference: Bool) {
            self.isScratch = isScratch
            self.isEmpty = isEmpty
            self.isLastReference = isLastReference
        }
    }

    public enum CloseAction: Equatable, Sendable {
        /// Flush the document to disk, then tear down.
        case keepAndSave
        /// Tear down WITHOUT saving; the backing file is discarded.
        case discardWithoutSaving
        /// Tear down without saving, but keep the backing file (a non-last
        /// reference releasing — another session owns the save).
        case keepNoSave
    }

    public static func onClose(_ s: CloseState) -> CloseAction {
        // A non-last reference must NOT save — another owner still holds the
        // session and will save it (saving from a releasing non-owner would
        // race that owner's pending write). Keep the file, no save.
        guard s.isLastReference else { return .keepNoSave }
        if s.isScratch && s.isEmpty { return .discardWithoutSaving }
        return .keepAndSave
    }

    public static func shouldDeleteBackingFile(_ s: CloseState) -> Bool {
        onClose(s) == .discardWithoutSaving
    }
}
