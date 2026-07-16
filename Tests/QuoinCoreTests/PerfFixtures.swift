import Foundation
@testable import QuoinCore

/// Deterministic documents for the editing-latency suite, at four sizes and
/// two flavors (with and without mermaid diagrams sprinkled through). All
/// content is generated — no randomness, no bundled corpus files — so every
/// run measures the same bytes and CI diffs stay meaningful.
///
/// The prose deliberately reads like a real manuscript (long paragraphs,
/// varied sentences) rather than lorem ipsum: the parser's inline scanner
/// costs scale with real punctuation and word shapes.
enum PerfFixtures {

    /// Document sizes named for what they represent, not their byte counts.
    /// `mobyDick` is a full-novel-length manuscript (~1.2 MB — the actual
    /// Moby-Dick weighs in around 1.2 MB of UTF-8).
    enum Size: String, CaseIterable {
        case small      // a note              (~2 KB)
        case medium     // a long README       (~50 KB)
        case large      // a hefty spec        (~400 KB)
        case mobyDick   // a novel             (~1.2 MB)

        var targetBytes: Int {
            switch self {
            case .small: return 2_000
            case .medium: return 50_000
            case .large: return 400_000
            case .mobyDick: return 1_200_000
            }
        }
    }

    // MARK: - Generation

    /// A deterministic document of roughly `size.targetBytes` bytes. With
    /// `charts: true`, a mermaid diagram lands every few sections (cycling
    /// flowchart-with-subgraphs, sequence, pie, state) — "put some mermaid
    /// diagrams into moby dick".
    static func document(size: Size, charts: Bool) -> String {
        var out = "# The Editing Latency Manuscript (\(size.rawValue))\n\n"
        out += "Call me Ishmael. Some years ago—never mind how long precisely—having "
        out += "little or no money in my purse, and nothing particular to interest me "
        out += "on shore, I thought I would sail about a little and see the watery part "
        out += "of the world.\n\n"
        var section = 0
        while out.utf8.count < size.targetBytes {
            section += 1
            out += chapter(section, charts: charts)
        }
        return out
    }

    /// One chapter: heading, three long prose paragraphs, and rotating
    /// garnishes (mermaid / code / math / list / table) so every block kind
    /// the reader renders appears throughout the document. Chapter 1 always
    /// carries a diagram and a code block, so even the `small` fixture
    /// exercises every editing mode.
    private static func chapter(_ n: Int, charts: Bool) -> String {
        var out = "## Chapter \(n): \(chapterTitles[n % chapterTitles.count])\n\n"
        for p in 0..<3 {
            out += paragraph(seed: n * 3 + p) + "\n\n"
        }
        if charts, n % 4 == 1 {
            out += mermaidDiagram(index: n) + "\n\n"
        }
        switch n % 4 {
        case 1:
            out += """
            ```swift
            func chapter\(n)Heading() -> String {
                return "Chapter \(n)"  // computed, never stored
            }
            ```

            """
        case 2:
            out += """
            $$
            E_\(n) = m_\(n) c^2
            $$

            """
        case 3:
            out += """
            - the first consideration, weighed at length
            - [ ] a task not yet done in chapter \(n)
            - a second consideration, noted for later

            """
        default:
            out += """
            | Voyage | Duration | Outcome \(n) |
            |--------|---------:|---------|
            | first  | \(n) days | fair    |
            | second | \(n * 2) days | foul |

            """
        }
        return out
    }

    /// Long, punctuation-rich prose. Deterministic by seed, and UNIQUE per
    /// seed: the closing sentence carries the seed. (Identical paragraphs
    /// share a BlockID content hash, and the incremental parser's identity
    /// guard deliberately refuses ambiguous blocks — real documents rarely
    /// repeat whole paragraphs, and the fixture shouldn't either.)
    private static func paragraph(seed: Int) -> String {
        var sentences: [String] = []
        for s in 0..<5 {
            let i = (seed + s * 7) % proseSentences.count
            sentences.append(proseSentences[i])
        }
        sentences.append("So closed the \(seed)th hour of the voyage, according to the log.")
        return sentences.joined(separator: " ")
    }

