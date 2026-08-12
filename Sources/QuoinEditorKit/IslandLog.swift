import Foundation

/// Opt-in diagnostic tracing for the editable-islands / recycler activation path
/// (Phase 3). The OLD projection reader (QuoinRender/AppKit) carries
/// `QUOIN_EDIT_PERF_LOG` tags, but the recycler + island path had NO logging —
/// this fills that gap so a single real click can be traced from the redirected
/// `/tmp/quoin.log`.
///
/// Gated behind `QUOIN_ISLAND_LOG=1` (mirrors `QuoinPerformanceTrace`'s
/// `QUOIN_EDIT_PERF_LOG` idiom). Zero cost when off: the flag is read once into a
/// `static let`, and the message closure is `@autoclosure` so it is never
/// evaluated unless the flag is set. Every line is a one-liner tagged
/// `[island] <tag> <msg>` and lands in NSLog (the app redirects NSLog to
/// `/tmp/quoin.log`).
public enum IslandLog {
    /// Read ONCE at first touch; no per-call environment lookup on the hot path.
    public static let enabled = ProcessInfo.processInfo.environment["QUOIN_ISLAND_LOG"] == "1"
}

/// Emit `[island] <tag> <msg>` via NSLog when `QUOIN_ISLAND_LOG=1`. No-op (and
/// the `msg` closure is never evaluated) when the flag is off.
@inline(__always)
public func ilog(_ tag: String, _ msg: @autoclosure () -> String = "") {
    guard IslandLog.enabled else { return }
    NSLog("[island] %@ %@", tag, msg())
}

/// First `count` frames of the current call stack, joined on " ← ", for the
/// "who called this" diagnostics (deactivate / clearEditing / setDocument). Only
/// built when the flag is on (callers wrap the call site accordingly), but cheap
/// enough to be safe regardless.
func islandShortStack(_ count: Int) -> String {
    Thread.callStackSymbols.prefix(count).joined(separator: " ← ")
}
