import Foundation

/// Block-granularity source edits (UI refresh ideas #9/#10/#11): pure
/// byte-exact `SourceEdit` builders for the context menu's block actions.
/// Everything preserves the bytes BETWEEN blocks verbatim — moving a
/// block swaps slices around the untouched separator, so round-trip
/// losslessness holds by construction.
public enum BlockEditing {

    public enum MoveDirection: Sendable {
        case up, down
    }

    /// Swaps a block with its neighbor. The separator bytes between the
    /// two stay exactly where they are; only the slices trade places.
    public static func moveEdit(
        source: String, blocks: [Block], blockIndex: Int, direction: MoveDirection
    ) -> SourceEdit? {
        let neighborIndex = direction == .up ? blockIndex - 1 : blockIndex + 1
        guard blocks.indices.contains(blockIndex),
              blocks.indices.contains(neighborIndex) else { return nil }
        let first = blocks[min(blockIndex, neighborIndex)]
        let second = blocks[max(blockIndex, neighborIndex)]
        guard let firstSlice = source.substring(in: first.range),
              let secondSlice = source.substring(in: second.range),
              let between = source.substring(in: ByteRange(
                offset: first.range.upperBound,
                length: second.range.offset - first.range.upperBound))
        else { return nil }
        let combined = ByteRange(
            offset: first.range.offset,
            length: second.range.upperBound - first.range.offset)
        return SourceEdit(range: combined, replacement: secondSlice + between + firstSlice)
    }

    /// Duplicates a block immediately below itself.
    public static func duplicateEdit(
        source: String, blocks: [Block], blockIndex: Int
    ) -> SourceEdit? {
        guard blocks.indices.contains(blockIndex),
              let slice = source.substring(in: blocks[blockIndex].range) else { return nil }
        return SourceEdit(
            range: ByteRange(offset: blocks[blockIndex].range.upperBound, length: 0),
            replacement: "\n\n" + slice)
    }

    /// Deletes a block plus ONE side's separator so no orphan blank lines
    /// remain (the following separator when one exists, else the
    /// preceding one for the document's last block).
    public static func deleteEdit(
        source: String, blocks: [Block], blockIndex: Int
    ) -> SourceEdit? {
        guard blocks.indices.contains(blockIndex) else { return nil }
        let block = blocks[blockIndex]
        var start = block.range.offset
        var end = block.range.upperBound
        if blockIndex + 1 < blocks.count {
            end = blocks[blockIndex + 1].range.offset
        } else if blockIndex > 0 {
            start = blocks[blockIndex - 1].range.upperBound
        } else {
            // Sole block: consume only the block's own line terminator.
            // Taking everything to EOF (the old behavior) erased trailing
            // bytes that belong to no rendered block — blank lines, stray
            // whitespace, link reference definitions — breaking the
            // byte-lossless rule (launch ledger, data integrity #15).
            let utf8 = source.utf8
            var index = utf8.index(utf8.startIndex, offsetBy: end)
            if index < utf8.endIndex, utf8[index] == 0x0D { // CR of a CRLF
                end += 1
                index = utf8.index(after: index)
            }
            if index < utf8.endIndex, utf8[index] == 0x0A { // LF
                end += 1
            }
        }
        return SourceEdit(range: ByteRange(offset: start, length: end - start), replacement: "")
    }
}

/// Pipe-table structure edits (idea #11): append a row or a column to a
/// GFM table's source. Conservative by design — anything that doesn't
/// look like a well-formed pipe table returns nil and the UI stays quiet.
public enum TableEditing {

    /// Appends an empty row matching the table's column count.
    public static func addingRow(to tableSource: String) -> String? {
        let lines = tableSource.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.first, columnCount(of: String(header)) > 0 else { return nil }
        let columns = columnCount(of: String(header))
        let row = "| " + Array(repeating: "  ", count: columns).joined(separator: " | ") + " |"
        let trimmed = tableSource.hasSuffix("\n") ? String(tableSource.dropLast()) : tableSource
        let suffix = tableSource.hasSuffix("\n") ? "\n" : ""
        return trimmed + "\n" + row + suffix
    }

    /// Appends an empty trailing column to every row (and `---` to the
    /// delimiter row).
    public static func addingColumn(to tableSource: String) -> String? {
        let lines = tableSource.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return nil }
        var result: [String] = []
        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(line)
                continue
            }
            guard columnCount(of: line) > 0 else { return nil }
            let base = line.trimmingCharacters(in: .whitespaces)
            let closed = base.hasSuffix("|") ? base : base + " |"
            result.append(closed + (index == 1 ? " --- |" : "   |"))
        }
        return result.joined(separator: "\n")
    }

    /// Smart paste (idea #4): tab-separated text (a spreadsheet selection)
    /// becomes a GFM table. Conservative: needs ≥2 rows, ≥2 uniform
    /// columns, else nil and the paste stays literal.
    public static func markdownTable(fromTabular text: String) -> String? {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        guard rows.count >= 2, let columns = rows.first?.count, columns >= 2,
              rows.allSatisfy({ $0.count == columns }) else { return nil }
        func line(_ cells: [String]) -> String {
            "| " + cells.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " | ") + " |"
        }
        var output = [line(rows[0]),
                      "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"]
        output += rows.dropFirst().map(line)
        return output.joined(separator: "\n")
    }

    private static func columnCount(of line: String) -> Int {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return 0 }
        // Cells = pipe count - 1 (unescaped pipes only; escaped \| stays).
        var count = 0
        var previous: Character = " "
        for character in trimmed {
            if character == "|" && previous != "\\" { count += 1 }
            previous = character
        }
        return max(0, count - 1)
    }
}
