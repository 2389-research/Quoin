import XCTest
@testable import QuoinCore

/// The editing-latency contract, enforced in CI: typing must feel
/// instantaneous in every editing mode, in every size of document, with or
/// without diagrams. "Feels instantaneous" is the classic keystroke-echo
/// standard: the whole loop fits in one 60 Hz frame (16 ms). The core's
/// slice of that loop (apply edit → re-parse → new snapshot) must therefore
/// stay well under it — the render layer still needs its share.
///
/// Two enforcement mechanisms, deliberately different:
/// 1. **Strategy assertions** (deterministic, noise-free): typing inside a
///    paragraph, a code fence, or a mermaid fence MUST take a block-local
///    fast path, never a full-document re-parse. This is what actually
///    guarantees "document length doesn't matter" — and it can't flake on a
///    slow CI runner.
/// 2. **Wall-clock ceilings** (best-of-N, generous headroom): catch
///    order-of-magnitude regressions the strategy check can't see (e.g. the
///    fast path itself going quadratic). Ceilings are ~3× the local numbers
///    because shared CI runners deliver 20–30% slower clocks with spikes.
final class EditingLatencyTests: XCTestCase {

    /// The budget table. One place to tune expectations.
    private enum Budget {
        /// Core slice of one keystroke (parseAfterEdit), any size, any mode.
        /// Best-in-class target is ≲2 ms locally; 25 ms is the CI ceiling
        /// that still fails unmistakably on any O(document·parse) keystroke
        /// (a full re-parse of the novel costs ~2,000 ms).
        static let keystrokeCore: TimeInterval = 0.025
        /// Opening a document (full parse), scaled per size. The PRD's
        /// budget is <1 s to interactive for 1 MB; these are CI ceilings.
        static func open(_ size: PerfFixtures.Size) -> TimeInterval {
            switch size {
            case .small: return 0.25
            case .medium: return 0.60
            case .large: return 1.80
            case .mobyDick: return 4.00
            }
        }
    }

    /// Best-of-N wall clock — the honest statistic for "how fast can this
    /// go" under scheduler noise (matches PerformanceTests' convention).
    private func bestOf(_ n: Int, _ work: () throws -> Void) rethrows -> TimeInterval {
        var best = TimeInterval.greatestFiniteMagnitude
        for _ in 0..<n {
            let start = Date()
            try work()
            best = min(best, Date().timeIntervalSince(start))
        }
        return best
    }

    private func insertEdit(at offset: Int, _ text: String = "x") -> SourceEdit {
        SourceEdit(range: ByteRange(offset: offset, length: 0), replacement: text)
    }

    /// The wall-clock ceilings are calibrated to Apple Silicon (the shipping
    /// platform) with ~3× headroom for shared macOS CI. Off Darwin — notably
    /// the Linux CI job, which runs emulated on contributor machines and 20–30%
    /// slower even natively — a timing assertion measures the host, not the
    /// code, so it would be a *bad* test. The deterministic strategy assertions
    /// (fast-path selection) still run everywhere and are the real guarantee;
    /// only the ceilings are Darwin-scoped. macOS CI keeps enforcing them.
    private func skipWallClockBudgetsOffDarwin() throws {
        #if !canImport(Darwin)
        throw XCTSkip("Wall-clock latency budgets are Apple-Silicon-calibrated; enforced on macOS CI only.")
        #endif
    }

    // MARK: - 1. Strategy: typing must never trigger a full re-parse

    func testTypingInProseUsesBlockLocalFastPath() throws {
        let doc = MarkdownConverter.parse(PerfFixtures.document(size: .medium, charts: true))
        let offset = try XCTUnwrap(PerfFixtures.proseEditOffset(in: doc))
        let result = try MarkdownConverter.parseAfterEdit(previous: doc, edit: insertEdit(at: offset))
        XCTAssertEqual(result.strategy, .plainParagraphFastPath,
                       "typing in prose re-parsed the whole document")
    }

    func testTypingInMermaidSourceUsesBlockLocalFastPath() throws {
        // The bug this suite was born from: typing into a mermaid block's
        // revealed source felt sluggish because every keystroke re-parsed
        // the entire document.
        let doc = MarkdownConverter.parse(PerfFixtures.document(size: .medium, charts: true))
        let offset = try XCTUnwrap(PerfFixtures.mermaidEditOffset(in: doc))
        let result = try MarkdownConverter.parseAfterEdit(previous: doc, edit: insertEdit(at: offset))
        XCTAssertEqual(result.strategy, .fencedBlockFastPath,
                       "typing in mermaid source re-parsed the whole document")
    }

    func testTypingInCodeFenceUsesBlockLocalFastPath() throws {
        let doc = MarkdownConverter.parse(PerfFixtures.document(size: .medium, charts: false))
        let offset = try XCTUnwrap(PerfFixtures.codeEditOffset(in: doc))
        let result = try MarkdownConverter.parseAfterEdit(previous: doc, edit: insertEdit(at: offset))
        XCTAssertEqual(result.strategy, .fencedBlockFastPath,
                       "typing in a code fence re-parsed the whole document")
    }

    func testFenceBreakingEditFallsBackToFullParse() throws {
        // Typing a backtick run could close the fence early and restructure
        // the document — the fast path must refuse and take the full parse.
        let doc = MarkdownConverter.parse(PerfFixtures.document(size: .medium, charts: true))
        let offset = try XCTUnwrap(PerfFixtures.mermaidEditOffset(in: doc))
        let result = try MarkdownConverter.parseAfterEdit(
            previous: doc, edit: insertEdit(at: offset, "\n```\n"))
        XCTAssertEqual(result.strategy, .full,
                       "a fence-breaking edit must not take the fast path")
    }

