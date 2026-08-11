#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinEditorKit

@MainActor
final class BlockEditorCellTests: XCTestCase {
    func testSeedsRawSourceAndIsEditableWithRealCaret() {
        let doc = MarkdownConverter.parse("# Heading\n\nBody.")
        let slice = doc.source.substring(in: doc.blocks[0].range)!   // "# Heading"
        let cell = BlockEditorCell()
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:600,height:200), styleMask:[.borderless], backing:.buffered, defer:false)
        window.contentView = cell; window.makeKeyAndOrderFront(nil)
        cell.configure(slice: slice, blockID: doc.blocks[0].id, width: 600)
        window.makeFirstResponder(cell.islandTextView)
        XCTAssertEqual(cell.islandTextView.string, "# Heading")   // RAW source, with the '#'
        XCTAssertTrue(cell.islandTextView.isEditable)
        XCTAssertFalse(cell.islandTextView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertEqual(cell.blockID, doc.blocks[0].id)
        // Real caret bar (not a 2pt dot): place caret at end, read firstRect height.
        cell.islandTextView.setSelectedRange(NSRange(location: 9, length: 0))
        cell.islandTextView.textLayoutManager?.ensureLayout(for: cell.islandTextView.textContentStorage!.documentRange)
        var actual = NSRange()
        let rect = cell.islandTextView.firstRect(forCharacterRange: cell.islandTextView.selectedRange(), actualRange: &actual)
        XCTAssertGreaterThan(rect.height, 8)
    }
    func testTypingFiresOnTextDidChange() {
        let cell = BlockEditorCell()
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:400,height:100), styleMask:[.borderless], backing:.buffered, defer:false)
        window.contentView = cell; window.makeKeyAndOrderFront(nil)
        cell.configure(slice: "ab", blockID: BlockID(contentHash: 1, occurrence: 0), width: 400)
        window.makeFirstResponder(cell.islandTextView)
        var fired = 0; cell.onTextDidChange = { fired += 1 }
        cell.islandTextView.insertText("c", replacementRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(cell.islandTextView.string, "abc")
        XCTAssertGreaterThan(fired, 0)
    }
}
#endif
