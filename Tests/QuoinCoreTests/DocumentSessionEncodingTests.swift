import XCTest
@testable import QuoinCore

/// Tier-1 data-safety fix: a `.md` another tool wrote in UTF-16 / Latin-1 /
/// with a BOM must OPEN (not be rejected as unreadable), and a save must write
/// it back in the SAME encoding rather than silently converting to UTF-8.
final class DocumentSessionEncodingTests: XCTestCase {

    func testDecodePlainUTF8() throws {
        let decoded = try XCTUnwrap(DocumentSession.decode(Data("# Hi\ncafé\n".utf8)))
        XCTAssertEqual(decoded.source, "# Hi\ncafé\n")
        XCTAssertEqual(decoded.encoding, .utf8)
    }

    func testDecodeUTF8BOMIsStripped() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("body\n".utf8))
        let decoded = try XCTUnwrap(DocumentSession.decode(data))
        XCTAssertEqual(decoded.source, "body\n", "the BOM must not leak in as a leading U+FEFF")
        XCTAssertEqual(decoded.encoding, .utf8)
    }

    func testDecodeUTF16WithBOM() throws {
        let text = "café — note\n"
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            // `.utf16` writing emits a BOM; construct explicit LE/BE + BOM.
            let bom: [UInt8] = encoding == .utf16LittleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]
            var data = Data(bom)
            data.append(text.data(using: encoding)!)
            let decoded = try XCTUnwrap(DocumentSession.decode(data))
            XCTAssertEqual(decoded.source, text)
            XCTAssertEqual(decoded.encoding, .utf16)
        }
    }

    func testDecodeLatin1Fallback() throws {
        // 0xE9 is 'é' in Latin-1 but an invalid lone UTF-8 lead byte.
        let data = Data([0x63, 0x61, 0x66, 0xE9, 0x0A]) // "caf<é>\n"
        let decoded = try XCTUnwrap(DocumentSession.decode(data))
        XCTAssertEqual(decoded.source, "café\n")
        XCTAssertTrue(decoded.encoding == .windowsCP1252 || decoded.encoding == .isoLatin1)
    }

    /// A UTF-16 file opens, and saving writes it back as UTF-16 (BOM intact,
    /// content identical) — no silent conversion to UTF-8.
    func testUTF16FileRoundTripsThroughOpenAndSave() async throws {
        let text = "# Notes\n\ncafé and 東京\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-enc-\(UUID().uuidString).md")
        try text.data(using: .utf16)!.write(to: url)      // UTF-16 with BOM
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try DocumentSession.open(fileURL: url)
        let openedEncoding = await session.fileEncoding
        XCTAssertEqual(openedEncoding, .utf16, "a UTF-16 file must open as UTF-16")

        try await session.saveNow()

        let onDisk = try Data(contentsOf: url)
        XCTAssertTrue(onDisk.starts(with: [0xFF, 0xFE]) || onDisk.starts(with: [0xFE, 0xFF]),
                      "save must preserve UTF-16, not convert to UTF-8")
        let reread = try XCTUnwrap(DocumentSession.decode(onDisk))
        XCTAssertEqual(reread.source, text)
        XCTAssertEqual(reread.encoding, .utf16)
    }
}