    // MARK: - 2. Wall clock: every mode, every size, one ceiling

    /// The characterization table the suite exists to keep honest: keystroke
    /// core latency per (size × mode). Every cell gets the SAME ceiling —
    /// that uniformity IS the "document length shouldn't matter, charts
    /// shouldn't matter" contract.
    func testKeystrokeCoreLatencyMeetsBudgetEverywhere() throws {
        try skipWallClockBudgetsOffDarwin()
        var report: [String] = []
        for size in PerfFixtures.Size.allCases {
            for charts in [false, true] {
                let source = PerfFixtures.document(size: size, charts: charts)
                let doc = MarkdownConverter.parse(source)

                var cells: [(mode: String, offset: Int?)] = [
                    ("prose", PerfFixtures.proseEditOffset(in: doc)),
                    ("code", PerfFixtures.codeEditOffset(in: doc)),
                ]
                if charts {
                    cells.append(("mermaid", PerfFixtures.mermaidEditOffset(in: doc)))
                }

                for (mode, offset) in cells {
                    guard let offset else { continue }
                    let edit = insertEdit(at: offset)
                    let best = try bestOf(5) {
                        _ = try MarkdownConverter.parseAfterEdit(previous: doc, edit: edit)
                    }
                    let label = "\(size.rawValue)\(charts ? "+charts" : "") \(mode)"
                    report.append(String(format: "%@ %.3f ms", label, best * 1000))
                    XCTAssertLessThan(
                        best, Budget.keystrokeCore,
                        "keystroke core latency blown: \(label) took \(best * 1000) ms"
                    )
                }
            }
        }
        print("keystroke-core-latency:\n  " + report.joined(separator: "\n  "))
    }

    /// Open (full parse) budgets per size — with and without charts held to
    /// the same ceiling: diagrams in the document must not tax opening it.
    func testOpenLatencyMeetsBudgetPerSize() throws {
        try skipWallClockBudgetsOffDarwin()
        for size in PerfFixtures.Size.allCases {
            for charts in [false, true] {
                let source = PerfFixtures.document(size: size, charts: charts)
                var blocks = 0
                let best = bestOf(3) {
                    blocks = MarkdownConverter.parse(source).blocks.count
                }
                XCTAssertGreaterThan(blocks, 1)
                XCTAssertLessThan(
                    best, Budget.open(size),
                    "open latency blown: \(size.rawValue)\(charts ? "+charts" : "") took \(best) s"
                )
            }
        }
    }

    // MARK: - 3. Fast path correctness: identical output to a full parse

    /// The fast paths must be invisible: for every covered edit, the
    /// incremental result must be indistinguishable from re-parsing the
    /// edited source from scratch — same blocks, same identities, same
    /// ranges, same outline, same stats, same hash. Byte-lossless round-trip
    /// is a project invariant; this extends it to parse-state losslessness.
    func testFastPathsProduceIdenticalDocuments() throws {
        let source = PerfFixtures.document(size: .medium, charts: true)
        let doc = MarkdownConverter.parse(source)

        var edits: [SourceEdit] = []
        for offset in [PerfFixtures.proseEditOffset(in: doc),
                       PerfFixtures.mermaidEditOffset(in: doc),
                       PerfFixtures.codeEditOffset(in: doc),
                       PerfFixtures.mathEditOffset(in: doc)].compactMap({ $0 }) {
            edits.append(insertEdit(at: offset))                    // insert one char
            edits.append(insertEdit(at: offset, "hello world"))     // insert a run
            edits.append(insertEdit(at: offset, "\n"))              // newline
            edits.append(SourceEdit(range: ByteRange(offset: offset, length: 2), replacement: ""))   // delete
            edits.append(SourceEdit(range: ByteRange(offset: offset, length: 1), replacement: "yz")) // replace
            edits.append(insertEdit(at: offset, "```"))             // fence hazard
            edits.append(insertEdit(at: offset, "$$"))              // math-fence hazard
        }

        for edit in edits {
            let incremental = try MarkdownConverter.parseAfterEdit(previous: doc, edit: edit)
            let (newSource, _) = try edit.apply(to: source)
            let reference = MarkdownConverter.parse(newSource)

            let context = "edit @\(edit.range.offset) len=\(edit.range.length) repl=\(edit.replacement.debugDescription) strategy=\(incremental.strategy)"
            XCTAssertEqual(incremental.document.source, reference.source, context)
            XCTAssertEqual(incremental.document.sourceHash, reference.sourceHash, context)
            XCTAssertEqual(incremental.document.blocks, reference.blocks, context)
            XCTAssertEqual(incremental.document.outline, reference.outline, context)
            XCTAssertEqual(incremental.document.stats, reference.stats, context)
            XCTAssertEqual(incremental.document.footnotes, reference.footnotes, context)
        }
    }

    /// Undo must survive the fast path: the inverse edit restores the
    /// original source exactly.
    func testFastPathInverseRestoresSource() throws {
        let source = PerfFixtures.document(size: .medium, charts: true)
        let doc = MarkdownConverter.parse(source)
        let offset = try XCTUnwrap(PerfFixtures.mermaidEditOffset(in: doc))
        let result = try MarkdownConverter.parseAfterEdit(
            previous: doc, edit: insertEdit(at: offset, "label"))
        let (restored, _) = try result.inverse.apply(to: result.document.source)
        XCTAssertEqual(restored, source)
    }
}
