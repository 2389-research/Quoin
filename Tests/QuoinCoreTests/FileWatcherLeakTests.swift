#if canImport(Darwin)
import Darwin
import XCTest
@testable import QuoinCore

/// #34 — FileWatcher must close its descriptor when it deallocates. The old
/// `deinit { cancel() }` bounced teardown through `queue.async { [weak self] }`,
/// which no-ops during deallocation (self is already nil), so the dispatch
/// source was never cancelled and its fd leaked. Enough churn exhausts the
/// process's fd table.
final class FileWatcherLeakTests: XCTestCase {
    /// Open descriptors in this process, counted by probing the fd table.
    private func openDescriptorCount() -> Int {
        var count = 0
        for fd in 0..<Int32(getdtablesize()) where fcntl(fd, F_GETFD) != -1 {
            count += 1
        }
        return count
    }

    /// Poll `condition` until true or the deadline passes — deterministic in
    /// outcome (no fixed sleeps): a real leak never satisfies it and the test
    /// fails at the assertion, a closed fd satisfies it within milliseconds.
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            usleep(10_000)
        }
    }

    func testDeinitClosesDescriptor() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fw-leak-\(UUID().uuidString).md")
        try "watch me".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let batch = 150
        let baseline = openDescriptorCount()

        var watchers: [FileWatcher] = []
        for _ in 0..<batch {
            let w = FileWatcher(url: tmp, onChange: {})
            w.start()
            watchers.append(w)
        }
        // Let them actually open their descriptors — otherwise the test is
        // vacuous (a watcher released before it arms never opens an fd).
        waitUntil(5) { openDescriptorCount() >= baseline + batch / 2 }
        XCTAssertGreaterThanOrEqual(
            openDescriptorCount(), baseline + batch / 2,
            "watchers never armed, so the leak check would be vacuous")

        // Release them all; each deinit must cancel its source and close its fd.
        watchers.removeAll()
        waitUntil(5) { openDescriptorCount() <= baseline + 20 }

        XCTAssertLessThanOrEqual(
            openDescriptorCount(), baseline + 20,
            "FileWatcher leaked descriptors on deinit (#34 regression)")
    }
}
#endif
