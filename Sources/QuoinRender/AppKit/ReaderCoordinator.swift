#if canImport(AppKit)
import AppKit
import SwiftUI
import QuoinCore

// MARK: - Coordinator

/// The reader view's delegate and mutable state: text-storage splicing,
/// selection→activation routing, syntax-reveal restyling, format commands,
/// search highlighting, and scroll anchoring. Split from
/// MarkdownReaderView.swift for navigability; same type, same module.
extension MarkdownReaderView {

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownReaderView
        weak var textView: NSTextView?
        var renderedGeneration: NSAttributedString?
        /// Last `RenderedDocument.revision` applied to the live storage.
        /// updateNSView runs on every SwiftUI pass; this is what stops a
        /// patch-bearing projection from re-applying its patches.
        var appliedRevision = -1
        var blockRanges: [BlockID: NSRange] = [:] {
            didSet { blockRangeIndex = nil }
        }
        /// Sorted-ranges index over `blockRanges` (ledger perf #11): built
        /// lazily once per projection, binary-searched per query.
        /// `blockID(atCharIndex:)` and `topVisibleBlockID` were O(blocks)
        /// linear scans on every caret move and scroll tick — the scroll
        /// path even allocated a description string per key per query.
        private var blockRangeIndex: BlockRangeIndex?
        private var rangeIndex: BlockRangeIndex {
            if let blockRangeIndex { return blockRangeIndex }
            let built = BlockRangeIndex(blockRanges)
            blockRangeIndex = built
            return built
        }
        /// The active block id as of the last applied update — what lets a
        /// re-render recognize an activate/deactivate FLIP (chart ↔ source)
        /// and pin the flipped block on screen across the height change.
        var lastActiveBlockID: BlockID?
        var appliedScrollGeneration = 0
        var appliedFlashGeneration = 0
        var appliedAnnotationGeneration = 0
        /// The live compose popover (comment/replacement body input).
        var annotationPopover: NSPopover?
        /// The in-flight card→mark flash ring. Its frame is frozen at
        /// flash time and its removal rides a 1.8s animation completion,
        /// so a second flash must replace it (stacked rings) and editor
        /// teardown must remove it explicitly (a mid-fade ring outlives
        /// relayout as a stray outline — #72).
        weak var activeFlashRing: FlashRingView?
        var appliedQuery: String?
        var appliedOrdinal: Int = -1
        /// The options + In-Selection scope the current highlights were
        /// scanned under; a toggle change re-scans just like a query change.
        var appliedOptions = SearchOptions()
        var appliedInSelection = false
        var appliedCaretGeneration: Int = -1
        var appliedFormatGeneration: Int = 0
        var appliedEditSourceToggleGeneration: Int = 0
        /// One-shot initial focus claim (⌘N must be typeable immediately).
        var hasClaimedInitialFocus = false
        /// `isActiveTab` as of the last update with a window: lets a keep-alive
        /// editor recognize the moment it BECOMES the frontmost tab and claim
        /// first responder (stealing it from the tab switched away from).
        var wasActiveTab = false
        /// One-shot guard so a returning tab's saved scroll/selection is
        /// applied exactly once, on the first update of the rebuilt editor.
        var hasRestoredViewport = false
        var suppressSelectionCallback = false
        var scrollObserver: NSObjectProtocol?
        private var matchRanges: [NSRange] = []
        private var hasAppliedSearchHighlights = false
        private var lastReportedTopBlock: BlockID?

        /// Replaces only the changed span of `storage`, so a re-render doesn't
        /// re-lay-out the whole document. Compares the common prefix and suffix
        /// of the old and new strings and splices the differing middle. Returns
        /// the new range that was spliced, or nil when it fell back to a full
        /// replacement (empty storage, or nearly everything changed) — the
        /// caller re-anchors scroll only in that case.
        static func spliceChanges(in storage: NSTextStorage, to newAttr: NSAttributedString) -> NSRange? {
            let old = storage.string as NSString
            let new = newAttr.string as NSString
            let oldLen = old.length
            let newLen = new.length
            guard oldLen > 0 else {
                storage.setAttributedString(newAttr)
                return nil
            }

            // Chunked comparison via memcmp: per-character `character(at:)`
            // costs an ObjC message each (~24 ms across a novel), and a
            // Swift element loop pays per-index bounds checks in debug
            // builds. memcmp on getCharacters buffers is C-speed in any
            // build mode; only a differing chunk is scanned element-wise.
            let chunk = 8192
            var oldBuf = [unichar](repeating: 0, count: chunk)
            var newBuf = [unichar](repeating: 0, count: chunk)
            func chunksEqual(_ n: Int) -> Bool {
                // Both buffers are fixed `chunk`-sized (never empty), so
                // `baseAddress` is always non-nil here.
                oldBuf.withUnsafeBufferPointer { a in
                    newBuf.withUnsafeBufferPointer { b in
                        memcmp(a.baseAddress!, b.baseAddress!, n * MemoryLayout<unichar>.size) == 0
                    }
                }
            }
            let bound = min(oldLen, newLen)
            var prefix = 0
            outer: while prefix < bound {
                let n = min(chunk, bound - prefix)
                old.getCharacters(&oldBuf, range: NSRange(location: prefix, length: n))
                new.getCharacters(&newBuf, range: NSRange(location: prefix, length: n))
                if chunksEqual(n) { prefix += n; continue }
                for i in 0..<n where oldBuf[i] != newBuf[i] { prefix += i; break outer }
                prefix += n
            }
            var suffix = 0
            let suffixBound = bound - prefix
            outer2: while suffix < suffixBound {
                let n = min(chunk, suffixBound - suffix)
                old.getCharacters(&oldBuf, range: NSRange(location: oldLen - suffix - n, length: n))
                new.getCharacters(&newBuf, range: NSRange(location: newLen - suffix - n, length: n))
                if chunksEqual(n) { suffix += n; continue }
                for i in 0..<n where oldBuf[n - 1 - i] != newBuf[n - 1 - i] { suffix += i; break outer2 }
                suffix += n
            }

            let oldChanged = NSRange(location: prefix, length: oldLen - prefix - suffix)
            let newChangedLen = newLen - prefix - suffix

            // Identical STRINGS can still carry different ATTRIBUTES — a
            // plain paragraph's revealed source is the same characters as
            // its rendered text, differing only in the reveal tint and
            // fonts. A string-only splice would "change nothing" and leave
            // the old attributes behind (the shipped symptom: the reveal
            // highlight lingering on a block after clicking away). Sync
            // attribute runs in place — no text edit, so no layout jump.
            if oldChanged.length == 0, newChangedLen == 0 {
                return syncAttributesWhereDifferent(in: storage, to: newAttr)
            }

            // If most of the document changed, a single set is simpler and a
            // scroll re-anchor is warranted.
            if oldChanged.length + newChangedLen > (oldLen + newLen) * 3 / 4 {
                storage.setAttributedString(newAttr)
                return nil
            }

            let replacement = newAttr.attributedSubstring(
                from: NSRange(location: prefix, length: newChangedLen)
            )
            storage.beginEditing()
            storage.replaceCharacters(in: oldChanged, with: replacement)
            storage.endEditing()
            // The string splice bounds the TEXT change, but attributes can
            // differ far beyond it: a revealed callout's body is
            // string-identical to its rendered text (only the reveal tint
            // and chrome differ), and a re-rendered diagram is the same
            // U+FFFC attachment character carrying a NEW attachment. The
            // string-trimmed splice kept those characters with their stale
            // attributes — the shipped symptom family (ledger #4/#8):
            // callout boxes shrunk to their title line, reveal tint
            // stranded on neighbors, ✓ done frames surviving close, and
            // live previews that never updated. Sync attribute runs across
            // the whole document after the splice (walks runs, not
            // characters).
            _ = syncAttributesWhereDifferent(in: storage, to: newAttr)
            return NSRange(location: prefix, length: newChangedLen)
        }

        /// Replaces attribute runs wherever they differ between the storage
        /// and `newAttr` (same string in both, by precondition). Returns the
        /// union range of the synced runs, or a zero range when nothing
        /// differed — non-nil either way, so callers don't re-anchor scroll
        /// for what is at most an attribute repaint.
        ///
        /// The walk deliberately covers the WHOLE document (ledger perf
        /// #8). LEDGER: bounding it to (changed range ∪ active-block range)
        /// was evaluated and rejected as unsound — attribute diffs occur
        /// outside both: a re-rendered diagram is the same single U+FFFC
        /// character carrying a NEW attachment, string-invisible to the
        /// splice diff and outside any active block
        /// (ActivationNeighborIntegrityTests.testSpliceCarriesReplaced-
        /// AttachmentsAcross pins exactly that shipped bug). Instead the
        /// walk goes through the toll-free-bridged CF API: per-run Swift
        /// dictionary bridging was ~90% of the cost (measured ~110ms →
        /// ~11ms for a 66k-char document, identical diff detection);
        /// dictionaries bridge only for the rare runs that actually differ.
        private static func syncAttributesWhereDifferent(
            in storage: NSTextStorage, to newAttr: NSAttributedString
        ) -> NSRange {
            var synced: NSRange?
            var location = 0
            let length = newAttr.length
            let oldCF = storage as CFAttributedString
            let newCF = newAttr as CFAttributedString
            storage.beginEditing()
            while location < length {
                var newRunRange = CFRange()
                var oldRunRange = CFRange()
                let newDict = CFAttributedStringGetAttributes(newCF, location, &newRunRange)
                let oldDict = CFAttributedStringGetAttributes(oldCF, location, &oldRunRange)
                // Compare over the shared extent of the two runs.
                let step = min(newRunRange.location + newRunRange.length,
                               oldRunRange.location + oldRunRange.length) - location
                let differs: Bool
                if let newDict, let oldDict {
                    differs = !CFEqual(newDict, oldDict)
                } else {
                    differs = (newDict == nil) != (oldDict == nil)
                }
                if differs {
                    let range = NSRange(location: location, length: step)
                    let newAttrs = (newDict as NSDictionary?) as? [NSAttributedString.Key: Any]
                    storage.setAttributes(newAttrs ?? [:], range: range)
                    synced = synced.map { NSUnionRange($0, range) } ?? range
                }
                location += max(step, 1)
            }
            storage.endEditing()
            return synced ?? NSRange(location: 0, length: 0)
        }

        static func spliceChanges(
            in storage: NSTextStorage,
            to newAttr: NSAttributedString,
            hint: RenderSpliceHint?
        ) -> NSRange? {
            if let hint,
               hint.oldRange.location >= 0,
               hint.replacementRange.location >= 0,
               NSMaxRange(hint.oldRange) <= storage.length,
               NSMaxRange(hint.replacementRange) <= newAttr.length {
                let replacement = newAttr.attributedSubstring(from: hint.replacementRange)
                storage.beginEditing()
                storage.replaceCharacters(in: hint.oldRange, with: replacement)
                storage.endEditing()
                return hint.replacementRange
            }
            return spliceChanges(in: storage, to: newAttr)
        }

        static func applyStoragePatch(
            in storage: NSTextStorage,
            patch: RenderStoragePatch
        ) -> NSRange? {
            guard patch.oldRange.location >= 0,
                  NSMaxRange(patch.oldRange) <= storage.length
            else { return nil }
            storage.beginEditing()
            storage.replaceCharacters(in: patch.oldRange, with: patch.replacement)
            storage.endEditing()
            return NSRange(location: patch.oldRange.location, length: patch.replacement.length)
        }

        /// How a projection landed in the live storage: bounded patches, or
        /// a computed splice (which includes the resync fallback).
        enum ProjectionApplication {
            case patched([RenderStoragePatch])
            case spliced(NSRange?)
        }

        /// The pre-edit extent a projection application replaced, in OLD
        /// (pre-application) coordinates — what a pre-existing selection
        /// must be checked against. Patches carry their old ranges
        /// directly; a splice reports its new range, so the old extent is
        /// recovered from the length delta; a full replacement (nil splice)
        /// is everything.
        static func changedOldRange(
            for application: ProjectionApplication, oldLength: Int, newLength: Int
        ) -> NSRange? {
            switch application {
            case .patched(let patches):
                return patches.reduce(nil as NSRange?) { union, patch in
                    union.map { NSUnionRange($0, patch.oldRange) } ?? patch.oldRange
                }
            case .spliced(let newRange):
                guard let newRange else {
                    return NSRange(location: 0, length: oldLength)
                }
                let oldEnd = oldLength - (newLength - NSMaxRange(newRange))
                return NSRange(location: newRange.location,
                               length: max(0, oldEnd - newRange.location))
            }
        }

        /// Where a RANGE selection goes when a projection changes the text
        /// under it: nil when the selection is clear of the change and
        /// survives as-is; otherwise a zero-length caret at its start —
        /// AppKit would clamp the stale indexes into whatever content the
        /// splice put there, which read as a random selection. Zero-length
        /// changes (pure insertions) invalidate only when they land
        /// strictly inside the selection.
        static func collapsedSelection(
            _ selection: NSRange, changedOldRange: NSRange?, newLength: Int
        ) -> NSRange? {
            guard selection.length > 0, let changed = changedOldRange else { return nil }
            let intersects: Bool
            if changed.length > 0 {
                intersects = NSIntersectionRange(selection, changed).length > 0
            } else {
                intersects = changed.location > selection.location
                    && changed.location < NSMaxRange(selection)
            }
            guard intersects else { return nil }
            return NSRange(location: min(selection.location, newLength), length: 0)
        }

        /// Applies a published projection to the live storage. Patches are
        /// trusted ONLY when the storage is exactly the state they were
        /// computed against (`patchBaseLength`): SwiftUI coalesces rapid
        /// publishes, so a view can skip an intermediate patch revision —
        /// applying the next batch to that stale storage would silently
        /// corrupt the projection (the caret mapping drifts and keystrokes
        /// near the block end fall outside the editable range and get
        /// swallowed). Any mismatch falls back to a full splice against
        /// `attributed`, which the model keeps authoritative — one O(scan)
        /// resync instead of compounding corruption.
        static func applyProjection(
            _ rendered: RenderedDocument, to storage: NSTextStorage
        ) -> ProjectionApplication {
            if !rendered.storagePatches.isEmpty,
               rendered.patchBaseLength == storage.length,
               rendered.storagePatches.allSatisfy({
                   $0.oldRange.location >= 0 && NSMaxRange($0.oldRange) <= storage.length
               }) {
                for patch in rendered.storagePatches {
                    _ = applyStoragePatch(in: storage, patch: patch)
                }
                return .patched(rendered.storagePatches)
            }
            return .spliced(spliceChanges(in: storage, to: rendered.attributed, hint: rendered.spliceHint))
        }

