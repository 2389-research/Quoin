import XCTest
@testable import QuoinEditorKit

final class ScaffoldTests: XCTestCase {
    func testTargetLinks() {
        XCTAssertEqual(QuoinEditorKit.version, "0.0.0-phase0")
    }
}
