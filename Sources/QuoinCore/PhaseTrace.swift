import Foundation

/// Opt-in, env-gated stage timing for the hot pipelines, mirroring the
/// `QUOIN_EDIT_PERF_LOG` idiom in QuoinRender. It answers "which stage of a
/// parse or render actually costs the milliseconds" without a profiler:
///
/// - `QUOIN_PARSE_PHASE_LOG=1` — `MarkdownConverter.parse` emits one stderr
///   block per full parse, splitting `parse.initial` into its stages
///   (front-matter/endmatter split, macro scan, display-math prescan, cmark,
///   tree walk, footnotes/stats, source hash).
/// - `QUOIN_RENDER_PHASE_LOG=1` — `AttributedRenderer.render` emits a
///   per-block-kind breakdown of a cold render (time + count per kind), so the
///   heavy kinds (math, diagrams, code) are visible against cheap prose.
///
/// Cost when unset is a single cached environment read; the accumulator is only
/// allocated when the flag is on, so instrumented builds and shipping builds
/// run the same code path in production.
public enum PhaseTrace {
    public static let parseEnabled: Bool =
        ProcessInfo.processInfo.environment["QUOIN_PARSE_PHASE_LOG"] == "1"
    public static let renderEnabled: Bool =
        ProcessInfo.processInfo.environment["QUOIN_RENDER_PHASE_LOG"] == "1"

    /// Sequential stopwatch: `lap(_:)` records the interval since the previous
    /// lap (or construction) under a label; `emit(_:)` prints the labelled
    /// intervals with per-stage percentages of the total.
    public struct Stopwatch {
        private var mark: UInt64
        private var laps: [(label: String, ms: Double)] = []

        public init() { mark = DispatchTime.now().uptimeNanoseconds }

        public mutating func lap(_ label: String) {
            let now = DispatchTime.now().uptimeNanoseconds
            laps.append((label, Double(now &- mark) / 1_000_000))
            mark = now
        }

        public func emit(_ title: String) {
            let total = laps.reduce(0) { $0 + $1.ms }
            var out = String(format: "[%@]  total %.2f ms\n", title, total)
            for lap in laps {
                let pct = total > 0 ? lap.ms / total * 100 : 0
                out += String(format: "    %-24@ %8.2f ms  %5.1f%%\n",
                              lap.label as NSString, lap.ms, pct)
            }
            FileHandle.standardError.write(Data(out.utf8))
        }
    }

    /// Keyed accumulator: sums time and counts across repeated `add(_:_:)`
    /// calls under the same key, then `emit(_:)` prints them largest-first.
    public struct Tally {
        private var totals: [String: (ms: Double, count: Int)] = [:]

        public init() {}

        public mutating func add(_ key: String, _ ms: Double) {
            var entry = totals[key] ?? (0, 0)
            entry.ms += ms
            entry.count += 1
            totals[key] = entry
        }

        public func emit(_ title: String) {
            let grand = totals.values.reduce(0) { $0 + $1.ms }
            var out = String(format: "[%@]  total %.2f ms across %d blocks\n",
                             title, grand, totals.values.reduce(0) { $0 + $1.count })
            for (key, entry) in totals.sorted(by: { $0.value.ms > $1.value.ms }) {
                let pct = grand > 0 ? entry.ms / grand * 100 : 0
                let per = entry.count > 0 ? entry.ms / Double(entry.count) : 0
                out += String(format: "    %-16@ %8.2f ms  %5.1f%%  (%5d blocks, %.4f ms/block)\n",
                              key as NSString, entry.ms, pct, entry.count, per)
            }
            FileHandle.standardError.write(Data(out.utf8))
        }
    }

    /// Time a single closure in milliseconds (used to wrap one block's render).
    @inline(__always)
    public static func timed<T>(_ work: () -> T) -> (value: T, ms: Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = work()
        return (value, Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }
}
