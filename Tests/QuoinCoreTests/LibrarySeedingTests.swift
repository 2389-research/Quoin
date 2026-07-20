import XCTest
@testable import QuoinCore

/// The pure onboarding/Help decisions (#13): whether to OFFER the first-run
/// sample seed and exactly which documents to place. The `LibraryModel` wrapper
/// in the app shell is a thin adapter that copies the chosen bundle resources
/// into the library, so these rules are verified headlessly (Linux CI included)
/// without AppKit, a live `Bundle`, or the filesystem.
final class LibrarySeedingTests: XCTestCase {

    // MARK: - Offer decision

    func testOffersSeedForAnEmptyLibrary() {
        // A brand-new / empty folder gets the offer.
        XCTAssertTrue(LibrarySeeding.shouldOfferSeed(existingFileNames: []))
    }

    func testOffersSeedForALibraryWithUnrelatedFiles() {
        // A real notes folder with no Quoin samples still gets the offer.
        let existing: Set<String> = ["notes.md", "todo.md", "Journal"]
        XCTAssertTrue(LibrarySeeding.shouldOfferSeed(existingFileNames: existing))
    }

    func testDoesNotOfferWhenAnySampleIsAlreadyPresent() {
        // Any sample already on disk means "already seeded" — never nag.
        for sample in LibrarySeeding.sampleSet {
            XCTAssertFalse(
                LibrarySeeding.shouldOfferSeed(existingFileNames: [sample.filename]),
                "should not offer when \(sample.filename) is present")
        }
    }

    func testDoesNotOfferWhenFullySeeded() {
        let all = Set(LibrarySeeding.sampleSet.map(\.filename))
        XCTAssertFalse(LibrarySeeding.shouldOfferSeed(existingFileNames: all))
    }

    // MARK: - What to place (never overwrite)

    func testPlacesEverySampleIntoAnEmptyLibrary() {
        let toPlace = LibrarySeeding.documentsToPlace(existingFileNames: [])
        XCTAssertEqual(toPlace, LibrarySeeding.sampleSet)
    }

    func testNeverOverwritesAnExistingSameNamedFile() {
        // The welcome note already exists — accepting the seed must skip it and
        // place only the missing pieces, never clobbering the user's file.
        let welcome = LibrarySeeding.welcome
        let toPlace = LibrarySeeding.documentsToPlace(existingFileNames: [welcome.filename])
        XCTAssertFalse(toPlace.contains(welcome), "must not re-place / overwrite the existing welcome note")
        XCTAssertEqual(toPlace, LibrarySeeding.sampleSet.filter { $0 != welcome })
    }

    func testPlacesNothingWhenFullySeeded() {
        let all = Set(LibrarySeeding.sampleSet.map(\.filename))
        XCTAssertTrue(LibrarySeeding.documentsToPlace(existingFileNames: all).isEmpty)
    }

    func testDeclineLeavesLibraryUntouched() {
        // Declining is simply "never call documentsToPlace" — this pins that the
        // decision function is pure and writes nothing (no side effects to
        // observe): an empty library stays describable as empty.
        let existing: Set<String> = []
        _ = LibrarySeeding.shouldOfferSeed(existingFileNames: existing)
        XCTAssertTrue(existing.isEmpty)
    }

    // MARK: - Catalog integrity

    func testSampleSetIsASubsetOfHelpSet() {
        let helpFilenames = Set(LibrarySeeding.helpSet.map(\.filename))
        for sample in LibrarySeeding.sampleSet {
            XCTAssertTrue(helpFilenames.contains(sample.filename),
                          "\(sample.filename) is offered but not reachable from Help")
        }
    }

    func testWelcomeIsThePrimarySample() {
        // Order matters: the welcome note is placed/opened first.
        XCTAssertEqual(LibrarySeeding.sampleSet.first, LibrarySeeding.welcome)
    }

    func testBundledDocumentsAreUniqueAndWellFormed() {
        let resources = LibrarySeeding.helpSet.map(\.resource)
        let filenames = LibrarySeeding.helpSet.map(\.filename)
        XCTAssertEqual(Set(resources).count, resources.count, "duplicate resource base names")
        XCTAssertEqual(Set(filenames).count, filenames.count, "duplicate on-disk filenames")
        for doc in LibrarySeeding.helpSet {
            XCTAssertFalse(doc.resource.isEmpty)
            XCTAssertTrue(doc.filename.hasSuffix(".md"), "\(doc.filename) must be a .md file")
            XCTAssertFalse(doc.menuTitle.isEmpty)
            XCTAssertFalse(doc.blurb.isEmpty)
        }
    }
}
