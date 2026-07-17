#if canImport(AppKit) || canImport(UIKit)
import XCTest
@testable import QuoinRender

/// Direct coverage for the VoiceOver structure-rotor navigation math
/// (`StructureRotor.result`) — the next/previous/first-search/filter selection
/// that feeds both the Headings and Landmarks rotors (accessibility structure,
/// #10). This is the novel, off-by-one-prone logic; the AppKit delegate is a
/// thin adapter over it. Anchors mirror caret-relative navigation elsewhere
/// (RevealFidelityTests, CaretLineAnchorTests).
final class StructureRotorTests: XCTestCase {

    private func item(_ location: Int, _ label: String, length: Int = 1) -> StructureRotor.Item {
        StructureRotor.Item(location: location, length: length, label: label)
    }

    private var sample: [StructureRotor.Item] {
        [item(0, "Heading level 1, Alpha"),
         item(10, "Heading level 2, Beta"),
         item(20, "Heading level 2, Gamma")]
    }

    // MARK: - First search (nil current item)

    func testFirstNextSearchReturnsFirstItem() {
        let hit = StructureRotor.result(items: sample, currentLocation: nil, direction: .next, filter: "")
        XCTAssertEqual(hit, item(0, "Heading level 1, Alpha"))
    }

    func testFirstPreviousSearchReturnsLastItem() {
        let hit = StructureRotor.result(items: sample, currentLocation: nil, direction: .previous, filter: "")
        XCTAssertEqual(hit, item(20, "Heading level 2, Gamma"))
    }

    // MARK: - Stepping forward / backward

    func testNextPicksFirstItemStrictlyAfterAnchor() {
        let hit = StructureRotor.result(items: sample, currentLocation: 10, direction: .next, filter: "")
        XCTAssertEqual(hit, item(20, "Heading level 2, Gamma"))
    }

    func testPreviousPicksLastItemStrictlyBeforeAnchor() {
        let hit = StructureRotor.result(items: sample, currentLocation: 20, direction: .previous, filter: "")
        XCTAssertEqual(hit, item(10, "Heading level 2, Beta"))
    }

    /// The comparison MUST be strict: standing on an item and stepping .next
    /// moves off it, never re-selects it (the `>` vs `>=` regression the
    /// finding calls out).
    func testNextDoesNotReselectTheAnchoredItem() {
        let hit = StructureRotor.result(items: sample, currentLocation: 0, direction: .next, filter: "")
        XCTAssertEqual(hit?.location, 10)
    }

    func testPreviousDoesNotReselectTheAnchoredItem() {
        let hit = StructureRotor.result(items: sample, currentLocation: 20, direction: .previous, filter: "")
        XCTAssertEqual(hit?.location, 10)
    }

    /// An anchor that falls between items still steps correctly.
    func testNextFromBetweenItems() {
        let hit = StructureRotor.result(items: sample, currentLocation: 5, direction: .next, filter: "")
        XCTAssertEqual(hit?.location, 10)
    }

    func testPreviousFromBetweenItems() {
        let hit = StructureRotor.result(items: sample, currentLocation: 15, direction: .previous, filter: "")
        XCTAssertEqual(hit?.location, 10)
    }

    // MARK: - Ends of the document

    func testNextPastLastItemReturnsNil() {
        XCTAssertNil(StructureRotor.result(items: sample, currentLocation: 20, direction: .next, filter: ""))
    }

    func testPreviousBeforeFirstItemReturnsNil() {
        XCTAssertNil(StructureRotor.result(items: sample, currentLocation: 0, direction: .previous, filter: ""))
    }

    // MARK: - Empty pool

    func testEmptyItemsReturnsNil() {
        XCTAssertNil(StructureRotor.result(items: [], currentLocation: nil, direction: .next, filter: ""))
    }

    // MARK: - Filtering

    func testFilterIsCaseInsensitiveSubstring() {
        let hit = StructureRotor.result(items: sample, currentLocation: nil, direction: .next, filter: "beta")
        XCTAssertEqual(hit, item(10, "Heading level 2, Beta"))
    }

    func testFilterNarrowsSteppingToMatchesOnly() {
        // Two "level 2" items; stepping .next from the first level-2 lands on
        // the second, skipping the non-matching level-1.
        let hit = StructureRotor.result(items: sample, currentLocation: 10, direction: .next, filter: "level 2")
        XCTAssertEqual(hit?.location, 20)
    }

    func testFilterThatMatchesNothingReturnsNil() {
        XCTAssertNil(StructureRotor.result(items: sample, currentLocation: nil, direction: .next, filter: "zzz"))
    }

    func testFirstPreviousSearchWithFilterReturnsLastMatch() {
        // "level 2" matches Beta(10) and Gamma(20); a first .previous search
        // returns the LAST match.
        let hit = StructureRotor.result(items: sample, currentLocation: nil, direction: .previous, filter: "level 2")
        XCTAssertEqual(hit?.location, 20)
    }

    func testFilterExcludesAnchorEvenIfBeyondIt() {
        // Anchor at Alpha(0); .next with a filter that only matches Alpha would
        // have nothing strictly after → nil.
        XCTAssertNil(StructureRotor.result(items: sample, currentLocation: 0, direction: .next, filter: "alpha"))
    }
}
#endif
