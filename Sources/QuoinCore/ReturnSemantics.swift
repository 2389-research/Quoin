/// THE Return rule table: what the Return key MEANS in each kind of block.
///
/// Markdown has no empty-paragraph representation, so a lone `\n` inside a
/// paragraph is a SOFT BREAK — it re-parses to the same block and renders as a
/// space. That is why "type a line, press Enter, nothing happens": Return was
/// semantically dead, not flaky. Prose therefore needs a real paragraph break
/// (`\n\n`) — but a blank line TERMINATES a table, so this cannot be a blanket
/// rule.
///
/// Keyed on `BlockKind`, deliberately NOT on `EditingFlavor`: flavor answers
/// "how does this block reveal" and calls tables `.prose`. Two recognizers for
/// one grammar diverge (CLAUDE.md); this is the only recognizer.
///
/// The switch is exhaustive with no `default:` — adding a BlockKind must FAIL
/// TO COMPILE until someone decides what Return does there.
public enum ReturnSemantics {

    public enum Mode: Equatable, Sendable {
        /// Insert `\n\n` — a real new paragraph.
        case paragraphBreak
        /// Continue the list marker; an empty item ends the list.
        case listAware
        /// Continue the `> ` prefix; an empty quoted line exits the quote.
        case quoteAware
        /// Insert `\n` plus an empty pipe row. NEVER a blank line.
        case tableRow
        /// Raw source: a newline is a newline.
        case verbatim
    }

    public static func mode(for kind: BlockKind) -> Mode {
        switch kind {
        case .paragraph, .heading:
            return .paragraphBreak
        case .list:
            return .listAware
        case .blockQuote, .callout:
            return .quoteAware
        case .table:
            return .tableRow
        case .codeBlock, .diagram, .mathBlock, .htmlBlock,
             .frontMatter, .reviewEndmatter:
            return .verbatim
        case .tableOfContents, .thematicBreak:
            // Generated/atomic blocks: nothing sensible to split. A plain
            // newline is the least surprising no-op-ish behavior.
            return .verbatim
        }
    }
}
