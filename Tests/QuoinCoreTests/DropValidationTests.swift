import XCTest
@testable import QuoinCore

final class DropValidationTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/Library/Quoin", isDirectory: true)

    // MARK: - Library sidebar drops

    func testSiblingMoveAllowed() {
        // A document in the root, dropped onto a sibling folder → move.
        let doc = root.appendingPathComponent("Alpha.md")
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        XCTAssertEqual(DropValidation.libraryDrop(dragged: doc, onto: folder, libraryRoot: root), .move)
    }

    func testDropOntoSelfRejected() {
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        XCTAssertEqual(DropValidation.libraryDrop(dragged: folder, onto: folder, libraryRoot: root), .reject)
    }

    func testFolderIntoOwnDescendantRejected() {
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        let descendant = folder.appendingPathComponent("Sub", isDirectory: true)
        XCTAssertEqual(DropValidation.libraryDrop(dragged: folder, onto: descendant, libraryRoot: root), .reject)
        // Deeper descendant too.
        let deeper = descendant.appendingPathComponent("Deep", isDirectory: true)
        XCTAssertEqual(DropValidation.libraryDrop(dragged: folder, onto: deeper, libraryRoot: root), .reject)
    }

    func testDropIntoCurrentParentRejectedAsNoop() {
        // Alpha.md already lives in root; dropping it back onto root is a no-op.
        let doc = root.appendingPathComponent("Alpha.md")
        XCTAssertEqual(DropValidation.libraryDrop(dragged: doc, onto: root, libraryRoot: root), .reject)
        // A file inside Projects dropped back onto Projects.
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        let nested = projects.appendingPathComponent("Gamma.md")
        XCTAssertEqual(DropValidation.libraryDrop(dragged: nested, onto: projects, libraryRoot: root), .reject)
    }

    func testMovingLibraryRootItselfRejected() {
        XCTAssertEqual(DropValidation.libraryDrop(dragged: root, onto: root, libraryRoot: root), .reject)
    }

    func testExternalMarkdownCopied() {
        let external = URL(fileURLWithPath: "/Users/someone/Desktop/Notes.md")
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        XCTAssertEqual(DropValidation.libraryDrop(dragged: external, onto: folder, libraryRoot: root), .copy)
        // Alternate markdown extensions import too.
        let markdown = URL(fileURLWithPath: "/Users/someone/Desktop/Notes.markdown")
        XCTAssertEqual(DropValidation.libraryDrop(dragged: markdown, onto: folder, libraryRoot: root), .copy)
    }

    func testExternalNonMarkdownRejected() {
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        let image = URL(fileURLWithPath: "/Users/someone/Desktop/photo.png")
        XCTAssertEqual(DropValidation.libraryDrop(dragged: image, onto: folder, libraryRoot: root), .reject)
        let pdf = URL(fileURLWithPath: "/Users/someone/Desktop/report.pdf")
        XCTAssertEqual(DropValidation.libraryDrop(dragged: pdf, onto: folder, libraryRoot: root), .reject)
        // An external folder is not a markdown file → rejected.
        let extFolder = URL(fileURLWithPath: "/Users/someone/Desktop/Stuff", isDirectory: true)
        XCTAssertEqual(DropValidation.libraryDrop(dragged: extFolder, onto: folder, libraryRoot: root), .reject)
    }

    func testInternalMoveBetweenSubfolders() {
        let source = root.appendingPathComponent("A", isDirectory: true)
        let doc = source.appendingPathComponent("Note.md")
        let dest = root.appendingPathComponent("B", isDirectory: true)
        XCTAssertEqual(DropValidation.libraryDrop(dragged: doc, onto: dest, libraryRoot: root), .move)
    }

    func testDescendantPrefixIsPathSegmentAware() {
        // "Projects2" must NOT count as a descendant of "Projects" (shared
        // string prefix without a path boundary).
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        let lookalike = root.appendingPathComponent("Projects2", isDirectory: true)
        XCTAssertEqual(DropValidation.libraryDrop(dragged: folder, onto: lookalike, libraryRoot: root), .move)
    }

    // MARK: - Editor drops

    func testEditorImageDrop() {
        XCTAssertEqual(DropValidation.editorDrop(URL(fileURLWithPath: "/tmp/pic.png")), .insertImage)
        XCTAssertEqual(DropValidation.editorDrop(URL(fileURLWithPath: "/tmp/pic.JPEG")), .insertImage)
        XCTAssertEqual(DropValidation.editorDrop(URL(fileURLWithPath: "/tmp/pic.heic")), .insertImage)
    }

    func testEditorMarkdownDropOpens() {
        XCTAssertEqual(DropValidation.editorDrop(URL(fileURLWithPath: "/tmp/notes.md")), .openDocument)
        XCTAssertEqual(DropValidation.editorDrop(URL(fileURLWithPath: "/tmp/notes.markdown")), .openDocument)
    }

    func testEditorUnsupportedDropRejected() {
        XCTAssertEqual(DropValidation.editorDrop(URL(fileURLWithPath: "/tmp/archive.zip")), .reject)
        XCTAssertEqual(DropValidation.editorDrop(URL(fileURLWithPath: "/tmp/report.pdf")), .reject)
    }
}
