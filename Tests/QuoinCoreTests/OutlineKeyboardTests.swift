import XCTest
@testable import QuoinCore

/// Keyboard collapse/expand + arrow movement for the outline tree (#11).
/// Mirrors NSOutlineView semantics: Down/Up walk the visible rows (no wrap),
/// Left collapses an open parent then climbs, Right expands a closed parent
/// then descends. Manual collapse stays authoritative — these are the ONLY
/// mutations of the collapse set (#74).
final class OutlineKeyboardTests: XCTestCase {

    /// 1 Intro (H1) › 1.1 (H2) — 2 Setup (H1) — 3 Inline (H1) › 3.1 (H2) › 3.1.1 (H3) › 3.2 (H2)
    private let outline: [HeadingInfo] = [
        heading(1, level: 1, title: "Intro"),
        heading(2, level: 2, title: "1.1"),
        heading(3, level: 1, title: "Setup"),
        heading(4, level: 1, title: "Inline"),
        heading(5, level: 2, title: "3.1"),
        heading(6, level: 3, title: "3.1.1"),
        heading(7, level: 2, title: "3.2"),
    ]

    private static func heading(_ n: Int, level: Int, title: String) -> HeadingInfo {
        HeadingInfo(
            id: BlockID(contentHash: n, occurrence: 0),
            level: level,
            title: title,
            slug: title.lowercased(),
            range: ByteRange(offset: n * 10, length: 5)
        )
    }

    private func id(_ n: Int) -> BlockID { BlockID(contentHash: n, occurrence: 0) }

    // MARK: - Down

    func testDownFromNilFocusesFirstVisibleRow() {
        XCTAssertEqual(
            OutlineKeyboard.moveDown(from: nil, outline: outline, collapsed: []),
            .move(id(1))
        )
    }

    func testDownWalksToTheNextVisibleRow() {
        XCTAssertEqual(
            OutlineKeyboard.moveDown(from: id(1), outline: outline, collapsed: []),
            .move(id(2))
        )
    }

    func testDownSkipsRowsHiddenInsideACollapsedBranch() {
        // "Inline" (id 4) collapsed: 3.1/3.1.1/3.2 hidden. Down from Setup
        // (id 3) lands on Inline, and Down from Inline dead-ends (last visible).
        XCTAssertEqual(
            OutlineKeyboard.moveDown(from: id(3), outline: outline, collapsed: [id(4)]),
            .move(id(4))
        )
        XCTAssertEqual(
            OutlineKeyboard.moveDown(from: id(4), outline: outline, collapsed: [id(4)]),
            .none
        )
    }

    func testDownAtTheLastRowDoesNotWrap() {
        XCTAssertEqual(
            OutlineKeyboard.moveDown(from: id(7), outline: outline, collapsed: []),
            .none
        )
    }

    func testDownFromAHiddenFocusFallsBackToFirstVisible() {
        // Focus was on a row that a collapse just hid: recover to the top.
        XCTAssertEqual(
            OutlineKeyboard.moveDown(from: id(6), outline: outline, collapsed: [id(4)]),
            .move(id(1))
        )
    }

    // MARK: - Up

    func testUpFromNilFocusesLastVisibleRow() {
        XCTAssertEqual(
            OutlineKeyboard.moveUp(from: nil, outline: outline, collapsed: []),
            .move(id(7))
        )
    }

    func testUpWalksToThePreviousVisibleRow() {
        XCTAssertEqual(
            OutlineKeyboard.moveUp(from: id(5), outline: outline, collapsed: []),
            .move(id(4))
        )
    }

    func testUpAtTheFirstRowDoesNotWrap() {
        XCTAssertEqual(
            OutlineKeyboard.moveUp(from: id(1), outline: outline, collapsed: []),
            .none
        )
    }

    // MARK: - Left (collapse or climb to parent)

    func testLeftCollapsesAnOpenParent() {
        XCTAssertEqual(
            OutlineKeyboard.collapseOrParent(focused: id(4), outline: outline, collapsed: []),
            .collapse(id(4))
        )
    }

    func testLeftOnAnAlreadyCollapsedParentClimbsToItsParent() {
        // 3.1 (id 5) is collapsed AND is a child of Inline (id 4): Left moves
        // focus up to Inline rather than collapsing again.
        XCTAssertEqual(
            OutlineKeyboard.collapseOrParent(focused: id(5), outline: outline, collapsed: [id(5)]),
            .move(id(4))
        )
    }

    func testLeftOnALeafClimbsToItsParent() {
        XCTAssertEqual(
            OutlineKeyboard.collapseOrParent(focused: id(6), outline: outline, collapsed: []),
            .move(id(5))
        )
    }

    func testLeftOnARootLeafDoesNothing() {
        // Setup (id 3) is a top-level heading with no children and no parent.
        XCTAssertEqual(
            OutlineKeyboard.collapseOrParent(focused: id(3), outline: outline, collapsed: []),
            .none
        )
    }

    func testLeftOnACollapsedRootParentClimbsNowhere() {
        // Inline collapsed and at root level: no parent to climb to.
        XCTAssertEqual(
            OutlineKeyboard.collapseOrParent(focused: id(4), outline: outline, collapsed: [id(4)]),
            .none
        )
    }

    // MARK: - Right (expand or descend to first child)

    func testRightExpandsACollapsedParent() {
        XCTAssertEqual(
            OutlineKeyboard.expandOrChild(focused: id(4), outline: outline, collapsed: [id(4)]),
            .expand(id(4))
        )
    }

    func testRightOnAnOpenParentDescendsToFirstChild() {
        XCTAssertEqual(
            OutlineKeyboard.expandOrChild(focused: id(4), outline: outline, collapsed: []),
            .move(id(5))
        )
    }

    func testRightOnALeafDoesNothing() {
        XCTAssertEqual(
            OutlineKeyboard.expandOrChild(focused: id(6), outline: outline, collapsed: []),
            .none
        )
        XCTAssertEqual(
            OutlineKeyboard.expandOrChild(focused: id(3), outline: outline, collapsed: []),
            .none
        )
    }

    // MARK: - Level skip (H1 → H3 with no H2)

    func testLeftOnLevelSkippedChildClimbsToPositionalParent() {
        let skippy = [
            Self.heading(1, level: 1, title: "Top"),
            Self.heading(2, level: 3, title: "Deep"),
        ]
        XCTAssertEqual(
            OutlineKeyboard.collapseOrParent(focused: id(2), outline: skippy, collapsed: []),
            .move(id(1))
        )
    }

    // MARK: - Empty outline

    func testMovementOnEmptyOutlineIsANoOp() {
        XCTAssertEqual(OutlineKeyboard.moveDown(from: nil, outline: [], collapsed: []), .none)
        XCTAssertEqual(OutlineKeyboard.moveUp(from: nil, outline: [], collapsed: []), .none)
    }
}
