#if canImport(AppKit) || canImport(UIKit)
import Foundation
import CoreGraphics
import QuoinCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The geometry of a rendered table, computed once from its cells and then
/// consumed while emitting rows. Pulling this out of `AttributedRenderer`'s
/// row loop separates the *measuring* (column widths, alignment inference,
/// tab-stop placement — a pure function of the cells, fonts, and a text
/// measurer) from the *emitting* (walking rows into attributed runs). The
/// measurer is injected, so the layout unit-tests with deterministic widths
/// and no font dependency, mirroring `DiagramLayoutEngine`.
struct TableLayout {
    /// `max(header.count, widest row)`.
    let columnCount: Int
    /// Per-column width: the widest cell, capped at `maxColumnWidth`.
    let widths: [CGFloat]
    /// Resolved per-column alignment (explicit marker, else numeric → right).
    let alignments: [NSTextAlignment]
    /// Whether a column's body cells are all numeric (drives tabular numerals).
    let isNumeric: [Bool]
    /// Alignment tab stops at each column start after the first.
    let tabStops: [NSTextTab]
    /// Content width of the table (last column's right edge), for the rules.
    let totalWidth: CGFloat
    /// The left edge (x) of the WIDEST column — the one most likely to wrap.
    /// Used as the row paragraph's `headIndent` so a long prose cell's
    /// wrapped lines stay under their column instead of collapsing to the
    /// left margin (tab stops can't hold a wrapping column). Handles the
    /// common "one wide last/prose column" table; a second wide column in the
    /// same row would still misalign — the real fix is block layout.
    let wrapIndent: CGFloat

    /// Measures a cell's rendered text width in the given font.
    typealias Measurer = (_ text: String, _ font: PlatformFont) -> CGFloat

    /// Computes the layout, or nil for an empty table (no columns).
    static func compute(
        header: [TableCell],
        rows: [[TableCell]],
        alignments explicit: [TableAlignment],
        bodyFont: PlatformFont,
        headerFont: PlatformFont,
        columnGap: CGFloat,
        maxColumnWidth: CGFloat,
        measure: Measurer
    ) -> TableLayout? {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return nil }

        // Column widths: the widest cell, capped so a runaway column can't eat
        // the page. Header measures in the (bold) header font, body in body.
        var widths = [CGFloat](repeating: 0, count: columnCount)
        func widen(_ cells: [TableCell], font: PlatformFont) {
            for (i, cell) in cells.enumerated() where i < columnCount {
                widths[i] = min(max(widths[i], measure(cell.inlines.plainText, font)), maxColumnWidth)
            }
        }
        widen(header, font: headerFont)
        for row in rows { widen(row, font: bodyFont) }

        // Numeric columns right-align with tabular numerals (element spec):
        // an explicit `---:`/`:-:` marker wins, otherwise a column whose body
        // cells are all numeric right-aligns automatically.
        var alignments = [NSTextAlignment](repeating: .left, count: columnCount)
        var isNumeric = [Bool](repeating: false, count: columnCount)
        for column in 0..<columnCount {
            let cells = rows.compactMap { column < $0.count ? $0[column].inlines.plainText : nil }
            isNumeric[column] = !cells.isEmpty && cells.allSatisfy(Self.isNumeric)
            switch column < explicit.count ? explicit[column] : TableAlignment.none {
            case .left: alignments[column] = .left
            case .center: alignments[column] = .center
            case .right: alignments[column] = .right
            case .none: alignments[column] = isNumeric[column] ? .right : .left
            }
        }

        // Tab stops at column starts (column 0 needs none); alignment tabs
        // place centered/right content within each column's span.
        var tabStops: [NSTextTab] = []
        var columnStart: CGFloat = 0
        var totalWidth: CGFloat = 0
        var columnStarts = [CGFloat](repeating: 0, count: columnCount)
        for column in 0..<columnCount {
            columnStarts[column] = columnStart
            if column > 0 {
                switch alignments[column] {
                case .center:
                    tabStops.append(NSTextTab(textAlignment: .center, location: columnStart + widths[column] / 2))
                case .right:
                    tabStops.append(NSTextTab(textAlignment: .right, location: columnStart + widths[column]))
                default:
                    tabStops.append(NSTextTab(textAlignment: .left, location: columnStart))
                }
            }
            totalWidth = columnStart + widths[column]
            columnStart += widths[column] + columnGap
        }

        // The widest column is the one most likely to wrap; anchor wrapped
        // lines to its left edge. A left-aligned column wraps under its own
        // start; for center/right alignment the tab stop isn't the left edge,
        // so only left-aligned wide columns get the anchor (0 otherwise).
        let widestColumn = widths.indices.max(by: { widths[$0] < widths[$1] }) ?? 0
        let wrapIndent = alignments[widestColumn] == .left ? columnStarts[widestColumn] : 0

        return TableLayout(
            columnCount: columnCount,
            widths: widths,
            alignments: alignments,
            isNumeric: isNumeric,
            tabStops: tabStops,
            totalWidth: totalWidth,
            wrapIndent: wrapIndent
        )
    }

    /// A cell reads as numeric if it is non-empty, holds at least one digit,
    /// and contains only digits and the usual numeric punctuation/symbols.
    static func isNumeric(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0.isNumber || "+-.,%$€£ ".contains($0) }
            && trimmed.contains(where: \.isNumber)
    }
}
#endif