    /// A rotating set of mermaid diagrams — including a flowchart with
    /// subgraphs, the everyday sequence set, a pie, and a state machine —
    /// so chart-bearing documents exercise the real diagram pipeline.
    static func mermaidDiagram(index: Int) -> String {
        switch index % 4 {
        case 0:
            return """
            ```mermaid
            flowchart TD
                A\(index)[Weigh anchor] --> B{Wind fair?}
                B -->|yes| C[Set course]
                B -->|no| D[Wait in port]
                subgraph nav [Navigation]
                    C --> E[Take bearings]
                    E --> F[Log position]
                end
                F --> G[Stand watch]
            ```
            """
        case 1:
            return """
            ```mermaid
            sequenceDiagram
                participant C as Captain
                participant M as Mate \(index)
                C->>+M: Report soundings
                M-->>-C: Twelve fathoms
                Note over C,M: entry logged
            ```
            """
        case 2:
            return """
            ```mermaid
            pie title Rations week \(index)
                "Biscuit" : 40
                "Salt pork" : 35
                "Water" : 25
            ```
            """
        default:
            return """
            ```mermaid
            stateDiagram-v2
                [*] --> Port
                Port --> AtSea : depart \(index)
                AtSea --> Port : return
                AtSea --> [*] : wreck
            ```
            """
        }
    }

    // MARK: - Edit-target helpers

    /// A byte offset strictly inside a plain-prose paragraph near the middle
    /// of the document — where a typist's caret usually is.
    static func proseEditOffset(in document: QuoinDocument) -> Int? {
        let paragraphs = document.blocks.filter {
            if case .paragraph = $0.kind { return true }
            return false
        }
        guard !paragraphs.isEmpty else { return nil }
        let block = paragraphs[paragraphs.count / 2]
        return block.range.offset + min(10, block.range.length - 1)
    }

    /// A byte offset strictly inside the CONTENT of a mermaid block near the
    /// middle of the document (past the opening fence line, before the
    /// closing fence line) — the caret position of someone editing a chart.
    static func mermaidEditOffset(in document: QuoinDocument) -> Int? {
        embedContentOffset(in: document) {
            if case .mermaid = $0 { return true }
            return false
        }
    }

    /// Same, for a fenced code block.
    static func codeEditOffset(in document: QuoinDocument) -> Int? {
        embedContentOffset(in: document) {
            if case .codeBlock = $0 { return true }
            return false
        }
    }

    /// Same, for a `$$ … $$` math block.
    static func mathEditOffset(in document: QuoinDocument) -> Int? {
        embedContentOffset(in: document) {
            if case .mathBlock = $0 { return true }
            return false
        }
    }

    private static func embedContentOffset(
        in document: QuoinDocument,
        matching: (BlockKind) -> Bool
    ) -> Int? {
        let embeds = document.blocks.filter { matching($0.kind) }
        guard !embeds.isEmpty else { return nil }
        let block = embeds[embeds.count / 2]
        guard let slice = document.source.substring(in: block.range) else { return nil }
        // Land after the opening fence line + a few characters, safely inside
        // the content region.
        guard let firstNewline = slice.utf8.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let contentStart = slice.utf8.distance(from: slice.utf8.startIndex, to: firstNewline) + 1
        return block.range.offset + contentStart + 3
    }

    // MARK: - Corpus

    private static let chapterTitles = [
        "Loomings", "The Carpet-Bag", "The Spouter-Inn", "The Counterpane",
        "Breakfast", "The Street", "The Chapel", "The Pulpit", "The Sermon",
        "A Bosom Friend", "Nightgown", "Biographical", "Wheelbarrow",
    ]

    private static let proseSentences = [
        "The ship groaned in every timber as the swell lifted her bows toward a horizon the color of old pewter.",
        "Whenever it is a damp, drizzly November in my soul, I account it high time to get to sea as soon as I can.",
        "There is nothing surprising in this; were they but known, almost all men cherish very nearly the same feelings toward the ocean.",
        "He kept a log with a patience that bordered on devotion, each entry shorter than the weather deserved.",
        "The harbor at dawn smelled of tar, hemp, and the particular optimism of departures.",
        "Consider the subtleness of the sea; how its most dreaded creatures glide under water, unapparent for the most part.",
        "A crew is a small nation, and like all nations it runs on bread, rumor, and the settled order of watches.",
        "By noon the wind had backed two points and the mate's whistle set the deck to a brisk, wordless choreography.",
        "Nothing in the charts had prepared them for the green stillness that followed, a calm with the texture of held breath.",
        "It is not down on any map; true places never are.",
        "The carpenter measured twice out of habit and a third time out of respect for the sea's opinion of assumptions.",
        "Better to sleep with a sober cannibal than a drunken Christian, he reflected, and turned the page of his almanac.",
    ]
}
