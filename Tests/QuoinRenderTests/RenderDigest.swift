#if canImport(AppKit) || canImport(UIKit)
import Foundation
@testable import QuoinRender
import QuoinCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// MARK: - Digest model

/// A deterministic, machine-independent projection of a `RenderedDocument`.
///
/// The renderer's real output is an `NSAttributedString` full of things that
/// vary machine to machine — font glyph widths, rasterised math/diagram
/// images, the user's chosen accent color. Golden-snapshotting those bytes
/// would be flaky. This digest captures only what the renderer *decides*:
/// the text, the run structure, and for each run the attributes that come
/// from theme constants and the source model — never anything measured from
/// a font or resolved from a machine setting.
///
/// What is deliberately excluded (font/machine dependent):
///  - font glyph widths → table tab-stop *locations*, math box pixels;
///  - rasterised NSImage bytes (attachments record presence only);
///  - the raw RGB of the system accent color (mapped to the `"accent"`
///    token by identity instead — see `ColorTokenizer`).
struct DocDigest: Codable, Equatable {
    /// Maximal attribute runs, left to right — the complete deterministic
    /// projection. Concatenating `runs[].t` reproduces the rendered string.
    ///
    /// `BlockID` descriptions are deliberately absent: their content-hash is
    /// computed with Swift's per-process-seeded `Hasher`, so a block's id is
    /// random from run to run (it only needs to be stable *within* a session,
    /// for the fragment cache and scroll anchoring). The run structure already
    /// reflects any change in block splitting — a merged or split block shifts
    /// the inter-block separator runs — and `testBlockRangesAreTaggedAndOrdered`
    /// covers id tagging within a single process.
    var runs: [RunDigest]
}

/// One maximal attribute run. Every field is either a theme constant, a
/// source-model value, or a semantic color token — all reproducible on any
/// machine that shares this OS's system colors.
struct RunDigest: Codable, Equatable {
    /// The run's substring.
    var t: String
    /// Sorted `QuoinAttribute` descriptors present on the run.
    var q: [String]
    /// Font: `"<pt>/<weight>[flags]"`, e.g. `"14.00/0.00"`, `"12.00/0.00m"`.
    var f: String?
    /// Paragraph scalars (no font-measured values). See `paragraphDigest`.
    var p: String?
    var fg: String?
    var bg: String?
    var underline: String?
    var strike: String?
    /// Block-level decoration label, e.g. `"callout(systemBlue)"`.
    var deco: String?
    /// `.link` destination (absolute string).
    var link: String?
}

// MARK: - Color tokenizer

/// Resolves attributed-string colors to stable *tokens* so a golden survives
/// a move between machines.
///
/// Almost every color the renderer emits is a fixed theme hex (`#1D1D1F`,
/// the six code-token colors, the highlight palette) — those serialize to
/// their sRGB hex and are identical everywhere. Two families are *not* fixed:
///
///  - the system **accent** color (`controlAccentColor`) is a user setting;
///  - the five **system semantic** colors used by callouts can shift between
///    OS versions.
///
/// Both are resolved once, under a pinned appearance, and matched by identity
/// so a run wearing them serializes to a name (`"accent"`, `"systemBlue"`)
/// rather than to bytes that differ across machines. System colors are
/// checked first; the accent — which can *equal* a system color when the
/// user picks the default blue — is disambiguated structurally by the digest
/// builder (linked and superscript runs are accent by construction), so this
/// residual overlap never reaches `token(for:)`.
struct ColorTokenizer {
    let prefersDark: Bool
    /// `(name, sRGB byte triple)` — system colors first, accent last.
    private let known: [(name: String, rgb: (Int, Int, Int))]

    init(theme: Theme) {
        self.prefersDark = theme.prefersDark
        var table: [(String, (Int, Int, Int))] = []
        func add(_ name: String, _ color: PlatformColor) {
            let c = Self.rgba(color, prefersDark: theme.prefersDark)
            table.append((name, (c.r, c.g, c.b)))
        }
        // Order matters: callout semantics resolve to their names even when
        // the user's accent coincides with one of them.
        add("systemBlue", .systemBlue)
        add("systemGreen", .systemGreen)
        add("systemPurple", .systemPurple)
        add("systemOrange", .systemOrange)
        add("systemRed", .systemRed)
        add("accent", theme.accent)
        self.known = table
    }

    /// A stable token for `color`: a known-color name, else an sRGB hex
    /// string (`#RRGGBB`, or `#RRGGBBAA` when partly transparent).
    func token(for color: PlatformColor) -> String {
        let c = Self.rgba(color, prefersDark: prefersDark)
        if let hit = known.first(where: {
            abs($0.rgb.0 - c.r) <= 1 && abs($0.rgb.1 - c.g) <= 1 && abs($0.rgb.2 - c.b) <= 1
        }) {
            return c.a >= 254 ? hit.name : "\(hit.name)@\(Int((Double(c.a) / 255 * 100).rounded()))"
        }
        let hex = String(format: "#%02X%02X%02X", c.r, c.g, c.b)
        return c.a >= 254 ? hex : hex + String(format: "%02X", c.a)
    }