        init(parent: MarkdownReaderView) {
            self.parent = parent
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        func reportTopBlock() {
            guard let textView else { return }
            // Focus dimming is viewport-culled; scrolling paints the newly
            // exposed blocks (no-op while the viewport stays inside the
            // already-painted extent).
            extendFocusDimmingIntoViewport(in: textView)
            // Reading progress (idea #12): scroll fraction of the document.
            if let onScrollProgress = parent.onScrollProgress,
               let clip = textView.enclosingScrollView?.contentView {
                let scrollable = max(1, textView.bounds.height - clip.bounds.height)
                let fraction = min(1, max(0, clip.bounds.origin.y / scrollable))
                if abs(fraction - lastReportedProgress) > 0.002 {
                    lastReportedProgress = fraction
                    onScrollProgress(fraction)
                }
            }
            let top = topVisibleBlockID(in: textView)
            guard top != lastReportedTopBlock else { return }
            lastReportedTopBlock = top
            parent.onTopBlockChange(top)
        }
        private var lastReportedProgress: Double = -1

        // MARK: Links & checkboxes

        public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = linkURL(from: link) else { return false }
            if let offset = QuoinLink.markerOffset(from: url) {
                parent.onTaskToggle(offset)
                return true
            }
            if QuoinLink.isCopyURL(url) {
                if let storage = textView.textContentStorage?.textStorage,
                   charIndex < storage.length,
                   let code = storage.attribute(QuoinAttribute.copySource, at: charIndex, effectiveRange: nil) as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                return true
            }
            if QuoinLink.isReviewURL(url) {
                parent.onOpenReview?()
                return true
            }
            if QuoinLink.isEditURL(url) {
                // ‹/› edit opens the enclosing block's source (caret at the
                // body start); ✓ done on the open block commits and closes,
                // caret restored at its rendered image.
                if let id = blockID(atCharIndex: charIndex) {
                    if id == parent.rendered.activeBlockID {
                        captureDeactivationCaret(in: textView)
                        parent.onActivateBlock?(nil, nil, nil)
                    } else {
                        // The chip run has no body mapping, and a nil hint
                        // parks the caret at the source END — for a tall
                        // diagram the caret-line pin then anchored the LAST
                        // source line at the chip's Y and scrolled the whole
                        // reveal out of view (live report, 2026-07-15). The
                        // chip means "edit this" — start at the top.
                        let hint: CaretHint = embedCaretHint(atCharIndex: charIndex)
                            .map { .source($0) } ?? .source(0)
                        parent.onActivateBlock?(id, hint, nil)
                    }
                }
                return true
            }
            if let slug = QuoinLink.anchorSlug(from: url) {
                if let blockID = parent.anchorResolver(slug), let range = blockRanges[blockID] {
                    // Record where we were — ⌘[ brings the reader back.
                    parent.onAnchorJump?(topVisibleBlockID(in: textView))
                    scrollBlockToTop(range, in: textView)
                }
                return true
            }
            if let id = QuoinLink.footnoteID(from: url) {
                // A [^id] reference: jump to its definition at the document
                // tail. Definitions live in the SAME attributed string, so
                // the target is a tagged-range lookup, not a resolver call.
                if let range = footnoteRun(id: id, tag: QuoinAttribute.footnoteDefinitionID, in: textView) {
                    parent.onAnchorJump?(topVisibleBlockID(in: textView))
                    scrollBlockToTop(range, in: textView)
                }
                return true
            }
            if let id = QuoinLink.footnoteBackID(from: url) {
                // A definition's ↩: return to the FIRST reference. Scroll
                // its enclosing block (a superscript's own rect is a sliver);
                // the tagged run is the fallback if the block map is stale.
                if let reference = footnoteRun(id: id, tag: QuoinAttribute.footnoteID, in: textView) {
                    parent.onAnchorJump?(topVisibleBlockID(in: textView))
                    if let blockID = blockID(atCharIndex: reference.location),
                       let blockRange = blockRanges[blockID] {
                        scrollBlockToTop(blockRange, in: textView)
                    } else {
                        scrollBlockToTop(reference, in: textView)
                    }
                }
                return true
            }
            return false // system handles web links
        }

        private func linkURL(from link: Any) -> URL? {
            if let url = link as? URL { return url }
            if let string = link as? String { return URL(string: string) }
            return nil
        }

        /// The FIRST run tagged `tag == id` in document order — for
        /// `footnoteID` that is the footnote's first reference (the ↩
        /// backlink's contract), for `footnoteDefinitionID` the definition
        /// (each id has exactly one).
        private func footnoteRun(
            id: String, tag: NSAttributedString.Key, in textView: NSTextView
        ) -> NSRange? {
            guard let storage = textView.textContentStorage?.textStorage else { return nil }
            var found: NSRange?
            storage.enumerateAttribute(
                tag, in: NSRange(location: 0, length: storage.length)
            ) { value, range, stop in
                if value as? String == id {
                    found = range
                    stop.pointee = true
                }
            }
            return found
        }

        // MARK: Editing

        // MARK: Edit-echo serialization (ledger #11)

        /// An editor command that arrived while an edit round-trip was
        /// still un-acked. Its POSITION cannot be trusted (the projection
        /// under the caret is about to move), but its CONTENT and ORDER
        /// can — sequential input happens at one conceptual caret/selection.
        /// Queued commands flush one edit per echo, each computed against
        /// the freshly restored selection. Format commands and smart paste
        /// queue here too (ledger #9): they compute ranges from the live
        /// selection exactly like keystrokes do, and ⌘B one frame after a
        /// fast keystroke used to wrap a stale range.
        enum PendingEditorCommand {
            case keystroke(deleteBackward: Bool, insert: String)
            case format(FormatCommand)
            /// The pasteboard string captured at paste time — the
            /// pasteboard itself could change before the flush.
            case smartPaste(String)
        }
        private var pendingCommands: [PendingEditorCommand] = []
        /// True from sending an edit until its projection echo restores
        /// the caret. Fast typing used to compute the NEXT keystroke's
        /// range against the stale projection — characters landed at old
        /// offsets, scrambling into neighboring text (field report:
        /// "edits swallowed in the source, persisted forever in the
        /// chart" — the chart rendered the true, scrambled document).
        private var awaitingEditEcho = false
        /// Internal (not private) so the watchdog tests can age it past
        /// the deadline without a real 2-second wait.
        var awaitingEditEchoSince: TimeInterval = 0
        /// How long a sent edit may go un-acked before the gate assumes
        /// the echo was lost and replays the queue (ledger #8).
        static let editEchoWatchdogInterval: TimeInterval = 2

        private var editEchoWatchdogExpired: Bool {
            ProcessInfo.processInfo.systemUptime - awaitingEditEchoSince
                > Self.editEchoWatchdogInterval
        }

        private func beginAwaitingEditEcho() {
            awaitingEditEcho = true
            awaitingEditEchoSince = ProcessInfo.processInfo.systemUptime
        }

        /// The projection echo landed (caret restored) — release the
        /// queue. Also the failure path's re-entry point: a rejected
        /// session edit republishes the fresh truth as an echo, and the
        /// queued commands REPLAY against it here (ledger #8) — they are
        /// content + order, applied at the freshly restored caret, so no
        /// stale offset ever splices.
        func noteEditEchoApplied(in textView: NSTextView) {
            awaitingEditEcho = false
            flushPendingCommands(in: textView)
        }

        /// Flushes queued commands, in order, until one sends an edit
        /// (re-arming the echo gate) or the queue drains. Each command
        /// re-enters its ordinary pipeline at the CURRENT caret/selection.
        private func flushPendingCommands(in textView: NSTextView) {
            while !awaitingEditEcho, !pendingCommands.isEmpty {
                let next = pendingCommands.removeFirst()
                switch next {
                case .keystroke(let deleteBackward, let insert):
                    let caret = textView.selectedRange().location
                    if deleteBackward {
                        guard caret > 0 else { continue }
                        _ = self.textView(
                            textView,
                            shouldChangeTextIn: NSRange(location: caret - 1, length: 1),
                            replacementString: "")
                    } else {
                        _ = self.textView(
                            textView,
                            shouldChangeTextIn: NSRange(location: caret, length: 0),
                            replacementString: insert)
                    }
                case .format(let command):
                    applyFormat(command, in: textView)
                case .smartPaste(let pasted):
                    if !applySmartPaste(pasted, in: textView) {
                        // Not a smart shape against the fresh selection —
                        // paste means "insert the text" at minimum.
                        _ = self.textView(
                            textView,
                            shouldChangeTextIn: textView.selectedRange(),
                            replacementString: pasted)
                    }
                }
            }
        }

        /// Activation changes invalidate queued positions entirely.
        func clearPendingKeystrokes() {
            pendingCommands.removeAll()
            awaitingEditEcho = false
        }

        /// Every keystroke lands here. Inside the active block's revealed
        /// source it becomes a relative byte-range edit for the session;
        /// anywhere else it activates the block under the caret instead.
        /// Always returns false — the text storage is a projection and is
        /// only ever replaced wholesale by a re-render.
        public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let onEdit = parent.onEditIntent else { return false }

            // An edit is still in flight: the projection (and every range
            // derived from it) is about to move. Queue simple typing
            // shapes instead of applying them against stale coordinates.
            if awaitingEditEcho, parent.rendered.activeEditableRange != nil {
                let simpleInsert = affectedCharRange.length == 0
                    && replacementString?.isEmpty == false
                let simpleBackspace = affectedCharRange.length == 1
                    && (replacementString ?? "").isEmpty
                if editEchoWatchdogExpired {
                    // Watchdog: a lost echo must never wedge typing — and
                    // it must never DISCARD what was typed either (ledger
                    // #8). Unwedge and REPLAY: queued keystrokes flush at
                    // the current caret through the normal path, with the
                    // current keystroke joining the queue in order.
                    awaitingEditEcho = false
                    if simpleInsert {
                        pendingCommands.append(
                            .keystroke(deleteBackward: false, insert: replacementString ?? ""))
                        flushPendingCommands(in: textView)
                        return false
                    } else if simpleBackspace {
                        pendingCommands.append(.keystroke(deleteBackward: true, insert: ""))
                        flushPendingCommands(in: textView)
                        return false
                    } else if !pendingCommands.isEmpty {
                        // A complex edit (drag, cut of a range) has no
                        // defined caret to replay at. Replay the queued
                        // typing, refuse the complex edit audibly — never
                        // silently.
                        flushPendingCommands(in: textView)
                        NSSound.beep()
                        return false
                    }
                    // No queue and a complex edit: fall through and apply
                    // it against the current state (the echo is lost; the
                    // projection is the best truth available).
                } else if simpleInsert {
                    pendingCommands.append(
                        .keystroke(deleteBackward: false, insert: replacementString ?? ""))
                    return false
                } else if simpleBackspace {
                    pendingCommands.append(.keystroke(deleteBackward: true, insert: ""))
                    return false
                } else {
                    // A complex edit mid-flight (drag, cut of a range):
                    // rare — drop the queue rather than misorder it.
                    pendingCommands.removeAll()
                }
            }

            if let active = parent.rendered.activeEditableRange,
               let sourceText = parent.rendered.activeSourceText,
               affectedCharRange.location >= active.location,
               affectedCharRange.location + affectedCharRange.length <= active.location + active.length {
                let relStart = affectedCharRange.location - active.location
                let relRange = relStart..<(relStart + affectedCharRange.length)

                // Classify the keystroke (smart-pair wrap / complete /
                // type-over, or a plain replacement) as one pure intent, then
                // apply its single uniform edit: UTF-16 range → bytes, caret
                // offset within the replacement → bytes.
                let intent = EditIntent.classify(
                    sourceText: sourceText, range: relRange, replacement: replacementString ?? ""
                )
                let (utf16Range, text, caret) = intent.edit
                guard let byteRange = EditMapping.utf8Range(inText: sourceText, utf16Range: utf16Range) else {
                    // A nil mapping would drop the keystroke silently — the
                    // "input vanished" class we treat as the worst editor
                    // failure. Refuse audibly and leave a trace, never mute.
                    NSSound.beep()
                    QuoinPerformanceTrace.log(
                        "edit.mapping.failed",
                        startedAt: DispatchTime.now().uptimeNanoseconds,
                        metadata: "utf16=\(utf16Range) sourceUTF16=\(sourceText.utf16.count)")
                    return false
                }
                let caretDelta = caret.flatMap { EditMapping.utf8Offset(inText: text, utf16Offset: $0) }
                onEdit(byteRange, text, caretDelta)
                beginAwaitingEditEcho()
                return false
            }

