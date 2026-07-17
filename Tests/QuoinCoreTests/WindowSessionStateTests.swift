import XCTest
@testable import QuoinCore

/// Window/session restoration model (#15): the pure serialize/deserialize +
/// prune + dedupe + route-to-existing rules, exercised off the filesystem.
final class WindowSessionStateTests: XCTestCase {

    private let root = "/Users/me/Library"

    // MARK: - Round-trip

    func testRoundTripPreservesEveryField() {
        let original = WindowSessionState(
            tabs: [
                WindowSessionState.Tab(path: "Notes/Today.md", scrollAnchor: "morning"),
                WindowSessionState.Tab(path: "Projects/Spec.md", scrollAnchor: nil),
                WindowSessionState.Tab(path: "Deep/Nested/Doc.md", scrollAnchor: "results"),
            ],
            activeTabIndex: 1,
            sidebarVisible: false,
            inspectorVisible: true,
            inspectorMode: .review
        )
        let decoded = WindowSessionState(serialized: original.serialized())
        XCTAssertEqual(decoded, original)
    }

    func testRoundTripDefaultsAndEmpty() {
        let empty = WindowSessionState()
        XCTAssertEqual(WindowSessionState(serialized: empty.serialized()), empty)
        // Every inspector mode survives.
        for mode in [WindowSessionState.InspectorMode.outline, .review, .properties] {
            let state = WindowSessionState(inspectorMode: mode)
            XCTAssertEqual(WindowSessionState(serialized: state.serialized())?.inspectorMode, mode)
        }
    }

    func testSerializationIsDeterministic() {
        let state = WindowSessionState(
            tabs: [WindowSessionState.Tab(path: "A.md"), WindowSessionState.Tab(path: "B.md")],
            activeTabIndex: 0, sidebarVisible: true, inspectorVisible: false, inspectorMode: .properties)
        XCTAssertEqual(state.serialized(), state.serialized())
    }

    func testDeserializeGarbageAndEmptyReturnsNil() {
        XCTAssertNil(WindowSessionState(serialized: ""))
        XCTAssertNil(WindowSessionState(serialized: "not json"))
        XCTAssertNil(WindowSessionState(serialized: "{\"unexpected\":true}"))
    }

    func testFutureVersionIsRefused() {
        var future = WindowSessionState(tabs: [WindowSessionState.Tab(path: "A.md")])
        future.version = WindowSessionState.currentVersion + 1
        // The blob encodes fine, but a build that doesn't understand the version
        // refuses it rather than half-reading a future layout.
        XCTAssertNil(WindowSessionState(serialized: future.serialized()))
    }

    // MARK: - Capture: no absolute path may leak

    func testCapturePersistsOnlyRelativeHandles() {
        let state = WindowSessionState.capture(
            rootPath: root,
            openTabPaths: [
                "\(root)/Notes/Today.md",
                "\(root)/Projects/Spec.md",
            ],
            activeTabPath: "\(root)/Projects/Spec.md",
            sidebarVisible: true, inspectorVisible: true, inspectorMode: .outline)

        XCTAssertEqual(state.tabs.map(\.path), ["Notes/Today.md", "Projects/Spec.md"])
        XCTAssertEqual(state.activeTabIndex, 1)

        // The serialized blob must contain NO absolute path fragment — not the
        // root, not a leading slash before a document.
        let blob = state.serialized()
        XCTAssertFalse(blob.contains(root), "the library root path leaked into the blob")
        XCTAssertFalse(blob.contains("\(root)/Notes/Today.md"))
        for tab in state.tabs {
            XCTAssertFalse(tab.path.hasPrefix("/"), "a tab handle is absolute: \(tab.path)")
        }
    }

    func testCaptureDropsTabsOutsideRoot() {
        let state = WindowSessionState.capture(
            rootPath: root,
            openTabPaths: [
                "\(root)/Inside.md",
                "/tmp/Outside.md",              // one-off ⌘O file, not persistable
                "/Users/me/Other/Elsewhere.md", // different tree
            ],
            activeTabPath: "/tmp/Outside.md",
            sidebarVisible: true, inspectorVisible: true, inspectorMode: .outline)

        XCTAssertEqual(state.tabs.map(\.path), ["Inside.md"])
        // The active tab was dropped → no persisted active index.
        XCTAssertNil(state.activeTabIndex)
        XCTAssertFalse(state.serialized().contains("/tmp/Outside.md"))
        XCTAssertFalse(state.serialized().contains("Elsewhere"))
    }

    func testCaptureWithNoRootPersistsNoTabs() {
        let state = WindowSessionState.capture(
            rootPath: nil,
            openTabPaths: ["\(root)/A.md"],
            activeTabPath: "\(root)/A.md",
            sidebarVisible: false, inspectorVisible: false, inspectorMode: .review)
        XCTAssertTrue(state.tabs.isEmpty)
        XCTAssertNil(state.activeTabIndex)
        // The chrome flags still round-trip even with no persistable tabs.
        XCTAssertEqual(state.sidebarVisible, false)
        XCTAssertEqual(state.inspectorMode, .review)
    }

    func testCaptureCarriesScrollAnchors() {
        let state = WindowSessionState.capture(
            rootPath: root,
            openTabPaths: ["\(root)/A.md", "\(root)/B.md"],
            activeTabPath: "\(root)/A.md",
            scrollAnchors: ["\(root)/A.md": "chapter-two"],
            sidebarVisible: true, inspectorVisible: true, inspectorMode: .outline)
        XCTAssertEqual(state.tabs.first { $0.path == "A.md" }?.scrollAnchor, "chapter-two")
        XCTAssertNil(state.tabs.first { $0.path == "B.md" }?.scrollAnchor)
    }