    /// Resolves a possibly-dynamic color to sRGB bytes under the pinned
    /// appearance, so light/dark catalog colors and the accent resolve the
    /// same way every run.
    static func rgba(_ color: PlatformColor, prefersDark: Bool) -> (r: Int, g: Int, b: Int, a: Int) {
        var out = (r: 0, g: 0, b: 0, a: 0)
        func read(_ c: PlatformColor) {
            #if canImport(AppKit)
            guard let s = c.usingColorSpace(.sRGB) else { return }
            out = (Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()),
                   Int((s.blueComponent * 255).rounded()), Int((s.alphaComponent * 255).rounded()))
            #else
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            out = (Int((r * 255).rounded()), Int((g * 255).rounded()),
                   Int((b * 255).rounded()), Int((a * 255).rounded()))
            #endif
        }
        #if canImport(AppKit)
        if let appearance = NSAppearance(named: prefersDark ? .darkAqua : .aqua) {
            appearance.performAsCurrentDrawingAppearance { read(color) }
        } else {
            read(color)
        }
        #else
        read(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: prefersDark ? .dark : .light)))
        #endif
        return out
    }
}

// MARK: - Builder

enum RenderDigester {

    /// Every custom key the renderer stamps, paired with how to describe its
    /// value deterministically. Big/duplicative values (a copy button's whole
    /// code payload) record presence only; small model values keep their value.
    static func digest(_ document: RenderedDocument, theme: Theme) -> DocDigest {
        let tokenizer = ColorTokenizer(theme: theme)
        let attributed = document.attributed
        let full = NSRange(location: 0, length: attributed.length)

        var runs: [RunDigest] = []
        attributed.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            runs.append(runDigest(attrs, text: attributed.attributedSubstring(from: range).string,
                                  tokenizer: tokenizer))
        }

