import XCTest
@testable import QuoinCore

/// #32 — coordinated document I/O. The coordination is transparent to bytes:
/// a coordinated write followed by a coordinated read must round-trip exactly,
/// and a missing file must surface an error (never silent empty data).
final class FileCoordinationTests: XCTestCase {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("filecoord-\(UUID().uuidString).md")
    }

    func testWriteThenReadRoundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = Data("Hello, coordinated world 🌍\nsecond line\n".utf8)
        try FileCoordination.writeAtomic(payload, to: url)
        XCTAssertEqual(try FileCoordination.read(url), payload)
    }

    func testWriteReplacesExistingContent() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileCoordination.writeAtomic(Data("first".utf8), to: url)
        try FileCoordination.writeAtomic(Data("second".utf8), to: url)
        XCTAssertEqual(try FileCoordination.read(url), Data("second".utf8))
    }

    func testReadingMissingFileThrows() {
        let url = tempURL() // never created
        XCTAssertThrowsError(try FileCoordination.read(url))
    }
}
