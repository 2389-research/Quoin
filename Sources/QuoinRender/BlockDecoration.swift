#if canImport(AppKit) || canImport(UIKit)
import Foundation

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Block-level chrome the element spec calls for that per-glyph attributes
/// can't express: the code block's full-width canvas, the callout's tinted
/// rounded box, the blockquote's 3pt rule, the diagram frame, and table
/// rules. The renderer tags each block's character range with one of these;
/// the reader view draws them behind the text at fragment-layout time, so
/// the shapes always track the laid-out geometry.
///
/// Colors are resolved from the theme at render time but stay dynamic
/// (appearance-aware) — they resolve to light/dark values when drawn.
public final class BlockDecoration: NSObject {

    public enum Kind {
        /// Rounded canvas behind a code block (`#1E2430` in both appearances).
        case codeCanvas(fill: PlatformColor)
        /// Tinted rounded box + border in the callout's semantic color.
        case callout(color: PlatformColor)
        /// 3pt vertical rule along the blockquote's left edge.
        case quoteRule(color: PlatformColor)
        /// Hairline rounded frame around a rendered diagram.
        case diagramFrame(color: PlatformColor)
        /// Compact chip fill behind a single-line run (front matter).
        case chip(fill: PlatformColor)
        /// Table rules: heavier line under the first (header) row, hairline
        /// under body rows. `width` is the table's content width.
        case tableRules(width: CGFloat, header: PlatformColor, body: PlatformColor)
        /// 1.5pt accent frame around the OPEN (editing) block's revealed
        /// source, with a drawn `✓ done` chip at its top-right — the
        /// editing mode announced in shape at the locus of attention
        /// (embed-editing brief: mode indicators are never hover-gated).
        /// Drawn, not a text run: the revealed source must stay 1:1 with
        /// the file, so no affordance characters may enter the range.
        case editingFrame(accent: PlatformColor)
    }

    public let kind: Kind
    /// Leading inset for full-width chrome (code canvas, callout box,
    /// diagram frame): nested cards — code inside a blockquote, a diagram
    /// inside a list item — must start at their container's text column,
    /// not at x = 0. Nesting passes accumulate it level by level.
    public let leadingInset: CGFloat

    public init(kind: Kind, leadingInset: CGFloat = 0) {
        self.kind = kind
        self.leadingInset = leadingInset
    }

    /// The same decoration pushed `delta` further in (nested one level
    /// deeper).
    public func inset(by delta: CGFloat) -> BlockDecoration {
        BlockDecoration(kind: kind, leadingInset: leadingInset + delta)
    }

    /// Value equality: decorations are values carried as attributes, and
    /// attribute comparison (splice attribute-sync, storage equality in
    /// tests) must treat two identically-specified decorations as equal —
    /// NSObject's default pointer identity made every fresh render look
    /// like an attribute change.
    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? BlockDecoration else { return false }
        guard leadingInset == other.leadingInset else { return false }
        switch (kind, other.kind) {
        case (.codeCanvas(let a), .codeCanvas(let b)):
            return a.isEqual(b)
        case (.callout(let a), .callout(let b)):
            return a.isEqual(b)
        case (.quoteRule(let a), .quoteRule(let b)):
            return a.isEqual(b)
        case (.diagramFrame(let a), .diagramFrame(let b)):
            return a.isEqual(b)
        case (.chip(let a), .chip(let b)):
            return a.isEqual(b)
        case (.tableRules(let w1, let h1, let b1), .tableRules(let w2, let h2, let b2)):
            return w1 == w2 && h1.isEqual(h2) && b1.isEqual(b2)
        case (.editingFrame(let a), .editingFrame(let b)):
            return a.isEqual(b)
        default:
            return false
        }
    }

    public override var hash: Int {
        switch kind {
        case .codeCanvas: return 1
        case .callout: return 2
        case .quoteRule: return 3
        case .diagramFrame: return 4
        case .chip: return 5
        case .tableRules: return 6
        case .editingFrame: return 7
        }
    }
}
#endif