        return DocDigest(runs: runs)
    }

    private static func runDigest(
        _ attrs: [NSAttributedString.Key: Any],
        text: String,
        tokenizer: ColorTokenizer
    ) -> RunDigest {
        var run = RunDigest(t: text, q: [])

        // QuoinAttribute keys, described deterministically. blockID identity
        // is captured once per block in `DocDigest.blocks` (and run→block
        // tagging is asserted separately), so it is not repeated per run.
        // math/diagram/copy sources record presence only — the actual source
        // string is a block's identity, not per-run structure, and repeating
        // it on every highlighted run inside a source card bloated the golden
        // ~10x. Correct-source tagging is covered by MathAndDiagramTests.
        var q: [String] = []
        if let off = attrs[QuoinAttribute.taskMarkerOffset] as? NSNumber { q.append("task=\(off.intValue)") }
        if attrs[QuoinAttribute.mathSource] != nil { q.append("math") }
        if attrs[QuoinAttribute.diagramSource] != nil { q.append("diagram") }
        if attrs[QuoinAttribute.editableSource] != nil { q.append("editable") }
        if attrs[QuoinAttribute.copySource] != nil { q.append("copy") }
        if attrs[QuoinAttribute.embedBlock] != nil { q.append("embed") }
        if let s = attrs[QuoinAttribute.embedSourceStart] as? NSNumber { q.append("embedStart=\(s.intValue)") }
        if attrs[QuoinAttribute.pendingContent] != nil { q.append("pending") }
        if let id = attrs[QuoinAttribute.footnoteID] as? String { q.append("fnref=\(id)") }
        if let id = attrs[QuoinAttribute.footnoteDefinitionID] as? String { q.append("fndef=\(id)") }
        if let level = attrs[QuoinAttribute.headingLevel] as? NSNumber { q.append("hlevel=\(level.intValue)") }
        if attrs[.attachment] is NSTextAttachment { q.append("attachment") }
        run.q = q.sorted()

        if let font = attrs[.font] as? PlatformFont { run.f = fontDigest(font) }
        if let para = attrs[.paragraphStyle] as? NSParagraphStyle { run.p = paragraphDigest(para) }

        let hasLink = attrs[.link] != nil
        let isLinkLike = hasLink || attrs[.underlineStyle] != nil || attrs[.underlineColor] != nil
        let superscript = (attrs[.baselineOffset] as? NSNumber).map { $0.doubleValue > 0 } ?? false
        let footnoteMarker = text.range(of: #"^\d+\. $"#, options: .regularExpression) != nil
        if let color = attrs[.foregroundColor] as? PlatformColor {
            // Link-styled runs, footnote-ref superscripts, and rendered
            // footnote ordinals are accent by construction. Labeling them
            // structurally keeps the token stable when the machine accent is
            // the default blue, which otherwise equals `systemBlue`.
            run.fg = (isLinkLike || superscript || footnoteMarker) ? "accent" : tokenizer.token(for: color)
        }
        if let color = attrs[.backgroundColor] as? PlatformColor { run.bg = tokenizer.token(for: color) }
        if let color = attrs[.underlineColor] as? PlatformColor {
            run.underline = isLinkLike ? "accent@\(alphaPct(color, tokenizer))" : tokenizer.token(for: color)
        } else if attrs[.underlineStyle] != nil {
            run.underline = "on"
        }
        if attrs[.strikethroughStyle] != nil {
            run.strike = (attrs[.strikethroughColor] as? PlatformColor).map { tokenizer.token(for: $0) } ?? "on"
        }
        if let deco = attrs[QuoinAttribute.blockDecoration] as? BlockDecoration {
            run.deco = decorationDigest(deco, tokenizer: tokenizer)
        }
        if let url = attrs[.link] as? URL { run.link = url.absoluteString }
        return run
    }

    /// `"<pt>/<weight>[b][i][m]"` — point size and normalized weight capture
    /// the whole type ramp (semibold H4 vs regular body at the same size),
    /// symbolic flags capture bold/italic/monospace. No glyph widths.
    private static func fontDigest(_ font: PlatformFont) -> String {
        let sym = font.fontDescriptor.symbolicTraits
        #if canImport(AppKit)
        let bold = sym.contains(.bold), italic = sym.contains(.italic), mono = sym.contains(.monoSpace)
        #else
        let bold = sym.contains(.traitBold), italic = sym.contains(.traitItalic), mono = sym.contains(.traitMonoSpace)
        #endif
        var flags = ""
        if bold { flags += "b" }
        if italic { flags += "i" }
        if mono { flags += "m" }
        return String(format: "%.2f/%.2f", font.pointSize, weight(of: font)) + flags
    }

    private static func weight(of font: PlatformFont) -> CGFloat {
        #if canImport(AppKit)
        let attrKey = NSFontDescriptor.AttributeName.traits
        let weightKey = NSFontDescriptor.TraitKey.weight
        #else
        let attrKey = UIFontDescriptor.AttributeName.traits
        let weightKey = UIFontDescriptor.TraitKey.weight
        #endif
        guard let traits = font.fontDescriptor.object(forKey: attrKey) as? [AnyHashable: Any],
              let w = traits[weightKey] as? CGFloat else { return 0 }
        return (w * 100).rounded() / 100
    }

    /// Paragraph scalars that are all theme constants — line height, spacing,
    /// indents, alignment, tab-stop *count*. Tab-stop locations are omitted
    /// because table columns measure them from font metrics.
    private static func paragraphDigest(_ p: NSParagraphStyle) -> String {
        func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
        return "lh\(f(p.lineHeightMultiple)) ps\(f(p.paragraphSpacing)) psb\(f(p.paragraphSpacingBefore)) "
            + "fh\(f(p.firstLineHeadIndent)) hi\(f(p.headIndent)) ti\(f(p.tailIndent)) "
            + "al\(p.alignment.rawValue) tabs\(p.tabStops.count)"
    }

    private static func decorationDigest(_ deco: BlockDecoration, tokenizer: ColorTokenizer) -> String {
        func t(_ c: PlatformColor) -> String { tokenizer.token(for: c) }
        // Nested cards carry a leading inset; geometry changes must show
        // in the digest (ledger #1/#2).
        if deco.leadingInset != 0 {
            return baseDigest(deco, tokenizer: tokenizer)
                + String(format: "+inset%.0f", deco.leadingInset)
        }
        return baseDigest(deco, tokenizer: tokenizer)
    }

    private static func baseDigest(_ deco: BlockDecoration, tokenizer: ColorTokenizer) -> String {
        func t(_ c: PlatformColor) -> String { tokenizer.token(for: c) }
        switch deco.kind {
        case .codeCanvas(let fill): return "codeCanvas(\(t(fill)))"
        case .callout(let color): return "callout(\(t(color)))"
        case .quoteRule(let color): return "quoteRule(\(t(color)))"
        case .diagramFrame(let color): return "diagramFrame(\(t(color)))"
        case .chip(let fill): return "chip(\(t(fill)))"
        // `width` is font-measured (table content width) → excluded.
        case .tableRules(_, let header, let body): return "tableRules(h:\(t(header)),b:\(t(body)))"
        case .editingFrame(let accent): return "editingFrame(\(t(accent)))"
        }
    }

    private static func alphaPct(_ color: PlatformColor, _ tokenizer: ColorTokenizer) -> Int {
        Int((Double(ColorTokenizer.rgba(color, prefersDark: tokenizer.prefersDark).a) / 255 * 100).rounded())
    }
}
#endif
