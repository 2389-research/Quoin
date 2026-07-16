#if canImport(AppKit) || canImport(UIKit)
import Foundation

/// Lightweight, opt-in local timing for edit/render responsiveness work.
///
/// Set `QUOIN_EDIT_PERF_LOG=1` before launching the app or a benchmark to emit
/// phase timings to stderr. This is deliberately local-only and dependency-free.
public enum QuoinPerformanceTrace {
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["QUOIN_EDIT_PERF_LOG"] == "1"
    }

    @discardableResult
    public static func measure<T>(
        _ phase: String,
        metadata: @autoclosure () -> String = "",
        _ work: () throws -> T
    ) rethrows -> T {
        guard isEnabled else { return try work() }
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let value = try work()
            log(phase, startedAt: start, metadata: metadata())
            return value
        } catch {
            log(phase, startedAt: start, metadata: "\(metadata()) error=\(error)")
            throw error
        }
    }

    @discardableResult
    public static func measure<T>(
        _ phase: String,
        metadata: @autoclosure () -> String = "",
        _ work: () async throws -> T
    ) async rethrows -> T {
        guard isEnabled else { return try await work() }
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let value = try await work()
            log(phase, startedAt: start, metadata: metadata())
            return value
        } catch {
            log(phase, startedAt: start, metadata: "\(metadata()) error=\(error)")
            throw error
        }
    }

    public static func log(_ phase: String, startedAt start: UInt64, metadata: String = "") {
        guard isEnabled else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        let suffix = metadata.isEmpty ? "" : " \(metadata)"
        let line = String(format: "quoin-edit-perf phase=%@ elapsed_ms=%.2f%@\n", phase, elapsed, suffix)
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
#endif