    // MARK: - Restore: prune moved/vanished, resolve to absolute

    func testRestoreResolvesToAbsoluteUnderRoot() {
        let present: Set<String> = ["\(root)/Notes/Today.md", "\(root)/Spec.md"]
        let state = WindowSessionState(
            tabs: [
                WindowSessionState.Tab(path: "Notes/Today.md"),
                WindowSessionState.Tab(path: "Spec.md"),
            ],
            activeTabIndex: 0)
        let restored = state.restoredTabs(rootPath: root) { present.contains($0) }
        XCTAssertEqual(restored.orderedPaths, ["\(root)/Notes/Today.md", "\(root)/Spec.md"])
        XCTAssertEqual(restored.activePath, "\(root)/Notes/Today.md")
    }

    func testRestorePrunesVanishedFiles() {
        // "Gone.md" moved/deleted since the session was saved.
        let present: Set<String> = ["\(root)/Kept.md"]
        let state = WindowSessionState(
            tabs: [
                WindowSessionState.Tab(path: "Gone.md"),
                WindowSessionState.Tab(path: "Kept.md"),
            ],
            activeTabIndex: 0) // active was the vanished one
        let restored = state.restoredTabs(rootPath: root) { present.contains($0) }
        XCTAssertEqual(restored.orderedPaths, ["\(root)/Kept.md"])
        // Active fell away → falls back to the last surviving tab, never nil-crashes.
        XCTAssertEqual(restored.activePath, "\(root)/Kept.md")
    }

    func testRestoreDropsAllWhenNoneExist() {
        let state = WindowSessionState(
            tabs: [WindowSessionState.Tab(path: "A.md"), WindowSessionState.Tab(path: "B.md")],
            activeTabIndex: 1)
        let restored = state.restoredTabs(rootPath: root) { _ in false }
        XCTAssertTrue(restored.orderedPaths.isEmpty)
        XCTAssertNil(restored.activePath)
    }

    func testRestoreRefusesHandleThatClimbsOutOfRoot() {
        // A malformed/hostile handle that escapes the root is refused by the
        // same lexical resolver a quoin:// link uses — even if the file "exists".
        let state = WindowSessionState(
            tabs: [
                WindowSessionState.Tab(path: "../Secrets/passwords.md"),
                WindowSessionState.Tab(path: "Safe.md"),
            ],
            activeTabIndex: 0)
        let restored = state.restoredTabs(rootPath: root) { _ in true }
        XCTAssertEqual(restored.orderedPaths, ["\(root)/Safe.md"])
        XCTAssertEqual(restored.activePath, "\(root)/Safe.md")
    }

    func testRestoreDedupesHandlesForOneFile() {
        // Two handles that normalize to the same file collapse to ONE tab —
        // never two sessions fighting over one document.
        let state = WindowSessionState(
            tabs: [
                WindowSessionState.Tab(path: "Notes/Today.md"),
                WindowSessionState.Tab(path: "Notes/../Notes/Today.md"),
            ],
            activeTabIndex: 1)
        let restored = state.restoredTabs(rootPath: root) { _ in true }
        XCTAssertEqual(restored.orderedPaths, ["\(root)/Notes/Today.md"])
        XCTAssertEqual(restored.activePath, "\(root)/Notes/Today.md")
    }

    func testCaptureRestoreRoundTripThroughDifferentRoot() {
        // The handle is portable: a library that moved to a new absolute
        // location restores the same documents relative to the NEW root.
        let captured = WindowSessionState.capture(
            rootPath: "/old/Library",
            openTabPaths: ["/old/Library/Notes/Today.md"],
            activeTabPath: "/old/Library/Notes/Today.md",
            sidebarVisible: true, inspectorVisible: true, inspectorMode: .outline)
        let restored = captured.restoredTabs(rootPath: "/new/Home/Library") { _ in true }
        XCTAssertEqual(restored.orderedPaths, ["/new/Home/Library/Notes/Today.md"])
    }

    // MARK: - Route-to-existing (dedupe) decision

    func testDedupeRoutesToExistingSession() {
        let open = ["\(root)/A.md", "\(root)/B.md", "\(root)/C.md"]
        XCTAssertEqual(
            SessionRouting.decide(opening: "\(root)/B.md", amongOpen: open),
            .focusExisting(index: 1))
    }

    func testDedupeOpensNewWhenAbsent() {
        let open = ["\(root)/A.md"]
        XCTAssertEqual(
            SessionRouting.decide(opening: "\(root)/New.md", amongOpen: open),
            .openNew)
    }

    func testDedupeCollapsesPathVariantsToOneTab() {
        let open = ["\(root)/Notes/Today.md"]
        // A `..` detour and a case variant both route to the SAME open tab on
        // the case-insensitive default volume.
        XCTAssertEqual(
            SessionRouting.decide(opening: "\(root)/Notes/../Notes/Today.md", amongOpen: open),
            .focusExisting(index: 0))
        XCTAssertEqual(
            SessionRouting.decide(opening: "\(root)/notes/today.md", amongOpen: open),
            .focusExisting(index: 0))
    }

    func testDedupeCaseSensitiveVolumeKeepsVariantsDistinct() {
        let open = ["\(root)/Todo.md"]
        XCTAssertEqual(
            SessionRouting.decide(opening: "\(root)/todo.md", amongOpen: open, caseSensitive: true),
            .openNew)
    }

    func testDedupeReturnsFirstMatch() {
        // Defensive: a duplicated open list routes to the first occurrence.
        let open = ["\(root)/A.md", "\(root)/a.md"]
        XCTAssertEqual(
            SessionRouting.decide(opening: "\(root)/A.md", amongOpen: open),
            .focusExisting(index: 0))
    }
}
