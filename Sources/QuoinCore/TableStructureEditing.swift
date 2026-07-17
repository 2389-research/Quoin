import Foundation

/// Structural, table-aware source edits for GFM pipe tables (#14): insert /
/// delete rows and columns, set a column's alignment, and normalize padding —
/// so a user never has to count pipes or align delimiter colons by hand.
///
/// Like ``StructureEditing`` and ``BlockEditing``, every operation works on a
/// table's SOURCE SLICE (the bytes at the table block's `range`) and returns a
/// `SourceEdit` whose `range` is RELATIVE to that slice (offset 0 = the first
/// byte of the slice). The caller rebases it by the block's absolute offset and
/// applies it through the normal `DocumentSession` pipeline, so undo,
/// byte-losslessness for other blocks, and re-projection all hold by
/// construction. Only the affected table is re-padded; nothing outside its
/// slice is touched.
///
/// Existing cell text and per-column alignment always survive a structural
/// edit: the slice is parsed into a model, mutated, and re-rendered with a
/// regenerated delimiter row. Ragged or malformed input degrades gracefully —
/// a slice whose second line is not a valid delimiter row is not a table, so
/// every operation returns nil and the UI stays quiet (never corruption).
///
/// All line handling is scalar-based to avoid Swift's `\r\n`-is-one-Character
/// trap, and the slice's original line terminator and trailing newline are
/// preserved so the boundary with neighbouring blocks stays byte-lossless.
extension TableEditing {

    // MARK: - Parsed model

    /// A GFM pipe table parsed from its source slice. Cells are trimmed of the
    /// surrounding pad whitespace but keep their inner content verbatim
    /// (including escaped `\|`). `header`, every row in `rows`, and
    /// `alignments` are all padded to `columnCount`, so the model is always
    /// rectangular even when the input was ragged.
    public struct ParsedTable: Equatable, Sendable {
        public var header: [String]
        public var alignments: [TableAlignment]
        public var rows: [[String]]
        /// The line terminator to write between rows (`"\n"` or `"\r\n"`),
        /// taken from the source slice so CRLF files round-trip.
        public var terminator: String
        /// The slice's trailing terminator (`""` when it does not end in a
        /// newline), preserved so the block boundary stays byte-lossless.
        public var trailingTerminator: String

        public var columnCount: Int { header.count }

        public init(
            header: [String], alignments: [TableAlignment], rows: [[String]],
            terminator: String = "\n", trailingTerminator: String = ""
        ) {
            self.header = header
            self.alignments = alignments
            self.rows = rows
            self.terminator = terminator
            self.trailingTerminator = trailingTerminator
        }
    }

    /// A physical line and its terminator (`""`, `"\n"`, or `"\r\n"`).
    private struct PhysicalLine {
        var content: String
        var terminator: String
    }

    /// Split into physical lines without tripping over CRLF graphemes (mirrors
    /// `StructureEditing.lines`). A slice ending in a newline yields no phantom
    /// trailing empty line.
    private static func physicalLines(of slice: String) -> [PhysicalLine] {
        var result: [PhysicalLine] = []
        var content = String.UnicodeScalarView()
        let scalars = slice.unicodeScalars
        var i = scalars.startIndex
        while i < scalars.endIndex {
            let scalar = scalars[i]
            if scalar == "\n" {
                result.append(PhysicalLine(content: String(content), terminator: "\n"))
                content = String.UnicodeScalarView()
            } else if scalar == "\r" {
                let next = scalars.index(after: i)
                if next < scalars.endIndex, scalars[next] == "\n" {
                    result.append(PhysicalLine(content: String(content), terminator: "\r\n"))
                    content = String.UnicodeScalarView()
                    i = next
                } else {
                    content.append(scalar)
                }
            } else {
                content.append(scalar)
            }
            i = scalars.index(after: i)
        }
        if !content.isEmpty {
            result.append(PhysicalLine(content: String(content), terminator: ""))
        }
        return result
    }

