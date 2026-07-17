import XCTest
@testable import QuoinCore

final class RecentDocumentsTests: XCTestCase {

    // MARK: - recording (MRU update)

    func testRecordingPrependsNewPath() {
        let out = RecentDocuments.recording("/a.md", into: ["/b.md", "/c.md"])
        XCTAssertEqual(out, ["/a.md", "/b.md", "/c.md"])
    }

    func testRecordingIntoEmptyList() {
        XCTAssertEqual(RecentDocuments.recording("/a.md", into: []), ["/a.md"])
    }

    func testReopeningPromotesRatherThanDuplicates() {
        // /c was already in the list; reopening it moves it to the front and
        // leaves exactly one copy — no duplicate entries.
        let out = RecentDocuments.recording("/c.md", into: ["/a.md", "/b.md", "/c.md"])
        XCTAssertEqual(out, ["/c.md", "/a.md", "/b.md"])
    }

    func testReopeningTheHeadIsIdempotent() {
        let list = ["/a.md", "/b.md"]
        XCTAssertEqual(RecentDocuments.recording("/a.md", into: list), list)
    }

    func testRecordingCapsAtLimit() {
        let list = (0..<20).map { "/f\($0).md" }
        let out = RecentDocuments.recording("/new.md", into: list)
        XCTAssertEqual(out.count, RecentDocuments.storageLimit)
        XCTAssertEqual(out.first, "/new.md")
        XCTAssertEqual(out.last, "/f18.md") // /f19 fell off the end
        XCTAssertFalse(out.contains("/f19.md"))
    }

    func testRecordingHonorsCustomLimit() {
        let out = RecentDocuments.recording("/a.md", into: ["/b.md", "/c.md"], limit: 2)
        XCTAssertEqual(out, ["/a.md", "/b.md"])
    }

    func testRecordingPreexistingPathStillTrimsToLimit() {
        // Promoting an already-present entry must not push the list over the cap.
        let list = (0..<3).map { "/f\($0).md" }
        let out = RecentDocuments.recording("/f2.md", into: list, limit: 2)
        XCTAssertEqual(out, ["/f2.md", "/f0.md"])
    }

    // MARK: - present (prune to existing, for menus)

    func testPresentDropsMissingFiles() {
        let existing: Set<String> = ["/a.md", "/c.md"]
        let out = RecentDocuments.present(
            in: ["/a.md", "/b.md", "/c.md"], exists: { existing.contains($0) })
        XCTAssertEqual(out, ["/a.md", "/c.md"]) // /b (deleted) is gone
    }

    func testPresentPreservesOrder() {
        let out = RecentDocuments.present(
            in: ["/z.md", "/a.md", "/m.md"], exists: { _ in true })
        XCTAssertEqual(out, ["/z.md", "/a.md", "/m.md"])
    }

    func testPresentCapsAtLimit() {
        let list = (0..<10).map { "/f\($0).md" }
        let out = RecentDocuments.present(in: list, limit: 3, exists: { _ in true })
        XCTAssertEqual(out, ["/f0.md", "/f1.md", "/f2.md"])
    }

    func testPresentCountsOnlyExistingTowardTheLimit() {
        // The first two entries are missing; the limit of 2 must still yield two
        // real files, not stop after skipping the dead ones.
        let missing: Set<String> = ["/x.md", "/y.md"]
        let out = RecentDocuments.present(
            in: ["/x.md", "/y.md", "/a.md", "/b.md", "/c.md"],
            limit: 2,
            exists: { !missing.contains($0) })
        XCTAssertEqual(out, ["/a.md", "/b.md"])
    }

    func testPresentDeduplicatesDefensively() {
        // A corrupted stored list with duplicates must still render each once.
        let out = RecentDocuments.present(
            in: ["/a.md", "/a.md", "/b.md"], exists: { _ in true })
        XCTAssertEqual(out, ["/a.md", "/b.md"])
    }

    func testPresentEmptyListIsEmpty() {
        XCTAssertEqual(RecentDocuments.present(in: [], exists: { _ in true }), [])
    }
}
