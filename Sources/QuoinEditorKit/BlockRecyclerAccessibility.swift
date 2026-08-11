#if canImport(AppKit)
import AppKit
import QuoinCore
import QuoinRender

/// Phase 1, Task 7: the accessibility seam for the block recycler — the
/// cell-level AX (role/label/heading level) and the table-level VoiceOver
/// structure rotors.
///
/// This is the recycler's analogue of what `QuoinTextView` does over one big
/// attributed string: the monolithic reader scans the storage for
/// `QuoinAttribute.headingLevel` / `blockAccessibilityLabel` runs and vends the
/// Headings + Landmarks rotors through `StructureRotor.result`. Here the
/// document is projected one block per table row, so the SAME vocabulary is
/// derived per-cell (from the cell's configured fragment attributes) and
/// per-table (over `document.blocks`), reusing `BlockAccessibility` and
/// `StructureRotor` verbatim — no new spoken labels are invented.
///
/// Read-only (Phase 1): the cell exposes role + label; the rotors let VoiceOver
/// list/step the document's structure. Editing actions (the "Edit" AX action)
/// are Phase 2 — see the `// Phase 2:` markers in `BlockRenderCell` and
/// `BlockStructureRotorDelegate`.
enum BlockRecyclerAccessibility {

    /// The AX a single block cell exposes, read from its rendered fragment.
    struct CellAccessibility: Equatable {
        var role: NSAccessibility.Role
        var label: String?
        /// 1–6 for a heading cell, nil otherwise — the level VoiceOver reads
        /// alongside the heading role.
        var headingLevel: Int?
    }

    /// VoiceOver's heading role. macOS has no `NSAccessibilityRole.heading`
    /// constant; `AXHeading` is the string role WebKit reports and VoiceOver
    /// announces as "heading level N", so heading cells adopt it.
    static let headingRole = NSAccessibility.Role(rawValue: "AXHeading")

    /// Derive a cell's AX from the fragment it was configured with. The
    /// renderer baked `QuoinAttribute.headingLevel` onto heading ranges and
    /// `QuoinAttribute.blockAccessibilityLabel` onto other structural ranges
    /// (`AttributedRenderer.render(block:)`), so the cell need not re-derive
    /// from `BlockKind` — it reads back exactly what the projection carries,
    /// guaranteeing the cell and the rendered text never disagree.
    static func cellAccessibility(for fragment: NSAttributedString) -> CellAccessibility {
        let full = NSRange(location: 0, length: fragment.length)

        var headingLevel: Int?
        fragment.enumerateAttribute(QuoinAttribute.headingLevel, in: full) { value, _, stop in
            if let level = (value as? NSNumber)?.intValue {
                headingLevel = level
                stop.pointee = true
            }
        }
        if let headingLevel {
            // A title-less heading renders as a lone zero-width space purely so
            // it has a navigable position (AttributedRenderer.renderHeading) —
            // strip it so the label reads "Heading level N", matching the rotor.
            let title = fragment.string
                .replacingOccurrences(of: "\u{200B}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CellAccessibility(
                role: headingRole,
                label: BlockAccessibility.headingAnnouncement(level: headingLevel, title: title),
                headingLevel: headingLevel)
        }

        var announcement: String?
        fragment.enumerateAttribute(QuoinAttribute.blockAccessibilityLabel, in: full) { value, _, stop in
            if let label = value as? String {
                announcement = label
                stop.pointee = true
            }
        }
        // A structural block ("Table, 3 columns…") announces its landmark
        // label; prose carries no announcement and reads as its own text, so
        // the cell is a plain group with no extra spoken label.
        return CellAccessibility(role: .group, label: announcement, headingLevel: nil)
    }

    /// The table-level rotor items over `blocks`, split into the Headings rotor
    /// (heading blocks) and the Blocks rotor (the other structural blocks),
    /// each in document order. Locations are BLOCK INDICES — the recycler's
    /// per-row analogue of the monolith's rendered-range offsets — so
    /// `StructureRotor.result` steps row to row. Prose blocks carry no
    /// `BlockAccessibility.announcement` and are intentionally omitted (they
    /// read as their own text), exactly as the monolith's Landmarks rotor.
    static func rotorItems(
        for blocks: [Block]
    ) -> (headings: [StructureRotor.Item], blocks: [StructureRotor.Item]) {
        var headings: [StructureRotor.Item] = []
        var landmarks: [StructureRotor.Item] = []
        for (index, block) in blocks.enumerated() {
            guard let label = BlockAccessibility.announcement(for: block.kind) else { continue }
            let item = StructureRotor.Item(location: index, length: 1, label: label)
            if BlockAccessibility.headingLevel(for: block.kind) != nil {
                headings.append(item)
            } else {
                landmarks.append(item)
            }
        }
        return (headings, landmarks)
    }
}

/// Feeds a recycler structure rotor (Headings or Blocks). Holds the current
/// items (refreshed by `BlockRecyclerView.accessibilityCustomRotors`) and
/// answers next/previous/filter queries through the pure `StructureRotor.result`
/// navigator — the SAME adapter shape `QuoinTextView` uses, so the off-by-one
/// stepping logic has one implementation.
///
/// `NSAccessibilityCustomRotor` holds its `itemSearchDelegate` weakly, so the
/// recycler view must own its delegates.
final class BlockStructureRotorDelegate: NSObject, NSAccessibilityCustomRotorItemSearchDelegate {
    private weak var owner: NSView?
    var items: [StructureRotor.Item] = []

    init(owner: NSView) {
        self.owner = owner
    }

    func rotor(
        _ rotor: NSAccessibilityCustomRotor,
        resultFor parameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let owner else { return nil }
        let direction: StructureRotor.Direction
        switch parameters.searchDirection {
        case .next: direction = .next
        case .previous: direction = .previous
        @unknown default: return nil
        }
        guard let hit = StructureRotor.result(
            items: items,
            currentLocation: parameters.currentItem?.targetRange.location,
            direction: direction,
            filter: parameters.filterString
        ) else { return nil }

        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: owner)
        // The item's location is a BLOCK INDEX; carried as the target range so a
        // subsequent step anchors off it. Phase 2 (Task 8) refines targeting to
        // the block's actual row cell and scrolls it into view.
        result.targetRange = NSRange(location: hit.location, length: hit.length)
        result.customLabel = hit.label
        return result
    }
}
#endif