            // Keystroke outside the revealed region: open that block at the
            // keystroke's position — and REPLAY the keystroke there. Typing
            // on a rendered block must reveal the source AND insert the
            // character (dropping it was the editor's worst mode error: the
            // flip looked like feedback, but the input was gone). Embed
            // blocks (code/table/…) map through the 1:1 body tag; plain
            // prose uses the rendered offset. Deletes and range replacements
            // just activate — their extent has no defined image in the
            // still-hidden source.
            // Presentation objects (diagrams, equations) never open from a
            // stray keystroke — chip/⌘↩/menu only (ledger #7).
            if isChipOnlyEmbed(atCharIndex: affectedCharRange.location) {
                return false
            }
            if let id = blockID(atCharIndex: affectedCharRange.location) {
                let hint = caretHint(forActivationAt: affectedCharRange.location, blockID: id)
                let insertion = (affectedCharRange.length == 0 && replacementString?.isEmpty == false)
                    ? replacementString : nil
                parent.onActivateBlock?(id, hint, insertion)
            } else if blockRanges.isEmpty,
                      let replacementString, !replacementString.isEmpty {
                // A brand-new EMPTY document has no blocks to activate —
                // this was the ⌘N black hole: a blank pane where every
                // keystroke silently vanished (launch audit BLOCKER #1).
                parent.onEmptyDocumentInsert?(replacementString)
            }
            return false
        }

        /// A zero-length click inside a non-active block activates it
        /// (the syntax-reveal trigger). Range selections stay read-only so
        /// copying across blocks keeps working.
        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !suppressSelectionCallback,
                  parent.onActivateBlock != nil,
                  let textView else { return }
            let selection = textView.selectedRange()

            // Find bar In-Selection replace scopes to the selection's source
            // byte range; report it as the selection moves (nil when empty).
            if let report = parent.onSelectionSourceRange {
                report(selectionSourceRange(selection, in: textView))
            }

            // Focus mode follows the caret across blocks.
            refreshFocusDimmingOnSelectionChange(in: textView)
            // Review panel linkage: caret-in-mark highlights its card.
            reportSuggestionCaretLink(in: textView)

            // Span-level syntax reveal: as the caret moves inside the
            // active block, re-style it so only the caret's span shows its
            // delimiters. Attribute-only pass; the text never changes.
            if selection.length == 0,
               let active = parent.rendered.activeEditableRange,
               selection.location >= active.location,
               selection.location <= active.location + active.length {
                let relativeCaret = selection.location - active.location
                if relativeCaret != lastStyledCaret {
                    lastStyledCaret = relativeCaret
                    restyleActiveBlock(caretAt: relativeCaret, in: textView)
                    // Keep the host's caret copy fresh (editor-modes plan,
                    // 0.4): a model-initiated re-render mid-edit must style
                    // the reveal at the caret's REAL position, not the one
                    // captured at activation.
                    parent.onActiveCaretMoved?(relativeCaret)
                }
            }
            // Images: clicking the attachment (length-1 selection) opens
            // its source. Embed blocks (code/math/mermaid/table) are handled
            // by double-click in QuoinTextView, not here — a single click on
            // one just places the caret so it can be admired or selected.
            if selection.length == 1,
               let storage = textView.textContentStorage?.textStorage,
               selection.location < storage.length,
               storage.attribute(.attachment, at: selection.location, effectiveRange: nil) != nil,
               !isEmbedBlock(atCharIndex: selection.location) {
                if let id = blockID(atCharIndex: selection.location),
                   id != parent.rendered.activeBlockID {
                    parent.onActivateBlock?(id, nil, nil)
                }
                return
            }
            guard selection.length == 0 else { return }
            // Single click on an embed block places the caret only.
            guard !isEmbedBlock(atCharIndex: selection.location) else { return }
            guard let id = blockID(atCharIndex: selection.location) else { return }
            if id != parent.rendered.activeBlockID {
                // Land the caret where the click fell, not at the block end.
                let hint = blockRanges[id].map { CaretHint.rendered(selection.location - $0.location) }
                parent.onActivateBlock?(id, hint, nil)
            }
        }

        /// Maps a projection selection to its footprint in the document
        /// SOURCE bytes, so In-Selection replace can scope to it. Each
        /// endpoint is mapped inside the block that holds it (rendered→source
        /// via `EditMapping`), then offset by that block's absolute source
        /// range. Returns nil for an empty or unmappable selection — the find
        /// bar then treats In-Selection replace as "select text first",
        /// never a whole-document replace.
        private func selectionSourceRange(_ selection: NSRange, in textView: NSTextView) -> ByteRange? {
            guard selection.length > 0,
                  let storage = textView.textContentStorage?.textStorage else { return nil }
            let text = storage.string as NSString
            func sourceByte(atCharIndex index: Int, blockProbe: Int) -> Int? {
                let probe = min(max(0, blockProbe), max(0, text.length - 1))
                guard let id = blockID(atCharIndex: probe),
                      let blockRange = blockRanges[id],
                      let blockSource = parent.blockSourceProvider?(id),
                      let blockByteRange = parent.blockSourceRangeProvider?(id)
                else { return nil }
                let clampedRange = NSIntersectionRange(
                    blockRange, NSRange(location: 0, length: text.length))
                guard clampedRange.length == blockRange.length else { return nil }
                let renderedSlice = text.substring(with: blockRange)
                let relRendered = min(max(0, index - blockRange.location), blockRange.length)
                let relSourceUTF16 = EditMapping.sourceOffset(
                    forRenderedOffset: relRendered, renderedText: renderedSlice, sourceText: blockSource)
                guard let relSourceByte = EditMapping.utf8Offset(
                    inText: blockSource, utf16Offset: relSourceUTF16) else { return nil }
                return blockByteRange.offset + min(relSourceByte, blockByteRange.length)
            }
            // The end maps within the block holding the LAST selected
            // character, so a selection ending at a block boundary does not
            // spill into the next block.
            guard let lo = sourceByte(atCharIndex: selection.location, blockProbe: selection.location),
                  let hi = sourceByte(
                    atCharIndex: NSMaxRange(selection),
                    blockProbe: max(selection.location, NSMaxRange(selection) - 1)),
                  hi > lo
            else { return nil }
            return ByteRange(offset: lo, length: hi - lo)
        }

        private var lastStyledCaret = -1

        /// Re-applies the active block's source styling for a new caret
        /// position. Same characters, new attributes — selection, undo
        /// state, and the 1:1 edit mapping are untouched.
        private func restyleActiveBlock(caretAt relativeCaret: Int, in textView: NSTextView) {
            guard let active = parent.rendered.activeEditableRange,
                  let source = parent.rendered.activeSourceText,
                  let storage = textView.textContentStorage?.textStorage,
                  active.location + active.length <= storage.length
            else { return }
            // Phase 3.3 done RIGHT: the restyle consumes the SAME fragment
            // pipeline the reveal used — styler config AND fallback metrics
            // AND paragraph transplant. A bare styler pass (even with the
            // carried config) lost everything applied AFTER the styler:
            // revealed code flipped mono→proportional on the first caret
            // click, because the mono font comes from applyFallbackMetrics,
            // not the styler (screenshots 2026-07-14).
            let styled: NSAttributedString
            if let fragment = parent.activeFragmentProvider?(relativeCaret) {
                styled = fragment
            } else {
                let config = parent.rendered.revealStyler ?? .prose
                var styler = MarkdownSourceStyler(theme: parent.theme)
                styler.collapsesNonLiteralSpans = config.collapsesNonLiteralSpans
                styler.treatsSourceAsVerbatimCode = config.treatsSourceAsVerbatimCode
                styled = styler.style(source, caretOffset: relativeCaret)
            }
            guard styled.length == active.length else { return }

            let blockID = storage.attribute(QuoinAttribute.blockID, at: active.location, effectiveRange: nil)
            storage.beginEditing()
            styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attrs, range, _ in
                var merged = attrs
                if let blockID { merged[QuoinAttribute.blockID] = blockID }
                let target = NSRange(location: active.location + range.location, length: range.length)
                // Keep the storage's paragraph styles: the revealed fragment
                // carries the block's outer spacing (heading spacing-above,
                // trailing paragraph gap), which the bare styler pass lacks —
                // overwriting it here made the block's height collapse on the
                // first caret move after activation.
                if let existingStyle = storage.attribute(.paragraphStyle, at: target.location, effectiveRange: nil) {
                    merged[.paragraphStyle] = existingStyle
                }
                // Keep the editing-frame decoration too: the bare styler
                // pass knows nothing of block chrome, and dropping it on
                // the first caret move made the ✓ done chip flicker away.
                if let decoration = storage.attribute(QuoinAttribute.blockDecoration, at: target.location, effectiveRange: nil) {
                    merged[QuoinAttribute.blockDecoration] = decoration
                }
                storage.setAttributes(merged, range: target)
            }
            storage.endEditing()
            // Delimiter fonts flip between 1pt and full size — a reflow —
            // so block chrome below the caret must redraw in place. The run
            // RANGES are untouched (attribute-only restyle), so this is a
            // redraw, not a rescan.
            (textView as? QuoinTextView)?.redrawDecorations()
        }

        /// Applies a format command to the selection inside the active
        /// block's revealed source.
        func applyFormat(_ command: FormatCommand, in textView: NSTextView) {
            guard let onEdit = parent.onEditIntent,
                  let active = parent.rendered.activeEditableRange,
                  let sourceText = parent.rendered.activeSourceText
            else { return }
            // ⌘B one frame after a fast keystroke used to wrap a STALE
            // range (ledger #9): while an edit round-trip is un-acked the
            // selection can't be trusted — join the queue like typing does.
            if awaitingEditEcho {
                pendingCommands.append(.format(command))
                return
            }
            var selection = textView.selectedRange()
            guard selection.location >= active.location,
                  selection.location + selection.length <= active.location + active.length
            else { return }

            // No selection: format the word under the caret (⌘B on a word
            // with no drag-select). Links still need an explicit selection.
            if selection.length == 0, command != .link,
               let word = Formatting.wordRange(in: sourceText, around: selection.location - active.location) {
                selection = NSRange(location: active.location + word.offset, length: word.length)
            }

            let relStart = selection.location - active.location
            let relRange = relStart..<(relStart + selection.length)
            guard let byteRange = EditMapping.utf8Range(inText: sourceText, utf16Range: relRange) else { return }
            let selected = (sourceText as NSString).substring(
                with: NSRange(location: relStart, length: selection.length)
            )

            let change: Formatting.Change
            switch command {
            case .bold: change = Formatting.toggleWrap(selection: selected, delimiter: "**")
            case .italic: change = Formatting.toggleWrap(selection: selected, delimiter: "*")
            case .strikethrough: change = Formatting.toggleWrap(selection: selected, delimiter: "~~")
            case .code: change = Formatting.toggleWrap(selection: selected, delimiter: "`")
            case .highlight: change = Formatting.cycleHighlight(selection: selected)
            case .link: change = Formatting.makeLink(selection: selected)
            }
            let caretDelta = EditMapping.utf8Offset(
                inText: change.replacement,
                utf16Offset: change.selectionOffset + change.selectionLength
            )
            onEdit(byteRange, change.replacement, caretDelta)
            // A format edit's round-trip moves the projection exactly like
            // a keystroke's — subsequent input must queue behind it.
            beginAwaitingEditEcho()
        }

        /// Set when a deactivation should land the caret at the rendered
        /// image of its source position (Escape today; ⌘↩/Done later).
        /// Captured BEFORE the flip-back is requested — the projection that
        /// replaces the revealed source arrives asynchronously in
        /// updateNSView, which consumes this. Without it the flip-back left
        /// whatever stale selection the storage splice produced.
        var pendingDeactivationCaret: (id: BlockID, sourceOffset: Int, sourceText: String)?

        /// Records the current caret (relative to the active block's source)
        /// so the imminent flip-back can restore it in rendered coordinates.
        func captureDeactivationCaret(in textView: NSTextView) {
            guard let closingID = parent.rendered.activeBlockID,
                  let active = parent.rendered.activeEditableRange,
                  let source = parent.rendered.activeSourceText
            else { return }
            let relative = min(max(0, textView.selectedRange().location - active.location), active.length)
            pendingDeactivationCaret = (closingID, relative, source)
        }

        /// Absolute storage location for the caret after a flip-back.
        /// Embed read fragments tag their body 1:1 with the source content
        /// (`embedSourceStart`) — the exact inverse of `embedCaretHint` —
        /// so those map arithmetically; everything else goes through the
        /// generic source→rendered alignment walk.
        func flipBackCaretLocation(
            blockRange: NSRange, storage: NSTextStorage, sourceOffset: Int, sourceText: String
        ) -> Int {
            var contentStart: Int?
            var bodyRange: NSRange?
            let clamped = NSRange(
                location: blockRange.location,
                length: min(blockRange.length, storage.length - blockRange.location)
            )
            storage.enumerateAttribute(QuoinAttribute.embedSourceStart, in: clamped) { value, range, stop in
                if let start = value as? NSNumber, start.intValue >= 0 {
                    contentStart = start.intValue
                    bodyRange = range
                    stop.pointee = true
                }
            }
            if let contentStart, let bodyRange {
                let delta = sourceOffset - contentStart
                if delta >= 0, delta <= bodyRange.length {
                    return bodyRange.location + delta
                }
                // Before the body (the opening fence / info line) rounds to
                // the body start; past it (closing fence) to the body end.
                return delta < 0 ? bodyRange.location : NSMaxRange(bodyRange)
            }
            let renderedText = (storage.string as NSString).substring(with: blockRange)
            return Self.deactivationCaretLocation(
                blockRange: blockRange, renderedText: renderedText,
                sourceOffset: sourceOffset, sourceText: sourceText
            )
        }

        /// The generic (non-embed) flip-back mapping: the rendered image of
        /// `sourceOffset`, rounded BACKWARD to visible content — a caret at
        /// the source's end must sit after the last rendered character,
        /// never forward across the trailing block separator into the next
        /// block.
        static func deactivationCaretLocation(
            blockRange: NSRange, renderedText: String, sourceOffset: Int, sourceText: String
        ) -> Int {
            let mapped = EditMapping.renderedOffsets(
                forSourceOffsets: [sourceOffset],
                renderedText: renderedText,
                sourceText: sourceText
            ).first ?? 0
            let ns = renderedText as NSString
            var contentEnd = ns.length
            while contentEnd > 0, ns.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
            return blockRange.location + min(max(0, mapped), contentEnd)
        }

        // MARK: Focus mode

        /// The block the dimming currently spares, plus whether dimming is
        /// applied at all — the dedupe that keeps caret blinks and scroll
        /// passes from re-painting rendering attributes.
        private var focusDimmedForBlock: BlockID?
        private var focusDimmingActive = false
        /// Character extents the dim pass has painted so far (merged,
        /// sorted): dimming is viewport-culled (ledger perf #4), so the
        /// painted region grows as the user scrolls instead of repainting
        /// O(blocks) on every caret move.
        private var focusPaintedRanges: [NSRange] = []
        /// The caret sentence last soft-dimmed (sentence scope), nil when
        /// scope is off — the dedupe key that used to be missing: sentence
        /// mode repainted the whole document on EVERY caret blink even
        /// when the sentence hadn't changed.
        private var focusAppliedSentence: NSRange?
        /// Overscan around the viewport so ordinary scrolling stays ahead
        /// of the lazily painted dim region (same generosity as the
        /// decoration cull in QuoinTextView).
        private static let focusDimSlack = 4096

        /// Focus mode: every block except the caret's recedes to 30% ink.
        /// Rendering attributes only (TextKit 2 overlay) — glyphs keep
        /// their layout exactly; nothing reflows, nothing re-renders, and
        /// the projection's real attributes are untouched. The paint is
        /// culled to the viewport (plus overscan); scrolling extends it
        /// through `extendFocusDimmingIntoViewport`.
        func applyFocusDimming(in textView: NSTextView, theme: Theme) {
            guard let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let storage = contentStorage.textStorage
            else { return }
            let enabled = parent.focusModeEnabled && storage.length > 0
            let caret = textView.selectedRange().location
            let currentBlock = enabled ? blockID(atCharIndex: min(caret, max(0, storage.length - 1))) : nil

            // Sentence scope: resolve the caret's sentence first — it is
            // the dedupe key. Block-local cost, not document-scale.
            let sentenceScope = parent.focusSentenceScope
            var sentence: NSRange?
            var sentenceBlockRange: NSRange?
            if enabled, sentenceScope, let currentBlock,
               let blockRange = blockRanges[currentBlock],
               NSMaxRange(blockRange) <= storage.length {
                sentenceBlockRange = blockRange
                let text = storage.string as NSString
                text.enumerateSubstrings(
                    in: blockRange, options: [.bySentences, .substringNotRequired]
                ) { _, range, _, stop in
                    if caret >= range.location, caret <= NSMaxRange(range) {
                        sentence = range
                        stop.pointee = true
                    }
                }
            }

            let stateUnchanged = enabled == focusDimmingActive
                && currentBlock == focusDimmedForBlock
                && appliedRevision == focusAppliedRevision
            guard !stateUnchanged || sentence != focusAppliedSentence else { return }

            // Sentence-only caret move: the block dims are already right —
            // repaint just the current block's soft dims, nothing else.
            if stateUnchanged, enabled, let blockRange = sentenceBlockRange ?? currentBlock.flatMap({ blockRanges[$0] }),
               NSMaxRange(blockRange) <= storage.length,
               let blockTextRange = nsTextRange(blockRange, in: contentStorage) {
                layoutManager.removeRenderingAttribute(.foregroundColor, for: blockTextRange)
                focusAppliedSentence = sentence
                applySentenceSoftDim(sentence, blockRange: blockRange, theme: theme,
                                     layoutManager: layoutManager, contentStorage: contentStorage)
                return
            }

            focusDimmingActive = enabled
            focusDimmedForBlock = currentBlock
            focusAppliedRevision = appliedRevision
            focusAppliedSentence = sentence
            focusPaintedRanges = []

            layoutManager.removeRenderingAttribute(
                .foregroundColor, for: contentStorage.documentRange)
            guard enabled else { return }
            let paintRange = focusViewportPaintRange(
                in: textView, layoutManager: layoutManager,
                contentStorage: contentStorage, storageLength: storage.length)
            paintFocusDim(in: paintRange, sparing: currentBlock, theme: theme,
                          layoutManager: layoutManager, contentStorage: contentStorage)
            focusPaintedRanges = [paintRange]
            // Sentence granularity (idea #2, iA-Writer-style): inside the
            // current block, everything but the caret's SENTENCE recedes
            // too — same rendering-attribute engine, softer dim.
            if let sentence, let blockRange = sentenceBlockRange {
                applySentenceSoftDim(sentence, blockRange: blockRange, theme: theme,
                                     layoutManager: layoutManager, contentStorage: contentStorage)
            }
        }
        private var focusAppliedRevision = -2

        /// The viewport's character extent plus overscan — the region the
        /// dim pass paints eagerly; everything else is painted on scroll.
        private func focusViewportPaintRange(
            in textView: NSTextView, layoutManager: NSTextLayoutManager,
            contentStorage: NSTextContentStorage, storageLength: Int
        ) -> NSRange {
            guard let viewport = layoutManager.textViewportLayoutController.viewportRange else {
                return NSRange(location: 0, length: storageLength)
            }
            let start = contentStorage.offset(from: contentStorage.documentRange.location,
                                              to: viewport.location)
            let end = contentStorage.offset(from: contentStorage.documentRange.location,
                                            to: viewport.endLocation)
            let lower = max(0, start - Self.focusDimSlack)
            let upper = min(storageLength, end + Self.focusDimSlack)
            return NSRange(location: lower, length: max(0, upper - lower))
        }

        /// Adds the 30% dim to every block intersecting `range` except the
        /// caret's — binary-searched via the block-range index, so the
        /// cost is O(visible blocks), never O(document blocks).
        /// Each run dims to 30% OF ITS OWN COLOR — a flat ink-tinted dim
        /// painted near-black over the dark code canvas and code vanished
        /// entirely in focus mode (live report, 2026-07-15); per-run
        /// dimming keeps token hues and stays visible on any surface.
        private func paintFocusDim(
            in range: NSRange, sparing currentBlock: BlockID?, theme: Theme,
            layoutManager: NSTextLayoutManager, contentStorage: NSTextContentStorage
        ) {
            forEachBlockRange(intersecting: range) { id, blockRange in
                guard id != currentBlock else { return }
                dimRuns(in: blockRange, alpha: 0.3, theme: theme,
                        layoutManager: layoutManager, contentStorage: contentStorage)
            }
        }

        private func applySentenceSoftDim(
            _ sentence: NSRange?, blockRange: NSRange, theme: Theme,
            layoutManager: NSTextLayoutManager, contentStorage: NSTextContentStorage
        ) {
            guard let sentence else { return }
            let before = NSRange(location: blockRange.location,
                                 length: sentence.location - blockRange.location)
            let after = NSRange(location: NSMaxRange(sentence),
                                length: NSMaxRange(blockRange) - NSMaxRange(sentence))
            for part in [before, after] where part.length > 0 {
                dimRuns(in: part, alpha: 0.4, theme: theme,
                        layoutManager: layoutManager, contentStorage: contentStorage)
            }
        }

        /// One dim engine: every foreground-color run in `range` gets a
        /// rendering attribute of ITS color at `alpha` (runs without an
        /// explicit color dim from the theme ink).
        private func dimRuns(
            in range: NSRange, alpha: CGFloat, theme: Theme,
            layoutManager: NSTextLayoutManager, contentStorage: NSTextContentStorage
        ) {
            guard let storage = contentStorage.textStorage,
                  NSMaxRange(range) <= storage.length else { return }
            storage.enumerateAttribute(.foregroundColor, in: range) { value, runRange, _ in
                let base = (value as? NSColor) ?? theme.ink
                guard let textRange = nsTextRange(runRange, in: contentStorage) else { return }
                layoutManager.addRenderingAttribute(
                    .foregroundColor, value: base.withAlphaComponent(alpha), for: textRange)
            }
        }

        /// Scroll hook for the viewport-culled dim: paints only the blocks
        /// in the newly exposed extent (nothing already painted is
        /// touched); a no-op whenever the viewport is inside the painted
        /// region. Called from the scroll observer.
        func extendFocusDimmingIntoViewport(in textView: NSTextView) {
            guard focusDimmingActive,
                  let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let storage = contentStorage.textStorage, storage.length > 0
            else { return }
            let target = focusViewportPaintRange(
                in: textView, layoutManager: layoutManager,
                contentStorage: contentStorage, storageLength: storage.length)
            // Subtract the already-painted extents from the target.
            var gaps: [NSRange] = [target]
            for painted in focusPaintedRanges {
                gaps = gaps.flatMap { gap -> [NSRange] in
                    let overlap = NSIntersectionRange(gap, painted)
                    guard overlap.length > 0 else { return [gap] }
                    var pieces: [NSRange] = []
                    if overlap.location > gap.location {
                        pieces.append(NSRange(location: gap.location,
                                              length: overlap.location - gap.location))
                    }
                    if NSMaxRange(overlap) < NSMaxRange(gap) {
                        pieces.append(NSRange(location: NSMaxRange(overlap),
                                              length: NSMaxRange(gap) - NSMaxRange(overlap)))
                    }
                    return pieces
                }
            }
            guard !gaps.isEmpty else { return }
            let theme = parent.theme
            for gap in gaps where gap.length > 0 {
                paintFocusDim(in: gap, sparing: focusDimmedForBlock, theme: theme,
                              layoutManager: layoutManager, contentStorage: contentStorage)
            }
            // Merge the target into the painted set (sorted, coalesced).
            var merged = focusPaintedRanges
            merged.append(target)
            merged.sort { $0.location < $1.location }
            var coalesced: [NSRange] = []
            for range in merged {
                if let last = coalesced.last, range.location <= NSMaxRange(last) {
                    let end = max(NSMaxRange(last), NSMaxRange(range))
                    coalesced[coalesced.count - 1] = NSRange(
                        location: last.location, length: end - last.location)
                } else {
                    coalesced.append(range)
                }
            }
            focusPaintedRanges = coalesced
        }

        /// Caret moved into a different block while focus mode is on —
        /// called from the selection-change path.
        func refreshFocusDimmingOnSelectionChange(in textView: NSTextView) {
            guard parent.focusModeEnabled else { return }
            applyFocusDimming(in: textView, theme: parent.theme)
        }

        /// ⌘↩ / Format ▸ Edit Source: toggles the block under the caret
        /// between rendered and revealed source. Closing uses the same
        /// commit-and-restore contract as Escape; opening lands the caret
        /// at the mapped position under it.
        func toggleEditSource(in textView: NSTextView) {
            if parent.rendered.activeBlockID != nil {
                captureDeactivationCaret(in: textView)
                parent.onActivateBlock?(nil, nil, nil)
                return
            }
            let location = textView.selectedRange().location
            guard let id = blockID(atCharIndex: location) else { return }
            let hint: CaretHint? = caretHint(forActivationAt: location, blockID: id)
            parent.onActivateBlock?(id, hint, nil)
        }

        /// Right-click items for the block under the pointer: Edit Source /
        /// Done Editing (embeds and the open block), and Copy Markdown
        /// Source (any block whose source the host can provide). Inserted
        /// above AppKit's standard items.
        /// Card→document affordance (user ask: "draw a line or something"):
        /// scrolls the mark into view and FLASHES an accent ring around its
        /// rendered runs — the native gesture for "this is the one",
        /// pane-to-pane lines being fragile theater. The ring is a
        /// pass-through overlay that fades and removes itself.
        func flashSuggestionMark(
            byteOffset: Int, fallbackBlockID: BlockID? = nil,
            scroll: MarkdownReaderView.FlashScrollBehavior = .center,
            in textView: NSTextView
        ) {
            guard let storage = textView.textContentStorage?.textStorage,
                  let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage else { return }
            var charRange: NSRange?
            storage.enumerateAttribute(
                QuoinAttribute.suggestionRange,
                in: NSRange(location: 0, length: storage.length)
            ) { value, range, stop in
                if let boxed = value as? NSValue, boxed.rangeValue.location == byteOffset {
                    charRange = charRange.map { NSUnionRange($0, range) } ?? range
                }
            }
            // No rendered mark at that offset — the RESOLUTION case (the
            // mark was just spliced away): pulse the block it happened in.
            // Trimmed to CONTENT: the block range includes its trailing
            // separator, whose empty line fragment made the ring tall and
            // narrow (live report — a one-word paragraph pulsed as a
            // portrait rectangle).
            if charRange == nil, let fallbackBlockID,
               var blockRange = parent.rendered.blockRanges[fallbackBlockID],
               NSMaxRange(blockRange) <= storage.length {
                let text = storage.string as NSString
                while blockRange.length > 0 {
                    let last = text.character(at: blockRange.location + blockRange.length - 1)
                    guard let scalar = Unicode.Scalar(last),
                          CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
                    blockRange.length -= 1
                }
                if blockRange.length > 0 { charRange = blockRange }
            }
            guard let charRange,
                  let textRange = nsTextRange(charRange, in: contentStorage) else { return }
            layoutManager.ensureLayout(for: textRange)

            var union: CGRect?
            layoutManager.enumerateTextLayoutFragments(
                from: textRange.location, options: [.ensuresLayout]
            ) { fragment in
                if fragment.rangeInElement.location.compare(textRange.endLocation) != .orderedAscending {
                    return false
                }
                union = union.map { $0.union(fragment.layoutFragmentFrame) } ?? fragment.layoutFragmentFrame
                return true
            }
            guard var rect = union else { return }
            rect = rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
                .insetBy(dx: -4, dy: -2)

            // Center the linked text: the mark's TOP lands as close to the
            // viewport's vertical center as document bounds allow (user
            // redline: the old minimal scroll left it hugging the top edge).
            // Resolution pulses scroll ONLY when the change is offscreen —
            // a visible change must not move under the click, an offscreen
            // one must come to the user (second redline).
            let shouldScroll: Bool
            switch scroll {
            case .center: shouldScroll = true
            case .centerIfOffscreen: shouldScroll = !textView.visibleRect.intersects(rect)
            }
            if shouldScroll, let scrollView = textView.enclosingScrollView {
                let clip = scrollView.contentView
                let visibleHeight = clip.bounds.height
                let maxOrigin = max(0, textView.bounds.height - visibleHeight)
                let target = max(0, min(rect.minY - visibleHeight / 2, maxOrigin))
                if abs(clip.bounds.origin.y - target) > 1 {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.25
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        clip.animator().setBoundsOrigin(
                            NSPoint(x: clip.bounds.origin.x, y: target))
                    }
                    scrollView.reflectScrolledClipView(clip)
                }
            }

            // One live ring at a time: the predecessor's frame is stale
            // against any reflow that happened since ITS flash, so a
            // repeat flash replaces it instead of stacking.
            activeFlashRing?.removeFromSuperview()
            let ring = FlashRingView(frame: rect)
            ring.strokeColor = parent.theme.accent
            textView.addSubview(ring)
            activeFlashRing = ring
            // The flash is invisible to VoiceOver — announce the jump so
            // the card→document affordance exists non-visually too
            // (panel review).
            let announced = (storage.string as NSString).substring(with: charRange)
            NSAccessibility.post(
                element: textView,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "Showing suggestion: \(announced.prefix(80))",
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ])
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 1.8 // user redline: 0.9 faded too fast
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                ring.animator().alphaValue = 0
            }, completionHandler: { [weak ring] in
                ring?.removeFromSuperview()
            })
        }

        /// Reverse linkage (document→card): the caret entering/leaving a
        /// rendered mark reports its byte range, deduped.
        private var lastReportedSuggestionLink: ByteRange??
        func reportSuggestionCaretLink(in textView: NSTextView) {
            guard parent.onSuggestionCaretLink != nil,
                  let storage = textView.textContentStorage?.textStorage else { return }
            let caret = textView.selectedRange().location
            var link: ByteRange?
            if caret >= 0, caret < storage.length,
               let boxed = storage.attribute(
                   QuoinAttribute.suggestionRange, at: caret, effectiveRange: nil) as? NSValue {
                let range = boxed.rangeValue
                link = ByteRange(offset: range.location, length: range.length)
            }
            guard lastReportedSuggestionLink != .some(link) else { return }
            lastReportedSuggestionLink = .some(link)
            parent.onSuggestionCaretLink?(link)
        }

        @objc private func contextResolveSuggestion(_ sender: NSMenuItem) {
            guard let payload = sender.representedObject as? [Any],
                  let boxed = payload.first as? NSValue,
                  let accept = payload.last as? Bool else { return }
            let range = boxed.rangeValue
            parent.onSuggestionAction?(
                ByteRange(offset: range.location, length: range.length),
                accept ? .accept : .reject)
        }

        func populateContextMenu(_ menu: NSMenu, atCharIndex index: Int) {
            guard let id = blockID(atCharIndex: index) else { return }
            var items: [NSMenuItem] = []
            // Right-click on a rendered suggestion mark: resolve it here
            // (suggestions design S2; the review rail adds card buttons).
            if parent.onSuggestionAction != nil,
               let storage = textView?.textContentStorage?.textStorage,
               index < storage.length,
               let boxed = storage.attribute(
                   QuoinAttribute.suggestionRange, at: index, effectiveRange: nil) as? NSValue {
                let accept = NSMenuItem(
                    title: "Accept Suggestion",
                    action: #selector(contextResolveSuggestion(_:)), keyEquivalent: "")
                accept.target = self
                accept.representedObject = [boxed, true] as [Any]
                items.append(accept)
                let reject = NSMenuItem(
                    title: "Reject Suggestion",
                    action: #selector(contextResolveSuggestion(_:)), keyEquivalent: "")
                reject.target = self
                reject.representedObject = [boxed, false] as [Any]
                items.append(reject)
                items.append(NSMenuItem.separator())
            }
            // Review gestures (S3a): selection-scoped, before block items.
            if parent.onAddAnnotation != nil, let textView,
               let target = annotationSelection(in: textView),
               target.relEnd > target.relStart, target.blockID == id {
                func reviewItem(_ title: String, _ raw: String) -> NSMenuItem {
                    let item = NSMenuItem(
                        title: title, action: #selector(contextAddAnnotation(_:)),
                        keyEquivalent: "")
                    item.target = self
                    item.representedObject = raw
                    return item
                }
                items.append(reviewItem("Add Comment…", "comment"))
                items.append(reviewItem("Suggest Replacement…", "replacement"))
                items.append(reviewItem("Suggest Deletion", "deletion"))
                items.append(reviewItem("Highlight", "highlight"))
                items.append(NSMenuItem.separator())
            }
            // Comment on the BLOCK (#68) — the only way to annotate code,
            // tables, diagrams, and math, and available everywhere.
            if parent.onAddBlockComment != nil {
                let item = NSMenuItem(
                    title: "Comment on Block…",
                    action: #selector(contextBlockComment(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                items.append(item)
                items.append(NSMenuItem.separator())
            }
            let isActive = id == parent.rendered.activeBlockID
            if isActive || isEmbedBlock(atCharIndex: index) {
                let item = NSMenuItem(
                    title: isActive ? "Done Editing" : "Edit Source",
                    action: #selector(contextEditSource(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = index
                items.append(item)
            }
            if let source = parent.blockSourceProvider?(id), !source.isEmpty {
                let item = NSMenuItem(
                    title: "Copy Markdown Source",
                    action: #selector(contextCopyMarkdownSource(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = source
                items.append(item)
            }
            // Block actions (ideas #9/#10): every block moves, duplicates,
            // deletes from here; tables also grow rows/columns (idea #11).
            if parent.onBlockCommand != nil {
                items.append(NSMenuItem.separator())
                func commandItem(_ title: String, _ name: String) -> NSMenuItem {
                    let item = NSMenuItem(
                        title: title, action: #selector(contextBlockCommand(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = [index, name] as [Any]
                    return item
                }
                items.append(commandItem("Move Block Up", "moveUp"))
                items.append(commandItem("Move Block Down", "moveDown"))
                items.append(commandItem("Duplicate Block", "duplicate"))
                items.append(commandItem("Delete Block", "delete"))
                // Structural table editing (#14): a full row/column/align
                // submenu, targeting the cell the click fell on. Only shown
                // for a block the AST recognizes as a table — the single
                // recognizer of record. Gating on `TableEditing.parse` (which
                // is lenient enough to accept setext headings and malformed
                // pipe paragraphs) would surface the submenu where a table op
                // would corrupt the block (two-recognizers-diverge, CLAUDE.md).
                if parent.isTableBlockProvider?(id) == true {
                    let target = tableGridLocation(forCharIndex: index, blockID: id)
                    items.append(NSMenuItem.separator())
                    items.append(tableSubmenuItem(index: index, target: target))
                }
            }
            guard !items.isEmpty else { return }
            items.append(NSMenuItem.separator())
            for (offset, item) in items.enumerated() {
                menu.insertItem(item, at: offset)
            }
        }

        // MARK: - S3a annotation gestures (suggestions §3.6)

        /// The current selection as an annotation target: block + rendered
        /// offsets RELATIVE to the block + the rendered text the user sees.
        /// Nil when the selection crosses blocks (marks are intra-block) or
        /// there is no text view. A zero-length selection is a valid target
        /// only for document-level comments — callers decide.
        struct AnnotationSelection {
            let blockID: BlockID
            let relStart: Int
            let relEnd: Int
            let renderedText: String
        }

        func annotationSelection(in textView: NSTextView) -> AnnotationSelection? {
            let selection = textView.selectedRange()
            guard let storage = textView.textContentStorage?.textStorage,
                  NSMaxRange(selection) <= storage.length,
                  let id = blockID(atCharIndex: selection.location),
                  let blockRange = blockRanges[id],
                  NSMaxRange(selection) <= NSMaxRange(blockRange)
            else { return nil }
            if selection.length > 0,
               blockID(atCharIndex: NSMaxRange(selection) - 1) != id {
                return nil // crosses blocks — v1 marks are intra-block
            }
            let text = (storage.string as NSString).substring(with: selection)
            return AnnotationSelection(
                blockID: id,
                relStart: selection.location - blockRange.location,
                relEnd: NSMaxRange(selection) - blockRange.location,
                renderedText: text)
        }

        func beginAnnotation(
            _ gesture: MarkdownReaderView.AnnotationGesture, in textView: NSTextView
        ) {
            guard let onAdd = parent.onAddAnnotation else { return }
            guard let target = annotationSelection(in: textView) else {
                NSSound.beep()
                return
            }
            let hasSelection = target.relEnd > target.relStart
            switch gesture {
            case .deletion:
                guard hasSelection else { NSSound.beep(); return }
                onAdd(.deletion, target.blockID, target.relStart, target.relEnd, target.renderedText)
            case .highlight:
                guard hasSelection else { NSSound.beep(); return }
                onAdd(.highlight, target.blockID, target.relStart, target.relEnd, target.renderedText)
            case .comment:
                // Inside an opaque block, a selection comment cannot exist
                // (RDFM opacity) — fall through to a BLOCK comment (#68)
                // instead of a refusal banner.
                if isEmbedBlock(atCharIndex: textView.selectedRange().location),
                   parent.onAddBlockComment != nil {
                    beginBlockComment(target.blockID, in: textView)
                    return
                }
                // No selection → document-level comment (endmatter-only).
                presentComposer(
                    prompt: hasSelection ? "Comment on “\(target.renderedText.prefix(40))…”"
                        : "Comment on the whole document",
                    initialText: "", commitTitle: "Comment", in: textView
                ) { body in
                    onAdd(.comment(body: body), target.blockID,
                          target.relStart, target.relEnd, target.renderedText)
                }
            case .replacement:
                guard hasSelection else { NSSound.beep(); return }
                presentComposer(
                    prompt: "Replace with", initialText: target.renderedText,
                    commitTitle: "Suggest", in: textView
                ) { new in
                    onAdd(.replacement(new: new), target.blockID,
                          target.relStart, target.relEnd, target.renderedText)
                }
            }
        }

        /// Editor teardown (tab switch): transient chrome anchored to the
        /// dying text view must not outlive it. A shown NSPopover survives
        /// its positioning view's removal as an orphaned floating panel,
        /// and a mid-fade flash ring would wait on its animation
        /// completion; the hover dwell would later call `show` against a
        /// windowless view, which raises.
        func teardownTransientChrome() {
            linkHoverDwell?.cancel()
            linkHoverDwell = nil
            if annotationPopover?.isShown == true { annotationPopover?.close() }
            annotationPopover = nil
            closeLinkPreview()
            activeFlashRing?.removeFromSuperview()
            activeFlashRing = nil
        }

        private func presentComposer(
            prompt: String, initialText: String, commitTitle: String,
            in textView: NSTextView, onCommit: @escaping (String) -> Void
        ) {
            // `NSPopover.show` raises on a view with no window, and
            // annotation commands arrive through updateNSView, which can
            // run before the window exists (see the first-focus claim).
            guard textView.window != nil else { return }
            annotationPopover?.performClose(nil)
            let controller = AnnotationComposerController(
                prompt: prompt, initialText: initialText, commitTitle: commitTitle,
                onCommit: onCommit)
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = controller
            controller.popover = popover
            // Anchor at the selection's first rect (screen → view coords);
            // fall back to the visible rect's center for caret-only input.
            let selection = textView.selectedRange()
            var screenRect = textView.firstRect(forCharacterRange: selection, actualRange: nil)
            if screenRect.isEmpty {
                screenRect.size = CGSize(width: 1, height: 14)
            }
            let windowRect = textView.window?.convertFromScreen(screenRect) ?? .zero
            var anchor = textView.convert(windowRect, from: nil)
            if anchor.isEmpty || !textView.visibleRect.intersects(anchor) {
                anchor = CGRect(x: textView.visibleRect.midX, y: textView.visibleRect.midY,
                                width: 1, height: 1)
            }
            annotationPopover = popover
            popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
        }

        func beginBlockComment(_ blockID: BlockID, in textView: NSTextView) {
            guard let onAdd = parent.onAddBlockComment else { return }
            presentComposer(
                prompt: "Comment on this block", initialText: "",
                commitTitle: "Comment", in: textView
            ) { body in
                onAdd(blockID, body)
            }
        }

        @objc func contextBlockComment(_ sender: NSMenuItem) {
            guard let textView, let id = sender.representedObject as? BlockID else { return }
            beginBlockComment(id, in: textView)
        }

        @objc func contextAddAnnotation(_ sender: NSMenuItem) {
            guard let textView,
                  let raw = sender.representedObject as? String else { return }
            let gesture: MarkdownReaderView.AnnotationGesture?
            switch raw {
            case "comment": gesture = .comment
            case "replacement": gesture = .replacement
            case "deletion": gesture = .deletion
            case "highlight": gesture = .highlight
            default: gesture = nil
            }
            if let gesture { beginAnnotation(gesture, in: textView) }
        }

        @objc private func contextEditSource(_ sender: NSMenuItem) {
            guard let textView, let index = sender.representedObject as? Int,
                  let id = blockID(atCharIndex: index) else { return }
            if id == parent.rendered.activeBlockID {
                captureDeactivationCaret(in: textView)
                parent.onActivateBlock?(nil, nil, nil)
            } else {
                let hint: CaretHint? = caretHint(forActivationAt: index, blockID: id)
                parent.onActivateBlock?(id, hint, nil)
            }
        }

        @objc private func contextCopyMarkdownSource(_ sender: NSMenuItem) {
            guard let source = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(source, forType: .string)
        }

        /// The table grid coordinates (row 0 = header, 0-based column) of a
        /// right-click at rendered char `index` inside table block `id`. When
        /// the table is the active (revealed) block, the storage text is its
        /// verbatim source so the offset maps 1:1; otherwise the click's
        /// rendered offset is mapped through `EditMapping` before the grid
        /// lookup. Falls back to the header's first cell if anything is
        /// unmappable — a safe, never-corrupting default.
        private func tableGridLocation(
            forCharIndex index: Int, blockID id: BlockID
        ) -> (row: Int, column: Int) {
            guard let source = parent.blockSourceProvider?(id),
                  let blockRange = blockRanges[id] else { return (0, 0) }
            let relRendered = max(0, index - blockRange.location)
            let sourceOffset: Int
            if id == parent.rendered.activeBlockID {
                sourceOffset = relRendered
            } else if let storage = textView?.textContentStorage?.textStorage,
                      NSMaxRange(blockRange) <= storage.length {
                let renderedSlice = (storage.string as NSString).substring(with: blockRange)
                sourceOffset = EditMapping.sourceOffset(
                    forRenderedOffset: relRendered,
                    renderedText: renderedSlice, sourceText: source)
            } else {
                sourceOffset = relRendered
            }
            return TableEditing.location(forOffsetUTF16: sourceOffset, in: source) ?? (0, 0)
        }

        /// Builds the "Table" submenu (#14). Each item carries `[index, name,
        /// row, column]`; `contextBlockCommand` decodes the target.
        private func tableSubmenuItem(index: Int, target: (row: Int, column: Int)) -> NSMenuItem {
            let root = NSMenuItem(title: "Table", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Table")
            func item(_ title: String, _ name: String) -> NSMenuItem {
                let entry = NSMenuItem(
                    title: title, action: #selector(contextBlockCommand(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = [index, name, target.row, target.column] as [Any]
                return entry
            }
            submenu.addItem(item("Insert Row Above", "insertRowAbove"))
            submenu.addItem(item("Insert Row Below", "insertRowBelow"))
            submenu.addItem(item("Delete Row", "deleteRow"))
            submenu.addItem(.separator())
            submenu.addItem(item("Insert Column Left", "insertColumnLeft"))
            submenu.addItem(item("Insert Column Right", "insertColumnRight"))
            submenu.addItem(item("Delete Column", "deleteColumn"))
            submenu.addItem(.separator())
            submenu.addItem(item("Move Row Up", "moveRowUp"))
            submenu.addItem(item("Move Row Down", "moveRowDown"))
            submenu.addItem(item("Move Column Left", "moveColumnLeft"))
            submenu.addItem(item("Move Column Right", "moveColumnRight"))
            submenu.addItem(.separator())
            let align = NSMenuItem(title: "Align Column", action: nil, keyEquivalent: "")
            let alignMenu = NSMenu(title: "Align Column")
            alignMenu.addItem(item("Left", "alignLeft"))
            alignMenu.addItem(item("Center", "alignCenter"))
            alignMenu.addItem(item("Right", "alignRight"))
            alignMenu.addItem(item("None", "alignNone"))
            align.submenu = alignMenu
            submenu.addItem(align)
            submenu.addItem(.separator())
            submenu.addItem(item("Normalize Table", "normalize"))
            root.submenu = submenu
            return root
        }

        @objc private func contextBlockCommand(_ sender: NSMenuItem) {
            guard let payload = sender.representedObject as? [Any], payload.count >= 2,
                  let index = payload[0] as? Int,
                  let commandName = payload[1] as? String,
                  let id = blockID(atCharIndex: index) else { return }
            // Table commands carry [index, name, row, column]; block commands
            // carry [index, name].
            let row = payload.count > 2 ? (payload[2] as? Int ?? 0) : 0
            let column = payload.count > 3 ? (payload[3] as? Int ?? 0) : 0
            let command: BlockCommand? = switch commandName {
            case "moveUp": .moveUp
            case "moveDown": .moveDown
            case "duplicate": .duplicate
            case "delete": .delete
            case "addTableRow": .addTableRow
            case "addTableColumn": .addTableColumn
            case "insertRowAbove": .tableInsertRow(at: row, above: true)
            case "insertRowBelow": .tableInsertRow(at: row, above: false)
            case "deleteRow": .tableDeleteRow(at: row)
            case "insertColumnLeft": .tableInsertColumn(at: column, left: true)
            case "insertColumnRight": .tableInsertColumn(at: column, left: false)
            case "deleteColumn": .tableDeleteColumn(at: column)
            case "moveRowUp": .tableMoveRow(at: row, up: true)
            case "moveRowDown": .tableMoveRow(at: row, up: false)
            case "moveColumnLeft": .tableMoveColumn(at: column, left: true)
            case "moveColumnRight": .tableMoveColumn(at: column, left: false)
            case "alignLeft": .tableSetAlignment(at: column, alignment: .left)
            case "alignCenter": .tableSetAlignment(at: column, alignment: .center)
            case "alignRight": .tableSetAlignment(at: column, alignment: .right)
            case "alignNone": .tableSetAlignment(at: column, alignment: .none)
            case "normalize": .tableNormalize
            default: nil
            }
            if let command {
                parent.onBlockCommand?(id, command)
            }
        }

        // MARK: Link hover peek (idea #8)

        private var linkPreviewPopover: NSPopover?
        private var linkHoverDwell: DispatchWorkItem?
        private var linkPreviewURL: URL?

        /// Hovering an INTERNAL anchor link peeks its target section — and a
        /// footnote reference its definition — in a small card after a short
        /// dwell (Wikipedia-style); external links stay quiet.
        /// Semitransient — moves away, it goes away.
        func handleLinkHover(url: URL?, at rect: NSRect) {
            linkHoverDwell?.cancel()
            linkHoverDwell = nil
            guard let url,
                  QuoinLink.anchorSlug(from: url) != nil
                    || QuoinLink.footnoteID(from: url) != nil else {
                if linkPreviewPopover?.isShown == true { linkPreviewPopover?.close() }
                linkPreviewURL = nil
                return
            }
            guard url != linkPreviewURL || linkPreviewPopover?.isShown != true else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.presentLinkPreview(for: url, at: rect)
            }
            linkHoverDwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }

        private func closeLinkPreview() {
            if linkPreviewPopover?.isShown == true { linkPreviewPopover?.close() }
            linkPreviewPopover = nil
            linkPreviewURL = nil
        }

        private func presentLinkPreview(for url: URL, at rect: NSRect) {
            // The dwell timer can outlive the view's window (tab switch
            // mid-hover); `NSPopover.show` raises on a windowless view.
            guard let textView, textView.window != nil,
                  let storage = textView.textContentStorage?.textStorage,
                  let snippetRange = previewSnippetRange(for: url, in: textView, storage: storage)
            else { return }
            let snippet = storage.attributedSubstring(from: snippetRange)

            let label = NSTextField(wrappingLabelWithString: "")
            label.attributedStringValue = snippet
            label.preferredMaxLayoutWidth = 340
            label.isSelectable = false
            let fitting = label.sizeThatFits(NSSize(width: 340, height: 1000))
            let height = min(fitting.height, 240)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 364, height: height + 24))
            label.frame = NSRect(x: 12, y: 12, width: 340, height: height)
            container.addSubview(label)

            let popover = linkPreviewPopover ?? NSPopover()
            popover.behavior = .semitransient
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let controller = NSViewController()
            controller.view = container
            popover.contentViewController = controller
            popover.contentSize = container.frame.size
            popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
            linkPreviewPopover = popover
            linkPreviewURL = url
        }

        /// What the hover card shows: an anchor link peeks the target
        /// section's opening (its block range, padded to a readable
        /// minimum); a footnote reference peeks the definition's EXACT
        /// tagged range — nothing before, nothing after.
        private func previewSnippetRange(
            for url: URL, in textView: NSTextView, storage: NSTextStorage
        ) -> NSRange? {
            if let slug = QuoinLink.anchorSlug(from: url) {
                guard let blockID = parent.anchorResolver(slug),
                      let range = blockRanges[blockID],
                      range.location < storage.length
                else { return nil }
                let length = min(storage.length - range.location, max(range.length, 600))
                return NSRange(location: range.location, length: length)
            }
            if let id = QuoinLink.footnoteID(from: url) {
                guard let range = footnoteRun(id: id, tag: QuoinAttribute.footnoteDefinitionID, in: textView),
                      range.location < storage.length
                else { return nil }
                return NSRange(
                    location: range.location,
                    length: min(range.length, storage.length - range.location))
            }
            return nil
        }

        /// Smart paste (idea #4), scoped to active-block editing: a URL
        /// pasted over selected text becomes a link; tab-separated rows
        /// pasted at the caret become a table. Anything else falls through
        /// to the ordinary paste pipeline.
        func handleSmartPaste() -> Bool {
            guard let textView,
                  parent.rendered.activeEditableRange != nil,
                  let pasted = NSPasteboard.general.string(forType: .string)
            else { return false }
            // Mid-flight the selection can't be trusted (ledger #9): queue
            // the CAPTURED string (the pasteboard may change before the
            // flush) and decide smart-vs-plain against the fresh selection.
            if awaitingEditEcho {
                pendingCommands.append(.smartPaste(pasted))
                return true
            }
            return applySmartPaste(pasted, in: textView)
        }

        /// The smart-paste decision against the CURRENT selection: URL over
        /// a selection becomes a link; tabular text at a caret becomes a
        /// markdown table. Returns false when neither applies (plain paste).
        private func applySmartPaste(_ pasted: String, in textView: NSTextView) -> Bool {
            guard let onEdit = parent.onEditIntent,
                  let active = parent.rendered.activeEditableRange,
                  let sourceText = parent.rendered.activeSourceText
            else { return false }
            let selection = textView.selectedRange()
            guard selection.location >= active.location,
                  NSMaxRange(selection) <= NSMaxRange(active) else { return false }
            let relStart = selection.location - active.location

            let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            if selection.length > 0,
               let url = URL(string: trimmed),
               let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
               trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
                let relRange = relStart..<(relStart + selection.length)
                guard let byteRange = EditMapping.utf8Range(inText: sourceText, utf16Range: relRange) else {
                    return false
                }
                let selected = (sourceText as NSString)
                    .substring(with: NSRange(location: relStart, length: selection.length))
                let replacement = "[\(selected)](\(trimmed))"
                onEdit(byteRange, replacement, replacement.utf8.count)
                beginAwaitingEditEcho()
                return true
            }

            if selection.length == 0,
               let table = TableEditing.markdownTable(fromTabular: pasted) {
                let relRange = relStart..<relStart
                guard let byteRange = EditMapping.utf8Range(inText: sourceText, utf16Range: relRange) else {
                    return false
                }
                onEdit(byteRange, table, table.utf8.count)
                beginAwaitingEditEcho()
                return true
            }
            return false
        }

        /// Esc closes the revealed block, committing as always (Escape
        /// never reverts — every keystroke is already in the file; backing
        /// out is ⌘Z's job) and restoring the caret at the rendered image
        /// of where it was.
        public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)),
               parent.rendered.activeBlockID != nil {
                captureDeactivationCaret(in: textView)
                parent.onActivateBlock?(nil, nil, nil)
                return true
            }
            // Tab / ⇧Tab on a list-item line of the revealed source:
            // indent / outdent as ONE byte edit (task #60). Non-list lines
            // fall through to the ordinary tab insertion.
            if commandSelector == #selector(NSTextView.insertTab(_:)) {
                return indentListLines(outdent: false, in: textView)
            }
            if commandSelector == #selector(NSTextView.insertBacktab(_:)) {
                return indentListLines(outdent: true, in: textView)
            }
            // Return on a list/quote/checkbox line continues the marker (or
            // ends the list on an empty item), like every native editor.
            // Non-list lines fall through to the ordinary newline.
            if commandSelector == #selector(NSTextView.insertNewline(_:)) {
                return continueListOnReturn(in: textView)
            }
            // ⌘A while EDITING selects the active block's editable range,
            // not the whole document (live redline 2026-07-15) — the block
            // is the editing scope, and whole-doc selection from inside a
            // code block invited accidental whole-doc deletes.
            if commandSelector == #selector(NSTextView.selectAll(_:)),
               let active = parent.rendered.activeEditableRange {
                textView.setSelectedRange(active)
                return true
            }
            // Home/End while EDITING move the caret to the line ends (user
            // redline, #60); reading mode keeps the system scroll behavior.
            if parent.rendered.activeEditableRange != nil {
                if commandSelector == #selector(NSResponder.scrollToBeginningOfDocument(_:)) {
                    textView.moveToBeginningOfLine(nil)
                    return true
                }
                if commandSelector == #selector(NSResponder.scrollToEndOfDocument(_:)) {
                    textView.moveToEndOfLine(nil)
                    return true
                }
            }
            return false
        }

        /// The width of a list marker at the start of `line` — leading
        /// spaces, then `-`/`*`/`+` or `12.`/`12)`, then a space — measured
        /// as marker + one space (the column where the item's content
        /// starts, which is exactly one nesting step). Nil for non-list
        /// lines.
        static func listMarkerWidth(of line: Substring) -> Int? {
            var rest = line.drop(while: { $0 == " " })
            if let first = rest.first, "-*+".contains(first) {
                rest = rest.dropFirst()
            } else {
                let digits = rest.prefix(while: \.isNumber)
                guard !digits.isEmpty, digits.count <= 9 else { return nil }
                rest = rest.dropFirst(digits.count)
                guard let punct = rest.first, punct == "." || punct == ")" else { return nil }
                rest = rest.dropFirst()
                guard rest.first == " " || rest.isEmpty else { return nil }
                return digits.count + 2
            }
            guard rest.first == " " || rest.isEmpty else { return nil }
            return 2
        }

        /// Indents (or outdents) every list-item line the selection touches
        /// inside the active block's revealed source, as ONE relative byte
        /// edit through the ordinary intent pipeline — the caret keeps its
        /// position in the text. Returns false when the caret line isn't a
        /// list item, so Tab falls through to plain insertion.
        private func indentListLines(outdent: Bool, in textView: NSTextView) -> Bool {
            guard let onEdit = parent.onEditIntent,
                  !awaitingEditEcho,
                  let active = parent.rendered.activeEditableRange,
                  let sourceText = parent.rendered.activeSourceText else { return false }
            let selection = textView.selectedRange()
            guard selection.location >= active.location,
                  NSMaxRange(selection) <= NSMaxRange(active) else { return false }
            let relSelection = NSRange(location: selection.location - active.location,
                                       length: selection.length)
            guard let edit = Self.listIndentEdit(
                sourceText: sourceText, selection: relSelection, outdent: outdent
            ) else { return false }
            if let (byteRange, replacement, caretDelta) = edit.byteEdit(inText: sourceText) {
                onEdit(byteRange, replacement, caretDelta)
                beginAwaitingEditEcho()
            }
            return true
        }

        /// Return inside the active block's revealed source: continue a
        /// list/quote/checkbox marker onto the new line (or, on an empty item,
        /// end the list by removing the marker), as ONE relative byte edit.
        /// Never fires in verbatim (code/math/diagram) source, or when the
        /// caret line isn't a list item — those fall through to a plain newline.
        private func continueListOnReturn(in textView: NSTextView) -> Bool {
            guard let onEdit = parent.onEditIntent,
                  !awaitingEditEcho,
                  !parent.rendered.revealVerbatimCode,
                  let active = parent.rendered.activeEditableRange,
                  let sourceText = parent.rendered.activeSourceText else { return false }
            let selection = textView.selectedRange()
            guard selection.length == 0,
                  selection.location >= active.location,
                  NSMaxRange(selection) <= NSMaxRange(active) else { return false }
            let relCaret = selection.location - active.location
            guard let edit = Self.listContinuationEdit(sourceText: sourceText, caretUTF16: relCaret)
            else { return false }
            if let (byteRange, replacement, caretDelta) = edit.byteEdit(inText: sourceText) {
                onEdit(byteRange, replacement, caretDelta)
                beginAwaitingEditEcho()
            }
            return true
        }

        /// The pure computation behind Return list continuation: which UTF-16
        /// span to replace, with what, and where the caret lands within the
        /// replacement. Nil when the caret line isn't a continuable marker (a
        /// plain newline follows).
        struct ListContinuationEdit {
            let utf16Range: Range<Int>
            let replacement: String
            let caretUTF16: Int   // offset WITHIN the replacement

            func byteEdit(inText sourceText: String) -> (ByteRange, String, Int?)? {
                guard let byteRange = EditMapping.utf8Range(
                    inText: sourceText, utf16Range: utf16Range) else { return nil }
                return (byteRange, replacement,
                        EditMapping.utf8Offset(inText: replacement, utf16Offset: caretUTF16))
            }
        }

        static func listContinuationEdit(sourceText: String, caretUTF16 caret: Int) -> ListContinuationEdit? {
            let ns = sourceText as NSString
            guard caret >= 0, caret <= ns.length else { return nil }
            let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
            let rawLine = ns.substring(with: lineRange)
            let line = Substring(rawLine.hasSuffix("\n") ? String(rawLine.dropLast()) : rawLine)
            guard let (prefixCount, continuation) = listContinuationMarker(of: line) else { return nil }
            // The marker prefix is all ASCII, so char count == UTF-16 length.
            let contentStart = lineRange.location + prefixCount
            guard caret >= contentStart else { return nil } // caret inside the marker → plain newline
            let content = line.dropFirst(prefixCount)
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                // Empty item + Return: remove the marker, ending the list.
                return ListContinuationEdit(
                    utf16Range: lineRange.location ..< contentStart, replacement: "", caretUTF16: 0)
            }
            // Non-empty: split the line, carrying the continued marker down.
            let replacement = "\n" + continuation
            return ListContinuationEdit(
                utf16Range: caret ..< caret, replacement: replacement, caretUTF16: replacement.utf16.count)
        }

        /// Parses a list/quote/checkbox marker at the start of `line`, returning
        /// the marker prefix's character count and the marker to write on the
        /// continued line (indent preserved, ordered numbers incremented,
        /// checkboxes reset to unchecked). Nil for non-list lines.
        static func listContinuationMarker(of line: Substring) -> (prefixCount: Int, continuation: String)? {
            let chars = Array(line)
            var i = 0
            while i < chars.count, chars[i] == " " { i += 1 }
            let indent = String(repeating: " ", count: i)
            guard i < chars.count else { return nil }

            // Blockquote: a run of '>' and spaces.
            if chars[i] == ">" {
                var j = i
                while j < chars.count, chars[j] == ">" || chars[j] == " " { j += 1 }
                var cont = String(chars[0..<j])
                if !cont.hasSuffix(" ") { cont += " " }
                return (j, cont)
            }

            let bullet = chars[i]
            if bullet == "-" || bullet == "*" || bullet == "+" {
                guard i + 1 < chars.count, chars[i + 1] == " " else { return nil }
                // Checkbox: bullet space '[' (space|x|X) ']' (space)
                if i + 4 < chars.count, chars[i + 2] == "[",
                   chars[i + 3] == " " || chars[i + 3] == "x" || chars[i + 3] == "X",
                   chars[i + 4] == "]" {
                    let trailingSpace = i + 5 < chars.count && chars[i + 5] == " "
                    return (trailingSpace ? i + 6 : i + 5, indent + String(bullet) + " [ ] ")
                }
                return (i + 2, indent + String(bullet) + " ")
            }

            // Ordered: 1–9 digits, then '.'/')' , then a space.
            var d = i
            while d < chars.count, chars[d].isNumber { d += 1 }
            let digits = d - i
            guard digits >= 1, digits <= 9,
                  d < chars.count, chars[d] == "." || chars[d] == ")",
                  d + 1 < chars.count, chars[d + 1] == " " else { return nil }
            let next = (Int(String(chars[i..<d])) ?? 0) + 1
            return (d + 2, indent + String(next) + String(chars[d]) + " ")
        }

        /// The pure computation behind Tab/⇧Tab list indenting: which
        /// UTF-16 line span to replace, with what, and where the caret
        /// lands within the replacement. Nil when any touched line isn't a
        /// list-item line (Tab falls through to plain insertion); a no-op
        /// outdent returns an empty edit (`isNoop`), which swallows the key.
        struct ListIndentEdit {
            let utf16Range: Range<Int>
            let replacement: String
            let caretUTF16: Int
            let isNoop: Bool

            func byteEdit(inText sourceText: String) -> (ByteRange, String, Int?)? {
                guard !isNoop,
                      let byteRange = EditMapping.utf8Range(
                        inText: sourceText, utf16Range: utf16Range) else { return nil }
                return (byteRange, replacement,
                        EditMapping.utf8Offset(inText: replacement, utf16Offset: caretUTF16))
            }
        }

        static func listIndentEdit(
            sourceText: String, selection: NSRange, outdent: Bool
        ) -> ListIndentEdit? {
            let sourceNS = sourceText as NSString
            guard NSMaxRange(selection) <= sourceNS.length else { return nil }
            let linesRange = sourceNS.lineRange(for: selection)
            let lines = sourceNS.substring(with: linesRange)
            // lineRange includes the trailing newline; splitting with it
            // would add a phantom empty "line" that fails the marker check.
            let hadNewline = lines.hasSuffix("\n")
            let body = hadNewline ? String(lines.dropLast()) : lines

            // Every touched line must be a list-item line — a mixed
            // selection (item + continuation paragraph) falls through.
            let split = body.split(separator: "\n", omittingEmptySubsequences: false)
            let widths = split.map { listMarkerWidth(of: $0) }
            guard !widths.isEmpty, widths.allSatisfy({ $0 != nil }) else { return nil }

            var replacementLines: [String] = []
            var caretShift = 0  // UTF-16 shift of the caret within linesRange
            var lineStart = 0   // running UTF-16 offset of the line inside `lines`
            let caretInLines = selection.location - linesRange.location
            for (line, width) in zip(split, widths) {
                let step = width ?? 2
                let delta: Int
                if outdent {
                    let leading = line.prefix(while: { $0 == " " }).count
                    delta = -min(leading, step)
                    replacementLines.append(String(line.dropFirst(-delta)))
                } else {
                    delta = step
                    replacementLines.append(String(repeating: " ", count: step) + line)
                }
                // The caret keeps its place in the TEXT: shift it by every
                // change at or before it. On the caret's own line an outdent
                // can only consume the spaces left of the caret.
                if caretInLines >= lineStart {
                    if delta > 0 {
                        caretShift += delta
                    } else {
                        caretShift -= min(caretInLines - lineStart, -delta)
                    }
                }
                lineStart += line.utf16.count + 1
            }
            let replacement = replacementLines.joined(separator: "\n")
                + (hadNewline ? "\n" : "")
            let caretUTF16 = max(0, min(caretInLines + caretShift, replacement.utf16.count))
            return ListIndentEdit(
                utf16Range: linesRange.location..<NSMaxRange(linesRange),
                replacement: replacement,
                caretUTF16: caretUTF16,
                isNoop: replacement == lines)
        }

        func blockID(atCharIndex index: Int) -> BlockID? {
            // Ranges include their trailing separator, so boundaries can
            // match two blocks; prefer the strictly-containing (earlier) one
            // deterministically by picking the largest containing start.
            rangeIndex.blockID(at: index)
        }

        /// Enumerates the blocks whose ranges intersect `query`, in
        /// document order — binary-searched, so viewport-scoped passes
        /// (focus dimming) touch only on-screen blocks.
        func forEachBlockRange(intersecting query: NSRange, _ body: (BlockID, NSRange) -> Void) {
            rangeIndex.forEachEntry(intersecting: query, body)
        }

        /// Sorted-ranges index (ledger perf #11). Entries are sorted by
        /// location; `prefixMaxEnd` is the non-decreasing running max of
        /// range ends, which lets containment walks and intersection scans
        /// stop with binary searches even though neighboring block ranges
        /// can overlap at their boundaries (trailing separators).
        struct BlockRangeIndex {
            private let entries: [(range: NSRange, id: BlockID)]
            private let prefixMaxEnd: [Int]
            /// For `topVisibleBlockID`: the storage attribute carries the
            /// id's STRING form; resolving it used to allocate a
            /// description per key per scroll tick.
            let idsByDescription: [String: BlockID]

            init(_ blockRanges: [BlockID: NSRange]) {
                var sorted = blockRanges.map { (range: $0.value, id: $0.key) }
                sorted.sort {
                    if $0.range.location != $1.range.location {
                        return $0.range.location < $1.range.location
                    }
                    if $0.range.length != $1.range.length {
                        return $0.range.length < $1.range.length
                    }
                    // Deterministic order for exact duplicates.
                    return ($0.id.contentHash, $0.id.occurrence)
                        < ($1.id.contentHash, $1.id.occurrence)
                }
                entries = sorted
                var runningMax = 0
                prefixMaxEnd = sorted.map { entry in
                    runningMax = max(runningMax, NSMaxRange(entry.range))
                    return runningMax
                }
                var byDescription = [String: BlockID](minimumCapacity: sorted.count)
                for entry in sorted { byDescription[entry.id.description] = entry.id }
                idsByDescription = byDescription
            }

            /// Containment query with the historical tie-break: among
            /// ranges containing `index`, the largest location wins.
            func blockID(at index: Int) -> BlockID? {
                // Binary search: first entry with location > index.
                var lo = 0, hi = entries.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if entries[mid].range.location <= index { lo = mid + 1 } else { hi = mid }
                }
                // Walk back while a containing range is still possible;
                // the first hit has the largest location by construction.
                var i = lo - 1
                while i >= 0, prefixMaxEnd[i] > index {
                    let range = entries[i].range
                    if index >= range.location, index < NSMaxRange(range) {
                        return entries[i].id
                    }
                    i -= 1
                }
                return nil
            }

            func forEachEntry(intersecting query: NSRange, _ body: (BlockID, NSRange) -> Void) {
                guard !entries.isEmpty else { return }
                // First candidate: the first entry whose running max end
                // exceeds the query start (prefixMaxEnd is non-decreasing).
                var lo = 0, hi = entries.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if prefixMaxEnd[mid] <= query.location { lo = mid + 1 } else { hi = mid }
                }
                let queryEnd = NSMaxRange(query)
                var i = lo
                while i < entries.count, entries[i].range.location < queryEnd {
                    if NSIntersectionRange(entries[i].range, query).length > 0 {
                        body(entries[i].id, entries[i].range)
                    }
                    i += 1
                }
            }
        }

        /// True when the character sits in an embed block (code/math/mermaid
        /// /table) that flips to source on double-click, not single click.
        func isEmbedBlock(atCharIndex index: Int) -> Bool {
            guard let storage = textView?.textContentStorage?.textStorage,
                  index >= 0, index < storage.length else { return false }
            return storage.attribute(QuoinAttribute.embedBlock, at: index, effectiveRange: nil) != nil
        }

        /// Attachment embeds (diagrams, equations) are presentation
        /// objects: they open ONLY through explicit intent — the ‹/› edit
        /// chip, ⌘↩, or the context menu — never a double-click or a stray
        /// keystroke (ledger #7).
        func isChipOnlyEmbed(atCharIndex index: Int) -> Bool {
            guard let storage = textView?.textContentStorage?.textStorage,
                  index >= 0, index < storage.length,
                  isEmbedBlock(atCharIndex: index) else { return false }
            return storage.attribute(QuoinAttribute.diagramSource, at: index, effectiveRange: nil) != nil
                || storage.attribute(QuoinAttribute.mathSource, at: index, effectiveRange: nil) != nil
        }

        /// Double-click on an embed block flips it to editable source
        /// (QuoinTextView routes the gesture here). The caret lands at the
        /// source position matching the click: code bodies map exactly
        /// (1:1 with source content); embeds without a body marker (tables,
        /// math, diagrams) fall back to the raw rendered offset, which the
        /// model's rendered↔source alignment maps — the same machinery that
        /// keeps prose and list clicks exact. The old nil fallback dumped
        /// the caret at the BLOCK END, and the caret-line pin then dragged
        /// the last line up to the click.
        @discardableResult
        func activateEmbedBlock(atCharIndex index: Int) -> Bool {
            guard isEmbedBlock(atCharIndex: index),
                  !isChipOnlyEmbed(atCharIndex: index),
                  let id = blockID(atCharIndex: index),
                  id != parent.rendered.activeBlockID else { return false }
            let hint: CaretHint? = caretHint(forActivationAt: index, blockID: id)
            parent.onActivateBlock?(id, hint, nil)
            return true
        }

        /// Where the caret should land when an embed block flips to source.
        /// The rendered code body is character-for-character 1:1 with the
        /// source content (the copy button and edit mapping depend on it),
        /// so a double-click INSIDE the body maps exactly: source content
        /// start + the click's offset into the rendered body. The old
        /// content-start-only shortcut teleported the caret to the block's
        /// first line — and the caret-line viewport pin then dragged line 1
        /// down to the clicked position, lurching the whole block. Clicks
        /// outside the body (header chip, attachment) keep the
        /// content-start fallback.
        func embedCaretHint(atCharIndex index: Int) -> Int? {
            guard let storage = textView?.textContentStorage?.textStorage,
                  let id = blockID(atCharIndex: index),
                  let blockRange = blockRanges[id] else { return nil }
            var contentStart: Int?
            var bodyRange: NSRange?
            let clamped = NSRange(
                location: blockRange.location,
                length: min(blockRange.length, storage.length - blockRange.location)
            )
            storage.enumerateAttribute(QuoinAttribute.embedSourceStart, in: clamped) { value, range, stop in
                if let start = value as? NSNumber {
                    contentStart = start.intValue
                    bodyRange = range
                    stop.pointee = true
                }
            }
            guard let contentStart else { return nil }
            if let bodyRange, index >= bodyRange.location, index <= NSMaxRange(bodyRange) {
                return contentStart + (index - bodyRange.location)
            }
            return contentStart
        }

        /// The caret hint for activating `id` from a click/selection at `index`:
        /// an embed maps to a SOURCE offset (1:1 body tag), prose to a RENDERED
        /// offset within the block. Feeding one space's offset through the
        /// other's mapping re-ships the caret-lands-early bug, so this is the
        /// one place the choice is made.
        func caretHint(forActivationAt index: Int, blockID id: BlockID) -> CaretHint? {
            embedCaretHint(atCharIndex: index).map { .source($0) }
                ?? blockRanges[id].map { .rendered(index - $0.location) }
        }

        // MARK: Scroll anchoring

        /// The block's full on-screen rect (viewport coordinates: y is the
        /// distance from the viewport's top), or nil when geometry is
        /// unavailable. The flip motion system measures the flipped block
        /// with this on both sides of the splice.
        func blockScreenRect(_ range: NSRange, in textView: NSTextView) -> CGRect? {
            guard let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let textRange = nsTextRange(range, in: contentStorage),
                  let clip = textView.enclosingScrollView?.contentView
            else { return nil }
            layoutManager.ensureLayout(for: textRange)
            var union: CGRect?
            layoutManager.enumerateTextLayoutFragments(
                from: textRange.location, options: [.ensuresLayout]
            ) { fragment in
                if fragment.rangeInElement.location.compare(textRange.endLocation) != .orderedAscending {
                    return false
                }
                let frame = fragment.layoutFragmentFrame
                union = union.map { $0.union(frame) } ?? frame
                return true
            }
            guard var rect = union else { return nil }
            rect.origin.x = 0
            rect.origin.y += textView.textContainerOrigin.y - clip.bounds.origin.y
            rect.size.width = clip.bounds.width
            return rect
        }

        /// The motion layer for activate/deactivate flips; owned here so it
        /// shares the view lifetime.
        var flipTransition: FlipTransitionController?

        /// Pre-splice gate for the flip snapshot (ledger perf #9): most
        /// prose clicks produce `Plan.none` — the reveal keeps the block's
        /// vertical skeleton, so |Δh| ≤ 40 — yet the viewport+overscan was
        /// rasterized BEFORE the plan could say so. The plan's inputs are
        /// (conservatively) knowable beforehand: document length and
        /// viewport height exactly; the new block's height estimated by
        /// measuring its already-rendered fragment. Skipping is safe by
        /// construction: no capture just means no cosmetic overlay (`run`
        /// bails on a nil pending capture); the real layout applies
        /// instantly either way. The margin (16 vs the plan's 40pt
        /// threshold) absorbs boundingRect-vs-TextKit-2 estimate error;
        /// anything ambiguous captures exactly as before.
        func flipCaptureWorthwhile(
            oldBlockRect: CGRect, flipID: BlockID, rendered: RenderedDocument,
            viewportHeight: CGFloat, in textView: NSTextView
        ) -> Bool {
            // Exact plan inputs: these alone force .none.
            guard rendered.attributed.length < 200_000, viewportHeight > 0 else { return false }
            guard let newRange = rendered.blockRanges[flipID],
                  NSMaxRange(newRange) <= rendered.attributed.length,
                  newRange.length <= 20_000, // don't burn time estimating giants
                  let container = textView.textContainer
            else { return true } // can't estimate — capture, as before
            let width = container.size.width - 2 * container.lineFragmentPadding
            guard width > 50 else { return true }
            let fragment = rendered.attributed.attributedSubstring(from: newRange)
            let estimated = fragment.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height
            return abs(estimated - oldBlockRect.height) > 16
        }

        /// The side-by-side preview panel (ledger #6b), created lazily and
        /// repositioned from the editing frame's drawn geometry. Its
        /// presentation runs through the choreographer — the raw per-draw
        /// stream never reaches Core Animation directly.
        private var previewPanel: PreviewPanelView?
        private var panelChoreographer = PreviewPanelChoreographer()
        private var panelBadgeVisible = false
        private var panelRecheck: DispatchWorkItem?
        private var lastPanelFrameBox: CGRect?

        /// Minimum source-column width before the panel yields (narrow
        /// windows: readable source beats a squeezed preview — ~44 mono
        /// chars, enough for a real mermaid edge line).
        private static let minimumSourceWidth: CGFloat = 340

        /// The badge is two words; the full explanation rides its tooltip.
        private func statusTooltip(for panel: RenderedDocument.PreviewPanel) -> String? {
            panel.statusMessage == nil ? nil
                : "The source doesn't parse yet. The last valid render stays until it does."
        }

        /// Re-plans the preview panel against the last known editing-frame
        /// geometry. Needed because the draw-pass geometry callback is
        /// deduped by rect (ledger perf #10): a new preview image behind
        /// an UNCHANGED frame no longer re-fires it, so the projection
        /// path must re-plan explicitly.
        func refreshPreviewPanelForProjectionChange() {
            updatePreviewPanel(editingFrame: lastPanelFrameBox)
        }

        /// Shows/hides/positions the preview panel for the current
        /// projection. `frameBox` is the drawn editing frame in text-view
        /// coordinates (nil = no open block).
        func updatePreviewPanel(editingFrame frameBox: CGRect?) {
            guard let textView else { return }
            if QuoinPerformanceTrace.isEnabled {
                let panel = parent.rendered.previewPanel
                let panelDesc = panel.map {
                    "img@\(UInt(bitPattern: ObjectIdentifier($0.image).hashValue) % 100_000)"
                } ?? "nil"
                QuoinPerformanceTrace.log(
                    "panel.update", startedAt: DispatchTime.now().uptimeNanoseconds,
                    metadata: "frame=\(frameBox.map { Int($0.minY) } ?? -1) "
                        + "panel=\(panelDesc)"
                        + " status=\(panel?.statusMessage != nil) active=\(parent.rendered.activeBlockID != nil) rev=\(parent.rendered.revision)")
            }
            lastPanelFrameBox = frameBox
            panelRecheck?.cancel()
            panelRecheck = nil
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let panelWidth = AttributedRenderer.previewPanelWidth
            guard let frameBox,
                  let panel = parent.rendered.previewPanel,
                  parent.rendered.activeBlockID != nil,
                  frameBox.width - panelWidth >= Self.minimumSourceWidth else {
                panelChoreographer.reset()
                panelBadgeVisible = false
                previewPanel?.dismiss()
                if let quoinView = textView as? QuoinTextView,
                   quoinView.editingFrameTintOverride != nil {
                    quoinView.editingFrameTintOverride = nil
                    quoinView.redrawDecorations()
                }
                return
            }
            let view: PreviewPanelView
            if let existing = previewPanel {
                view = existing
            } else {
                view = PreviewPanelView(frame: .zero)
                textView.addSubview(view)
                previewPanel = view
            }

            let plan = panelChoreographer.plan(
                for: .init(image: panel.image,
                           paused: panel.statusMessage != nil,
                           revision: parent.rendered.revision),
                at: ProcessInfo.processInfo.systemUptime)
            // A mounted flip cover owns the transition — the panel
            // presents directly beneath it. (The coordinator always runs
            // on main; the controller is @MainActor.)
            var suppress = reduceMotion
            if let flipTransition,
               MainActor.assumeIsolated({ flipTransition.isCovering }) {
                suppress = true
            }
            view.apply(plan, in: frameBox, panelWidth: panelWidth,
                       statusMessage: statusTooltip(for: panel),
                       suppressAnimation: suppress)
            // Ambient status at the locus's edge: the editing frame's
            // stroke turns amber while paused is ADMITTED (a cut, not a
            // fade — binary signals that fade read as uncertainty).
            let tint: NSColor? = plan.showsPausedBadge ? .systemOrange : nil
            if let quoinView = textView as? QuoinTextView,
               quoinView.editingFrameTintOverride != tint {
                quoinView.editingFrameTintOverride = tint
                quoinView.redrawDecorations()
            }

            // VoiceOver hears pause/resume when the badge transitions —
            // silence would strand a non-sighted user on a frozen artifact.
            if plan.showsPausedBadge != panelBadgeVisible {
                NSAccessibility.post(
                    element: textView,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: plan.showsPausedBadge
                            ? "Preview paused — showing the last good render"
                            : "Preview resumed",
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                    ])
            }
            panelBadgeVisible = plan.showsPausedBadge

            // A swap or badge decision is pending on time — re-evaluate
            // exactly when the choreographer asked.
            if let after = plan.recheckAfter {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.updatePreviewPanel(editingFrame: self.lastPanelFrameBox)
                }
                panelRecheck = work
                DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
            }
        }

        /// The on-screen y (distance from the viewport's top) of a block's
        /// first laid-out fragment, or nil when geometry is unavailable.
        /// Captured BEFORE an activate/deactivate splice so the flipped
        /// block can be pinned at the same place afterward.
        func blockTopScreenY(_ range: NSRange, in textView: NSTextView) -> CGFloat? {
            guard let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let textRange = nsTextRange(range, in: contentStorage),
                  let clip = textView.enclosingScrollView?.contentView
            else { return nil }
            layoutManager.ensureLayout(for: textRange)
            guard let fragment = layoutManager.textLayoutFragment(for: textRange.location) else { return nil }
            let documentY = fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y
            return documentY - clip.bounds.origin.y
        }

        /// Scrolls so the block's top sits at `screenY` from the viewport's
        /// top. Forcing layout for the block's new range FIRST matters twice
        /// over: the scroll math needs real (not estimated) geometry, and an
        /// un-laid-out splice region is what briefly draws overlapping
        /// lines. Content above the splice is untouched by the flip, so the
        /// fragment frame is exact once the range itself is laid out.
        func scrollBlockTop(_ range: NSRange, toScreenY screenY: CGFloat, in textView: NSTextView,
                            settle: Bool = true) {
            guard let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let textRange = nsTextRange(range, in: contentStorage),
                  let clip = textView.enclosingScrollView?.contentView
            else { return }
            layoutManager.ensureLayout(for: textRange)
            guard let fragment = layoutManager.textLayoutFragment(for: textRange.location) else { return }
            let documentY = fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y
            let y = max(0, documentY - screenY)
            // Height-neutral reveals leave the pin where it already is —
            // don't touch the clip view for a sub-point correction, or
            // keyboard traversal picks up a micro-jitter at every block
            // boundary.
            if abs(y - clip.bounds.origin.y) > 0.5 {
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                textView.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            guard settle else { return }
            // Second pass after TextKit resolves estimated geometry for the
            // spliced region (see pinCaretLine — same lie, same cure).
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView,
                      let layoutManager = textView.textLayoutManager else { return }
                if let viewport = layoutManager.textViewportLayoutController.viewportRange {
                    layoutManager.ensureLayout(for: viewport)
                }
                self.scrollBlockTop(range, toScreenY: screenY, in: textView, settle: false)
            }
        }

        /// The on-screen y of the LINE containing `location` (distance from
        /// the viewport's top), or nil when geometry is unavailable. This is
        /// the anchor for the viewport invariant: the line the user touched.
        func lineScreenY(at location: Int, in textView: NSTextView) -> CGFloat? {
            guard location >= 0,
                  let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let textRange = nsTextRange(NSRange(location: location, length: 0), in: contentStorage),
                  let clip = textView.enclosingScrollView?.contentView
            else { return nil }
            layoutManager.ensureLayout(for: textRange)
            guard let fragment = layoutManager.textLayoutFragment(for: textRange.location) else { return nil }
            return fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y - clip.bounds.origin.y
        }

        /// Scrolls so the line containing `location` sits at `screenY` from
        /// the viewport top — restoring the user's point of attention after
        /// a projection change, whatever happened to the heights around it.
        ///
        /// TWO passes, because TextKit 2 lies at first: the immediate pin
        /// measures against whatever geometry exists NOW — and a fresh
        /// splice's heights are ESTIMATES that can settle hundreds of points
        /// away (a link-heavy list wraps its revealed source; a block
        /// spanning the fold resolves lazily). The reported symptom: click a
        /// list item near the fold and the whole list dives down-screen.
        /// So: eagerly lay out the revealed block first (real within-block
        /// geometry), pin, then re-pin on the next runloop turn after
        /// ensuring the viewport's real layout — idempotent, and a no-op
        /// when the first pin was already right.
        func pinCaretLine(
            at location: Int, toScreenY screenY: CGFloat, in textView: NSTextView,
            ensuringLayoutOf blockRange: NSRange? = nil, settle: Bool = true
        ) {
            guard let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let textRange = nsTextRange(NSRange(location: location, length: 0), in: contentStorage),
                  let clip = textView.enclosingScrollView?.contentView
            else { return }
            if let blockRange, let blockTextRange = nsTextRange(blockRange, in: contentStorage) {
                layoutManager.ensureLayout(for: blockTextRange)
            }
            // Settle the viewport's real geometry BEFORE measuring: the
            // immediate pin otherwise scrolls against estimates and the
            // async correction lands a frame later — a visible double-hop
            // (traced live at 125pt on a fold-straddling list).
            if settle, let viewport = layoutManager.textViewportLayoutController.viewportRange {
                layoutManager.ensureLayout(for: viewport)
            }
            layoutManager.ensureLayout(for: textRange)
            guard let fragment = layoutManager.textLayoutFragment(for: textRange.location) else { return }
            let documentY = fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y
            let y = max(0, documentY - screenY)
            QuoinPerformanceTrace.log(
                "anchor.pinCaretLine", startedAt: DispatchTime.now().uptimeNanoseconds,
                metadata: "loc=\(location) targetScreenY=\(Int(screenY)) docY=\(Int(documentY)) clipY=\(Int(clip.bounds.origin.y)) newY=\(Int(y)) settlePass=\(!settle)")
            if abs(y - clip.bounds.origin.y) > 0.5 {
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                textView.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            guard settle else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView,
                      let layoutManager = textView.textLayoutManager else { return }
                // Settle the geometry the user is about to see, then correct.
                if let viewport = layoutManager.textViewportLayoutController.viewportRange {
                    layoutManager.ensureLayout(for: viewport)
                }
                self.pinCaretLine(at: location, toScreenY: screenY, in: textView,
                                  ensuringLayoutOf: blockRange, settle: false)
            }
        }

        /// Scrolls only when the caret is NOT already visible — and then by
        /// the minimal amount, using settled layout. Arrowing through a
        /// document must feel native: no scroll while the caret is on
        /// screen, one small nudge when it crosses the fold. The old
        /// unconditional `scrollRangeToVisible` re-scrolled on every block
        /// activation (against TextKit 2's estimates, no less), which is
        /// what made keyboard traversal lurch at block boundaries.
        func scrollCaretIntoViewIfNeeded(_ location: Int, in textView: NSTextView) {
            guard let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let textRange = nsTextRange(NSRange(location: location, length: 0), in: contentStorage),
                  let clip = textView.enclosingScrollView?.contentView
            else {
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
                return
            }
            layoutManager.ensureLayout(for: textRange)
            guard let fragment = layoutManager.textLayoutFragment(for: textRange.location) else {
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
                return
            }
            let origin = textView.textContainerOrigin
            let lineTop = fragment.layoutFragmentFrame.minY + origin.y
            let lineBottom = fragment.layoutFragmentFrame.maxY + origin.y
            let visibleTop = clip.bounds.origin.y
            let visibleBottom = visibleTop + clip.bounds.height
            let padding: CGFloat = 8
            var target: CGFloat?
            if lineTop < visibleTop + padding {
                target = max(0, lineTop - padding)
            } else if lineBottom > visibleBottom - padding {
                target = lineBottom + padding - clip.bounds.height
            }
            guard let target, abs(target - visibleTop) > 0.5 else { return }
            QuoinPerformanceTrace.log(
                "anchor.caretIntoView", startedAt: DispatchTime.now().uptimeNanoseconds,
                metadata: "loc=\(location) from=\(Int(visibleTop)) to=\(Int(target))")
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, target)))
            textView.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        /// The block ID at the top of the current viewport, used to keep the
        /// reading position stable across live reloads.
        /// Jump-to-section scroll that works with TextKit 2's lazy layout:
        /// force layout up to the target range first (otherwise its rect is an
        /// estimate and the scroll lands in the wrong place, or nowhere), then
        /// align the block near the top of the viewport.
        func scrollBlockToTop(_ range: NSRange, in textView: NSTextView) {
            guard let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let textRange = nsTextRange(range, in: contentStorage) else {
                textView.scrollRangeToVisible(range)
                return
            }
            layoutManager.ensureLayout(for: textRange)
            guard let fragment = layoutManager.textLayoutFragment(for: textRange.location) else {
                textView.scrollRangeToVisible(range)
                return
            }
            let origin = textView.textContainerOrigin
            let top = fragment.layoutFragmentFrame.minY + origin.y
            if let clip = textView.enclosingScrollView?.contentView {
                let maxY = max(0, (textView.bounds.height) - clip.bounds.height)
                // Pin the target fragment's top exactly at the viewport top so
                // the section sampler (which probes just below the top) reads
                // this block, not the previous one. A heading's own spacing-
                // before still supplies the visual breathing room; an 8pt gap
                // here put the previous block at the very top and made the
                // outline highlight the section above on a jump.
                let y = min(max(0, top), maxY)
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                textView.enclosingScrollView?.reflectScrolledClipView(clip)
            } else {
                textView.scrollRangeToVisible(range)
            }
        }

        func topVisibleBlockID(in textView: NSTextView) -> BlockID? {
            guard let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager,
                  let storage = textView.textContentStorage?.textStorage, storage.length > 0
            else { return nil }
            // Ask TextKit 2 which layout fragment owns the top of the viewport.
            // Unlike characterIndexForInsertion, a fragment's frame includes its
            // 28–32pt heading spacing-before, so a heading pinned (or scrolled)
            // to the top resolves to the heading itself — not the tail of the
            // previous block, which was highlighting the section above (−1).
            let origin = textView.textContainerOrigin
            let y = textView.visibleRect.minY - origin.y + 1
            let point = CGPoint(x: 1, y: max(0, y))
            guard let fragment = layoutManager.textLayoutFragment(for: point) else { return nil }
            let offset = layoutManager.offset(
                from: contentManager.documentRange.location, to: fragment.rangeInElement.location
            )
            guard offset >= 0, offset < storage.length,
                  let idString = storage.attribute(QuoinAttribute.blockID, at: offset, effectiveRange: nil) as? String
            else { return nil }
            return rangeIndex.idsByDescription[idString]
        }

        // MARK: Search highlighting

        /// Debounce for the document-wide match scan (ledger perf #5):
        /// while search is active, EVERY projection change used to rescan
        /// the whole document synchronously in the same pass (updateNSView
        /// nils `appliedQuery` on new content), and every find-bar
        /// keystroke rescanned immediately. Bursts now coalesce into one
        /// scan shortly after the last change.
        static let searchDebounceInterval: TimeInterval = 0.12
        private var pendingSearchScan: DispatchWorkItem?
        private var pendingSearchKey: PendingSearchKey?
        private struct PendingSearchKey: Equatable {
            let query: String
            let ordinal: Int
            let revision: Int
            let options: SearchOptions
            let inSelection: Bool
        }

        func applySearch(
            query: String, activeOrdinal: Int,
            options: SearchOptions = SearchOptions(), inSelection: Bool = false
        ) {
            guard query != appliedQuery || activeOrdinal != appliedOrdinal
                    || options != appliedOptions || inSelection != appliedInSelection else {
                // Already applied — a still-pending scan can only be for a
                // stale intermediate query (typed and reverted); drop it.
                cancelPendingSearchScan()
                return
            }
            guard let textView,
                  let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage
            else { return }

            // A regex pattern's leading/trailing whitespace is significant;
            // only a literal query is trimmed (a whitespace-only literal is
            // a no-op, never a document of blanks highlighted).
            let searchTerm = options.regex ? query : query.trimmingCharacters(in: .whitespaces)

            // Clearing (find bar closed / emptied) stays immediate:
            // lingering highlights read as broken.
            guard !searchTerm.isEmpty else {
                cancelPendingSearchScan()
                if hasAppliedSearchHighlights {
                    layoutManager.removeRenderingAttribute(.backgroundColor, for: contentStorage.documentRange)
                    hasAppliedSearchHighlights = false
                }
                matchRanges = []
                appliedQuery = query
                appliedOrdinal = activeOrdinal
                appliedOptions = options
                appliedInSelection = inSelection
                parent.onMatchCount(0)
                return
            }

            // ⌘G cycling: same query + options over the same content —
            // recolor the two ordinals and scroll; never rescan the document.
            if query == appliedQuery, options == appliedOptions,
               inSelection == appliedInSelection, activeOrdinal != appliedOrdinal {
                let theme = parent.theme
                if appliedOrdinal >= 0, appliedOrdinal < matchRanges.count,
                   let textRange = nsTextRange(matchRanges[appliedOrdinal], in: contentStorage) {
                    layoutManager.addRenderingAttribute(
                        .backgroundColor,
                        value: theme.searchHighlight.withAlphaComponent(0.35), for: textRange)
                }
                if activeOrdinal >= 0, activeOrdinal < matchRanges.count,
                   let textRange = nsTextRange(matchRanges[activeOrdinal], in: contentStorage) {
                    layoutManager.addRenderingAttribute(
                        .backgroundColor, value: theme.searchHighlight, for: textRange)
                    textView.scrollRangeToVisible(matchRanges[activeOrdinal])
                }
                appliedOrdinal = activeOrdinal
                parent.onMatchCount(matchRanges.count)
                return
            }

            // Query change or content change (appliedQuery is nilled per
            // projection): debounce the whole-document scan. A repeat call
            // with the same pending key must NOT push the deadline —
            // unrelated updateNSView passes would otherwise starve the scan.
            let key = PendingSearchKey(
                query: query, ordinal: activeOrdinal, revision: appliedRevision,
                options: options, inSelection: inSelection)
            guard key != pendingSearchKey else { return }
            cancelPendingSearchScan()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingSearchScan = nil
                self.pendingSearchKey = nil
                self.performSearchScan(
                    query: query, activeOrdinal: activeOrdinal,
                    options: options, inSelection: inSelection)
            }
            pendingSearchScan = work
            pendingSearchKey = key
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.searchDebounceInterval, execute: work)
        }

        private func cancelPendingSearchScan() {
            pendingSearchScan?.cancel()
            pendingSearchScan = nil
            pendingSearchKey = nil
        }

        /// The document-wide scan + repaint — the old synchronous body of
        /// `applySearch`, now behind the debounce. Internal for the
        /// latency budget test.
        func performSearchScan(
            query: String, activeOrdinal: Int,
            options: SearchOptions = SearchOptions(), inSelection: Bool = false
        ) {
            guard let textView,
                  let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let storage = contentStorage.textStorage
            else { return }
            let searchTerm = options.regex ? query : query.trimmingCharacters(in: .whitespaces)
            defer {
                appliedQuery = query
                appliedOrdinal = activeOrdinal
                appliedOptions = options
                appliedInSelection = inSelection
                parent.onMatchCount(matchRanges.count)
            }

            // Clear previous highlights across the whole document, not just
            // the remembered match ranges: after an incremental splice those
            // NSRanges are pre-edit coordinates, so clearing at the shifted
            // locations would leave stale highlights behind. Skip this entirely
            // when search has not painted highlights; large-document edits with
            // inactive search should not touch the whole TextKit document.
            if hasAppliedSearchHighlights {
                layoutManager.removeRenderingAttribute(.backgroundColor, for: contentStorage.documentRange)
                hasAppliedSearchHighlights = false
            }
            matchRanges = []
            guard !searchTerm.isEmpty else { return }

            let haystack = storage.string as NSString
            // In-Selection scopes the scan to the current selection; with no
            // selection the option is inert (whole document), matching the
            // platform's Find behavior.
            var scope: NSRange?
            if inSelection {
                let selection = textView.selectedRange()
                if selection.length > 0 { scope = selection }
            }
            // ONE matcher drives BOTH the highlight/count here and
            // SourceReplace, so a query can never mean different occurrences
            // to the "1 of 3" and to Replace-All (#23). A nil result is an
            // invalid regex — highlight nothing; the find bar shows the
            // invalid state independently (TextMatcher.isValidQuery).
            matchRanges = TextMatcher.matches(
                of: searchTerm, in: haystack, options: options, within: scope) ?? []

            let theme = parent.theme
            for (index, range) in matchRanges.enumerated() {
                guard let textRange = nsTextRange(range, in: contentStorage) else { continue }
                let color = index == activeOrdinal
                    ? theme.searchHighlight
                    : theme.searchHighlight.withAlphaComponent(0.35)
                layoutManager.addRenderingAttribute(.backgroundColor, value: color, for: textRange)
            }
            hasAppliedSearchHighlights = !matchRanges.isEmpty

            if activeOrdinal >= 0, activeOrdinal < matchRanges.count {
                textView.scrollRangeToVisible(matchRanges[activeOrdinal])
            }
        }

    }
}
#endif


#if canImport(AppKit)
/// The card→mark flash: a pass-through accent ring that fades out.
final class FlashRingView: NSView {
    var strokeColor: PlatformColor = .controlAccentColor
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(CGPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.setStrokeColor(strokeColor.cgColor)
        context.setLineWidth(2)
        context.strokePath()
    }
}
#endif