    /// Split a table row line into its cell contents. Strips one optional
    /// leading and one optional trailing pipe (GFM tables may omit the outer
    /// pipes), then splits on UNESCAPED `|` so a `\|` stays inside its cell.
    /// Each returned cell is trimmed of surrounding spaces/tabs.
    static func splitCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }

        var cells: [String] = []
        var current = String.UnicodeScalarView()
        var previous: Unicode.Scalar = " "
        for scalar in trimmed.unicodeScalars {
            if scalar == "|" && previous != "\\" {
                cells.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
            previous = scalar
        }
        cells.append(String(current))
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// True when every cell of a candidate delimiter line matches GFM's
    /// `:?-+:?` shape (at least one dash, optional leading/trailing colon).
    private static func isDelimiterRow(_ cells: [String]) -> Bool {
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            cell.range(of: "^:?-+:?$", options: .regularExpression) != nil
        }
    }

    private static func alignment(ofDelimiterCell cell: String) -> TableAlignment {
        let left = cell.hasPrefix(":")
        let right = cell.hasSuffix(":")
        switch (left, right) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        case (false, false): return .none
        }
    }

    /// Parses a table source slice into ``ParsedTable``, or nil when the slice
    /// is not a well-formed GFM pipe table (needs a header line plus a valid
    /// delimiter line directly beneath it). Ragged body rows are accepted and
    /// padded; the model normalizes to the widest row so no cell text is lost.
    public static func parse(_ tableSource: String) -> ParsedTable? {
        let physical = physicalLines(of: tableSource)
        // Drop trailing blank lines (they belong to the block separator, not
        // the table) but remember the slice's real trailing terminator.
        var lines = physical
        let trailingTerminator = lines.last?.terminator ?? ""
        while let last = lines.last,
              last.content.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        guard lines.count >= 2 else { return nil }

        let headerCells = splitCells(lines[0].content)
        guard !headerCells.isEmpty,
              !(headerCells.count == 1 && headerCells[0].isEmpty) else { return nil }

        let delimiterCells = splitCells(lines[1].content)
        guard isDelimiterRow(delimiterCells) else { return nil }

        // Any remaining line must be a body row (a blank line would have ended
        // the table in GFM); skip stray blanks defensively.
        var bodyRows: [[String]] = []
        for line in lines.dropFirst(2) {
            if line.content.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            bodyRows.append(splitCells(line.content))
        }

        // Rectangularize to the widest row so ragged input never loses text.
        let columnCount = max(
            headerCells.count,
            delimiterCells.count,
            bodyRows.map(\.count).max() ?? 0)
        func padded(_ cells: [String]) -> [String] {
            cells + Array(repeating: "", count: max(0, columnCount - cells.count))
        }
        var alignments = delimiterCells.map(alignment(ofDelimiterCell:))
        alignments += Array(repeating: .none, count: max(0, columnCount - alignments.count))

        return ParsedTable(
            header: padded(headerCells),
            alignments: alignments,
            rows: bodyRows.map(padded),
            terminator: lines[0].terminator.isEmpty ? "\n" : lines[0].terminator,
            trailingTerminator: trailingTerminator)
    }

    // MARK: - Rendering

    /// The minimum inner width of a column, so even a one-character column has
    /// a delimiter that fits `:-:` (centered).
    private static let minColumnWidth = 3

    /// Renders a ``ParsedTable`` back to normalized, padded GFM source. Each
    /// column is widened to its longest cell (min 3), content is left-justified
    /// with a one-space pad on each side, and the delimiter row is regenerated
    /// from `alignments`.
    public static func render(_ table: ParsedTable) -> String {
        let columns = table.columnCount
        guard columns > 0 else { return "" }

        var widths = [Int](repeating: minColumnWidth, count: columns)
        func widen(_ cells: [String]) {
            for (index, cell) in cells.enumerated() where index < columns {
                widths[index] = max(widths[index], cell.count)
            }
        }
        widen(table.header)
        for row in table.rows { widen(row) }

        func leftJustify(_ cell: String, _ width: Int) -> String {
            cell + String(repeating: " ", count: max(0, width - cell.count))
        }
        func rowLine(_ cells: [String]) -> String {
            var padded = cells
            if padded.count < columns {
                padded += Array(repeating: "", count: columns - padded.count)
            }
            let body = (0..<columns).map { leftJustify(padded[$0], widths[$0]) }
                .joined(separator: " | ")
            return "| " + body + " |"
        }
        func delimiterCell(_ alignment: TableAlignment, _ width: Int) -> String {
            switch alignment {
            case .none: return String(repeating: "-", count: width)
            case .left: return ":" + String(repeating: "-", count: width - 1)
            case .right: return String(repeating: "-", count: width - 1) + ":"
            case .center: return ":" + String(repeating: "-", count: width - 2) + ":"
            }
        }
        func delimiterLine() -> String {
            let body = (0..<columns)
                .map { delimiterCell(table.alignments[$0], widths[$0]) }
                .joined(separator: " | ")
            return "| " + body + " |"
        }

        var lines = [rowLine(table.header), delimiterLine()]
        lines += table.rows.map(rowLine)
        return lines.joined(separator: table.terminator) + table.trailingTerminator
    }

    // MARK: - Grid coordinates

    /// Where a caret at `offsetUTF16` (a UTF-16 offset into the table slice)
    /// falls, as a grid row and column. Grid row 0 is the header; the delimiter
    /// line also maps to row 0 (so "insert below" adds a first body row); body
    /// lines map to rows 1…N. Column counts UNESCAPED pipes on the caret's
    /// line. Returns nil when the slice is not a table.
    public static func location(
        forOffsetUTF16 offsetUTF16: Int, in tableSource: String
    ) -> (row: Int, column: Int)? {
        guard let table = parse(tableSource) else { return nil }
        let lines = physicalLines(of: tableSource)
        guard !lines.isEmpty else { return nil }

        // Find the physical line holding the offset and the offset within it.
        var consumed = 0
        var lineIndex = lines.count - 1
        var withinLine = 0
        let clamped = max(0, offsetUTF16)
        for (index, line) in lines.enumerated() {
            let length = line.content.utf16.count + line.terminator.utf16.count
            if clamped < consumed + length {
                lineIndex = index
                withinLine = clamped - consumed
                break
            }
            consumed += length
            withinLine = line.content.utf16.count
        }

        // Grid row: header (line 0) and delimiter (line 1) → row 0; body → 1…N.
        let row = lineIndex <= 1 ? 0 : lineIndex - 1

        // Column: count unescaped pipes before the offset, discounting the
        // optional leading pipe. Clamp into the valid range.
        let content = Array(lines[lineIndex].content.utf16)
        let hasLeadingPipe: Bool = {
            let trimmed = lines[lineIndex].content.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("|")
        }()
        let pipe = UInt16(UnicodeScalar("|").value)
        let backslash = UInt16(UnicodeScalar("\\").value)
        var pipes = 0
        var previous: UInt16 = 0
        let upTo = min(withinLine, content.count)
        for i in 0..<upTo {
            if content[i] == pipe && previous != backslash { pipes += 1 }
            previous = content[i]
        }
        var column = hasLeadingPipe ? pipes - 1 : pipes
        column = max(0, min(column, table.columnCount - 1))
        return (row, column)
    }

    // MARK: - Structural operations

    /// The byte length of `slice` (a `SourceEdit` range is UTF-8).
    private static func byteLength(_ slice: String) -> Int { slice.utf8.count }

    /// Builds a whole-slice replacement edit, or nil when the render is
    /// byte-identical to the input (a no-op should not enter the undo stack).
    private static func replacement(
        _ table: ParsedTable, original: String
    ) -> SourceEdit? {
        let rendered = render(table)
        guard rendered != original else { return nil }
        return SourceEdit(
            range: ByteRange(offset: 0, length: byteLength(original)),
            replacement: rendered)
    }

    /// Insert an empty row above or below grid `row`. `above` on the header
    /// (row 0) is refused (a GFM table's header must stay first); `below` the
    /// header inserts a new first body row. Returns a slice-relative
    /// `SourceEdit`, or nil for a non-table / invalid target.
    public static func insertRowEdit(
        in tableSource: String, at row: Int, above: Bool
    ) -> SourceEdit? {
        guard var table = parse(tableSource) else { return nil }
        // Body index in `rows` where the new row lands.
        let bodyInsert: Int
        if above {
            guard row >= 1 else { return nil } // cannot precede the header
            bodyInsert = row - 1
        } else {
            bodyInsert = row // below row 0 → 0; below body row k → k
        }
        let index = max(0, min(bodyInsert, table.rows.count))
        table.rows.insert(Array(repeating: "", count: table.columnCount), at: index)
        return replacement(table, original: tableSource)
    }

    /// Delete grid `row`. The header (row 0) cannot be deleted. Returns nil for
    /// a non-table, the header, or an out-of-range body row.
    public static func deleteRowEdit(in tableSource: String, at row: Int) -> SourceEdit? {
        guard var table = parse(tableSource) else { return nil }
        guard row >= 1 else { return nil }
        let bodyIndex = row - 1
        guard table.rows.indices.contains(bodyIndex) else { return nil }
        table.rows.remove(at: bodyIndex)
        return replacement(table, original: tableSource)
    }

    /// Insert an empty column to the left or right of `column`.
    public static func insertColumnEdit(
        in tableSource: String, at column: Int, left: Bool
    ) -> SourceEdit? {
        guard var table = parse(tableSource) else { return nil }
        let index = max(0, min(left ? column : column + 1, table.columnCount))
        table.header.insert("", at: index)
        table.alignments.insert(.none, at: index)
        for rowIndex in table.rows.indices {
            table.rows[rowIndex].insert("", at: index)
        }
        return replacement(table, original: tableSource)
    }

    /// Delete `column`. Refused when only one column remains (that would
    /// destroy the table). Returns nil for a non-table or out-of-range index.
    public static func deleteColumnEdit(in tableSource: String, at column: Int) -> SourceEdit? {
        guard var table = parse(tableSource) else { return nil }
        guard table.columnCount > 1, table.header.indices.contains(column) else { return nil }
        table.header.remove(at: column)
        table.alignments.remove(at: column)
        for rowIndex in table.rows.indices {
            if table.rows[rowIndex].indices.contains(column) {
                table.rows[rowIndex].remove(at: column)
            }
        }
        return replacement(table, original: tableSource)
    }

    /// Set `column`'s alignment (regenerating the delimiter row). Existing
    /// cell text is untouched. Returns nil for a non-table or bad index.
    public static func setAlignmentEdit(
        in tableSource: String, at column: Int, to alignment: TableAlignment
    ) -> SourceEdit? {
        guard var table = parse(tableSource) else { return nil }
        guard table.alignments.indices.contains(column) else { return nil }
        table.alignments[column] = alignment
        return replacement(table, original: tableSource)
    }

    /// Re-pad the table to normalized widths and a regenerated delimiter row
    /// without changing structure. Returns nil when it is already normalized.
    public static func normalizeEdit(in tableSource: String) -> SourceEdit? {
        guard let table = parse(tableSource) else { return nil }
        return replacement(table, original: tableSource)
    }

    /// Move grid `row` up or down by one, swapping it with its neighbour. The
    /// header is fixed in place; a body row cannot cross above the first body
    /// row's boundary into the header. Returns nil when the move is impossible.
    public static func moveRowEdit(in tableSource: String, at row: Int, up: Bool) -> SourceEdit? {
        guard var table = parse(tableSource) else { return nil }
        guard row >= 1 else { return nil } // header is fixed
        let bodyIndex = row - 1
        let targetBody = up ? bodyIndex - 1 : bodyIndex + 1
        guard table.rows.indices.contains(bodyIndex),
              table.rows.indices.contains(targetBody) else { return nil }
        table.rows.swapAt(bodyIndex, targetBody)
        return replacement(table, original: tableSource)
    }

    /// Move `column` left or right by one, swapping header cells, alignments,
    /// and every body cell. Returns nil when the move is impossible.
    public static func moveColumnEdit(in tableSource: String, at column: Int, left: Bool) -> SourceEdit? {
        guard var table = parse(tableSource) else { return nil }
        let target = left ? column - 1 : column + 1
        guard table.header.indices.contains(column),
              table.header.indices.contains(target) else { return nil }
        table.header.swapAt(column, target)
        table.alignments.swapAt(column, target)
        for rowIndex in table.rows.indices {
            if table.rows[rowIndex].indices.contains(column),
               table.rows[rowIndex].indices.contains(target) {
                table.rows[rowIndex].swapAt(column, target)
            }
        }
        return replacement(table, original: tableSource)
    }
}
