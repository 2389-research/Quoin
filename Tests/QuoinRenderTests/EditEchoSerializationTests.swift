#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Ledger #11 — fast typing raced the edit round-trip: a keystroke
/// arriving before the previous edit's projection echo computed its range
/// against STALE coordinates and scrambled into neighboring text (field
/// report: "edits swallowed in the source, persisted forever in the
/// chart" — a relationship label reading 'containsininnao'). Keystrokes
/// arriving mid-flight must QUEUE, in order, and flush one per echo at
/// the freshly restored caret — never against stale offsets.
final class EditEchoSerializationTests: XCTestCase {

    private struct SentEdit {
        let range: ByteRange
        let text: String
    }

    private func makeHarness() throws -> (
        coordinator: MarkdownReaderView.Coordinator,
        textView: QuoinTextView,
        sent: () -> [SentEdit]
    ) {
        let source = "# T\n\n```mermaid\nflowchart TD\n    A --> B\n```\n\nTail.\n"
        let document = MarkdownConverter.parse(source)
        let block = try XCTUnwrap(document.blocks.first {
            if case .mermaid = $0.kind { return true }
            return false
        })
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let editing = renderer.render(document, activeBlockID: block.id, activeCaret: 0, cache: &cache)

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), textContainer: container)
        textView.textContentStorage?.textStorage?.setAttributedString(editing.attributed)

        final class Box { var edits: [SentEdit] = [] }
        let box = Box()
        let view = MarkdownReaderView(
            rendered: RenderedDocument(
                attributed: editing.attributed, blockRanges: editing.blockRanges,
                activeBlockID: block.id, activeEditableRange: editing.activeEditableRange,
                activeSourceText: editing.activeSourceText),
            onEditIntent: { range, text, _ in box.edits.append(SentEdit(range: range, text: text)) },
            onActivateBlock: { _, _, _ in }
        )
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView
        coordinator.blockRanges = editing.blockRanges
        return (coordinator, textView, { box.edits })
    }

    func testMidFlightKeystrokesQueueAndFlushInOrder() throws {
        let (coordinator, textView, sent) = try makeHarness()
        let active = try XCTUnwrap(coordinator.parent.rendered.activeEditableRange)
        let caret = active.location + 12
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        // Keystroke 1 goes straight through and opens the flight window.
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: caret, length: 0),
            replacementString: "a")
        XCTAssertEqual(sent().count, 1)

        // Keystrokes 2 and 3 arrive BEFORE the echo: they must queue —
        // computing their ranges now would use stale coordinates (the
        // scrambled-label field report).
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: caret, length: 0),
            replacementString: "b")
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: caret, length: 0),
            replacementString: "c")
        XCTAssertEqual(sent().count, 1, "mid-flight keystrokes never apply against stale ranges")

        // Echo 1 lands (caret restored one to the right): keystroke 2
        // flushes at the FRESH caret.
        textView.setSelectedRange(NSRange(location: caret + 1, length: 0))
        coordinator.noteEditEchoApplied(in: textView)
        XCTAssertEqual(sent().count, 2)
        XCTAssertEqual(sent()[1].text, "b")
        XCTAssertEqual(sent()[1].range.offset, sent()[0].range.offset + 1,
                       "queued keystroke applies at the restored caret, not the stale one")

        // Echo 2 → keystroke 3, one per ack, in order.
        textView.setSelectedRange(NSRange(location: caret + 2, length: 0))
        coordinator.noteEditEchoApplied(in: textView)
        XCTAssertEqual(sent().count, 3)
        XCTAssertEqual(sent()[2].text, "c")
        XCTAssertEqual(sent()[2].range.offset, sent()[0].range.offset + 2)

        // Queue drained; the next echo flushes nothing.
        coordinator.noteEditEchoApplied(in: textView)
        XCTAssertEqual(sent().count, 3)
    }

    func testBackspaceQueuesMidFlight() throws {
        let (coordinator, textView, sent) = try makeHarness()
        let active = try XCTUnwrap(coordinator.parent.rendered.activeEditableRange)
        let caret = active.location + 12
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: caret, length: 0),
            replacementString: "x")
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: caret - 1, length: 1),
            replacementString: "")
        XCTAssertEqual(sent().count, 1, "backspace queues like any keystroke")

        textView.setSelectedRange(NSRange(location: caret + 1, length: 0))
        coordinator.noteEditEchoApplied(in: textView)
        XCTAssertEqual(sent().count, 2)
        XCTAssertEqual(sent()[1].text, "", "the queued backspace deletes at the fresh caret")
    }

    func testWatchdogExpiryReplaysQueuedKeystrokesInsteadOfDiscarding() throws {
        // Ledger #8: a lost echo used to wedge typing for 2s and then the
        // watchdog DISCARDED the queue silently. It must replay instead:
        // the queued keystrokes are content + order, and they apply at the
        // current caret through the ordinary pipeline.
        let (coordinator, textView, sent) = try makeHarness()
        let active = try XCTUnwrap(coordinator.parent.rendered.activeEditableRange)
        let caret = active.location + 12
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: caret, length: 0),
            replacementString: "a")
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: caret, length: 0),
            replacementString: "b")
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: caret, length: 0),
            replacementString: "c")
        XCTAssertEqual(sent().count, 1)

        // The echo never arrives; the watchdog deadline passes; the user
        // keeps typing.
        coordinator.awaitingEditEchoSince -=
            MarkdownReaderView.Coordinator.editEchoWatchdogInterval + 1
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: caret, length: 0),
            replacementString: "d")

        // Unwedged: "b" flushed at the current caret (an edit, re-arming
        // the gate); "c" and "d" remain queued in order behind it.
        XCTAssertEqual(sent().count, 2, "the watchdog replays, it does not discard")
        XCTAssertEqual(sent()[1].text, "b")

        // Subsequent echoes drain the rest in order — nothing was lost.
        coordinator.noteEditEchoApplied(in: textView)
        XCTAssertEqual(sent().count, 3)
        XCTAssertEqual(sent()[2].text, "c")
        coordinator.noteEditEchoApplied(in: textView)
        XCTAssertEqual(sent().count, 4)
        XCTAssertEqual(sent()[3].text, "d")
        coordinator.noteEditEchoApplied(in: textView)
        XCTAssertEqual(sent().count, 4, "queue drained")
    }

    func testActivationChangeDropsTheQueue() throws {
        let (coordinator, textView, sent) = try makeHarness()
        let active = try XCTUnwrap(coordinator.parent.rendered.activeEditableRange)
        textView.setSelectedRange(NSRange(location: active.location + 3, length: 0))
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: active.location + 3, length: 0),
            replacementString: "a")
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: active.location + 3, length: 0),
            replacementString: "b")
        coordinator.clearPendingKeystrokes()
        coordinator.noteEditEchoApplied(in: textView)
        XCTAssertEqual(sent().count, 1, "a flip invalidates queued positions entirely")
    }

    // Ledger #9 — format commands and smart paste used to BYPASS the echo
    // gate: ⌘B one frame after a fast keystroke computed its wrap range
    // against the stale projection. They must queue like keystrokes and
    // apply against the freshly restored selection.

    func testFormatCommandQueuesMidFlightAndAppliesAtFreshSelection() throws {
        let (coordinator, textView, sent) = try makeHarness()
        let active = try XCTUnwrap(coordinator.parent.rendered.activeEditableRange)

        // Open the flight window with a keystroke.
        textView.setSelectedRange(NSRange(location: active.location + 12, length: 0))
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: active.location + 12, length: 0),
            replacementString: "a")
        XCTAssertEqual(sent().count, 1)

        // ⌘B mid-flight: must NOT wrap a stale range.
        coordinator.applyFormat(.bold, in: textView)
        XCTAssertEqual(sent().count, 1, "format never applies against stale coordinates")

        // Echo restores the selection over "TD"; the queued bold flushes
        // against the FRESH selection.
        let source = try XCTUnwrap(coordinator.parent.rendered.activeSourceText)
        let word = (source as NSString).range(of: "TD")
        textView.setSelectedRange(NSRange(location: active.location + word.location, length: word.length))
        coordinator.noteEditEchoApplied(in: textView)
        XCTAssertEqual(sent().count, 2)
        XCTAssertEqual(sent()[1].text, "**TD**")

        // The format edit re-armed the gate: the next keystroke queues.
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: active.location + 12, length: 0),
            replacementString: "z")
        XCTAssertEqual(sent().count, 2, "format edits arm the echo gate like keystrokes")
    }

    func testSmartPasteQueuesMidFlightAndLinksAtFreshSelection() throws {
        let (coordinator, textView, sent) = try makeHarness()
        let active = try XCTUnwrap(coordinator.parent.rendered.activeEditableRange)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://example.com/x", forType: .string)

        // Open the flight window.
        textView.setSelectedRange(NSRange(location: active.location + 12, length: 0))
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: active.location + 12, length: 0),
            replacementString: "a")
        XCTAssertEqual(sent().count, 1)

        // Paste mid-flight: handled (queued), nothing sent yet.
        XCTAssertTrue(coordinator.handleSmartPaste())
        XCTAssertEqual(sent().count, 1, "paste never applies against stale coordinates")

        // Echo restores a selection over "TD" → URL-over-selection links it.
        let source = try XCTUnwrap(coordinator.parent.rendered.activeSourceText)
        let word = (source as NSString).range(of: "TD")
        textView.setSelectedRange(NSRange(location: active.location + word.location, length: word.length))
        coordinator.noteEditEchoApplied(in: textView)
        XCTAssertEqual(sent().count, 2)
        XCTAssertEqual(sent()[1].text, "[TD](https://example.com/x)")
    }
}
#endif
