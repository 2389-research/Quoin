#if canImport(AppKit)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformAppearance = NSAppearance
#elseif canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
/// UIKit has no NSAppearance analogue; exports use trait collections there.
public typealias PlatformAppearance = NSObject
#endif

#if canImport(AppKit) || canImport(UIKit)
import Foundation
import MermaidRender
import VinculumRender

/// The Graphite design system from `docs/design/handoff.md`. Colors, type
/// ramp, spacing, and radii are the handoff's exact values — change them
/// there first, here second. Dark mode inverts ink/canvas, keeps the code
/// surface, and desaturates highlights ~15%.
public struct Theme: Sendable {

    /// Captured at creation: whether the app is in dark appearance. Keys
    /// the engine render caches so cached math/diagram images match the
    /// surrounding canvas. (A mid-session appearance switch re-creates
    /// themes via the SwiftUI environment on the next render.)
    public let prefersDark: Bool

    public init() {
        #if canImport(AppKit)
        if Thread.isMainThread, let app = NSApp {
            prefersDark = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        } else {
            prefersDark = false
        }
        #else
        prefersDark = false
        #endif
    }

    /// Pinned appearance, for exports that force light or dark output
    /// regardless of the app's current appearance.
    public init(prefersDark: Bool) {
        self.prefersDark = prefersDark
    }

    // MARK: - Spacing & metrics (handoff: 4 · 8 · 12 · 16 · 24 · 32)

    public var bodySize: CGFloat = 14
    public var bodyLineHeightMultiple: CGFloat = 1.7
    public var paragraphSpacing: CGFloat = 12
    public var contentInset: CGFloat = 48   // gutters ≥48pt
    public var maxContentWidth: CGFloat = 680

    public enum Radius {
        public static let inlineCode: CGFloat = 4
        public static let control: CGFloat = 6
        public static let block: CGFloat = 8
        public static let panel: CGFloat = 10
    }

    // MARK: - Type ramp (editor face: SF Pro Rounded; mono: SF Mono)

    /// H1 26/700 · H2 20/700 · H3 16/600 · H4–H6 14/600.
    public func headingFont(level: Int) -> PlatformFont {
        switch level {
        case 1: return roundedFont(size: 26, weight: .bold)
        case 2: return roundedFont(size: 20, weight: .bold)
        case 3: return roundedFont(size: 16, weight: .semibold)
        default: return roundedFont(size: 14, weight: .semibold)
        }
    }

    public func headingLineHeightMultiple(level: Int) -> CGFloat {
        switch level {
        case 1: return 1.25
        case 2: return 1.3
        default: return 1.35
        }
    }

    /// Space above/below headings: H1 32/12 · H2 28/10 · H3 22/8.
    public func headingSpacing(level: Int) -> (above: CGFloat, below: CGFloat) {
        switch level {
        case 1: return (32, 12)
        case 2: return (28, 10)
        case 3: return (22, 8)
        default: return (16, 8)
        }
    }

    public func bodyFont() -> PlatformFont {
        roundedFont(size: bodySize, weight: .regular)
    }

    public func boldBodyFont() -> PlatformFont {
        roundedFont(size: bodySize, weight: .bold)
    }

    /// Inline code: 12.5pt mono. Code blocks: 12pt mono, line height 1.6.
    public func inlineCodeFont() -> PlatformFont {
        .monospacedSystemFont(ofSize: 12.5, weight: .regular)
    }

    public func codeBlockFont() -> PlatformFont {
        .monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    /// UI captions/status: 10.5pt mono per spec.
    public func captionFont() -> PlatformFont {
        .monospacedSystemFont(ofSize: 10.5, weight: .regular)
    }

    private func roundedFont(size: CGFloat, weight: PlatformFont.Weight) -> PlatformFont {
        let base = PlatformFont.systemFont(ofSize: size, weight: weight)
        #if canImport(AppKit)
        let descriptor = base.fontDescriptor.withDesign(.rounded)
        return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? base
        #else
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
        #endif
    }

    // MARK: - Colors (dynamic: light per handoff, dark = inverted ink/canvas)
    //
    // Every color is a STABLE static instance, not minted per access: a
    // dynamic NSColor gets a fresh identity each time it's created, which
    // (a) allocated thousands of colors per render and (b) made two renders
    // of the same content attribute-UNEQUAL — breaking the storage-patch
    // equivalence contract (a patched projection must be indistinguishable
    // from a full re-render). Dynamic colors resolve per-appearance at draw
    // time, so one shared instance is correct in both light and dark.

    /// `ink` #1D1D1F — headings, bold text.
    public var ink: PlatformColor { Palette.ink }

    /// `ink.body` #333333 — body text.
    public var textColor: PlatformColor { Palette.textColor }

    /// `ink.secondary` — 55% ink.
    public var secondaryTextColor: PlatformColor { Palette.secondaryText }

    /// `ink.tertiary` — 35–40% ink.
    public var tertiaryTextColor: PlatformColor { Palette.tertiaryText }

    /// `canvas` — the editor page.
    public var canvas: PlatformColor { Palette.canvas }

    /// `surface.sidebar` #F5F5F7.
    public var sidebarSurface: PlatformColor { Palette.sidebarSurface }

    /// `fill.codeInline` #F2F2F4.
    public var inlineCodeFill: PlatformColor { Palette.inlineCodeFill }

    /// `surface.code` #1E2430 — the SAME in both appearances (handoff rule).
    public var codeSurface: PlatformColor { Theme.codeColor(\.surface) }

    /// Code block body text.
    public var codeText: PlatformColor { Theme.codeColor(\.text) }

    /// Resolves one palette role through the Settings choice: a pinned
    /// palette is static; "match" composes the light/dark pair
    /// appearance-dynamically. Every color is created ONCE (static
    /// storage): a fresh dynamic-provider NSColor per access would break
    /// attribute equality between the patch paths and the full render —
    /// ProjectorEquivalenceTests caught exactly that.
    static func codeColor(_ role: KeyPath<ResolvedCodeColors, PlatformColor>) -> PlatformColor {
        let choice = UserDefaults.standard.string(forKey: "QuoinCodeTheme") ?? "match"
        return (ResolvedCodeColors.byID[choice] ?? ResolvedCodeColors.match)[keyPath: role]
    }

    struct ResolvedCodeColors {
        let surface: PlatformColor
        let text: PlatformColor
        let keyword: PlatformColor
        let function: PlatformColor
        let type: PlatformColor
        let comment: PlatformColor
        let string: PlatformColor
        let number: PlatformColor

        init(_ palette: CodePalette) {
            surface = rgbStatic(palette.surface)
            text = rgbStatic(palette.text)
            keyword = rgbStatic(palette.keyword)
            function = rgbStatic(palette.function)
            type = rgbStatic(palette.type)
            comment = rgbStatic(palette.comment)
            string = rgbStatic(palette.string)
            number = rgbStatic(palette.number)
        }

        init(light: CodePalette, dark: CodePalette) {
            surface = themeDynamic(light: rgbStatic(light.surface), dark: rgbStatic(dark.surface))
            text = themeDynamic(light: rgbStatic(light.text), dark: rgbStatic(dark.text))
            keyword = themeDynamic(light: rgbStatic(light.keyword), dark: rgbStatic(dark.keyword))
            function = themeDynamic(light: rgbStatic(light.function), dark: rgbStatic(dark.function))
            type = themeDynamic(light: rgbStatic(light.type), dark: rgbStatic(dark.type))
            comment = themeDynamic(light: rgbStatic(light.comment), dark: rgbStatic(dark.comment))
            string = themeDynamic(light: rgbStatic(light.string), dark: rgbStatic(dark.string))
            number = themeDynamic(light: rgbStatic(light.number), dark: rgbStatic(dark.number))
        }

        static let byID: [String: ResolvedCodeColors] = Dictionary(
            uniqueKeysWithValues: CodePalette.registry.map { ($0.id, ResolvedCodeColors($0)) })
        static let match = ResolvedCodeColors(
            light: CodePalette.registry.first { $0.id == CodePalette.matchLightID }!,
            dark: CodePalette.registry.first { $0.id == CodePalette.matchDarkID }!)
    }

    private enum Palette {
        static let ink = themeDynamic(light: rgbStatic(0x1D1D1F), dark: rgbStatic(0xF2F2F4))
        static let textColor = themeDynamic(light: rgbStatic(0x333333), dark: rgbStatic(0xD9D9DE))
        static let secondaryText = themeDynamic(
            light: rgbStatic(0x1D1D1F, alpha: 0.55), dark: rgbStatic(0xF2F2F4, alpha: 0.55))
        static let tertiaryText = themeDynamic(
            light: rgbStatic(0x1D1D1F, alpha: 0.38), dark: rgbStatic(0xF2F2F4, alpha: 0.38))
        static let canvas = themeDynamic(light: rgbStatic(0xFFFFFF), dark: rgbStatic(0x1B1B1D))
        static let sidebarSurface = themeDynamic(light: rgbStatic(0xF5F5F7), dark: rgbStatic(0x232326))
        static let inlineCodeFill = themeDynamic(light: rgbStatic(0xF2F2F4), dark: rgbStatic(0x2E2E32))

        static let hairline = themeDynamic(
            light: rgbStatic(0x000000, alpha: 0.12), dark: rgbStatic(0xFFFFFF, alpha: 0.12))
        static let quoteRule = themeDynamic(
            light: rgbStatic(0x000000, alpha: 0.15), dark: rgbStatic(0xFFFFFF, alpha: 0.15))
        static let suggestionInsertFill = themeDynamic(light: rgbStatic(0xDCF2DC), dark: rgbStatic(0x2E4A33))
        static let suggestionInsertInk = themeDynamic(light: rgbStatic(0x2E7D42), dark: rgbStatic(0x7FC98F))
        static let suggestionDeleteFill = themeDynamic(light: rgbStatic(0xF9DCDC), dark: rgbStatic(0x53302F))
        static let suggestionCommentFill = themeDynamic(light: rgbStatic(0xFDF3D0), dark: rgbStatic(0x4A4432))
        static let suggestionCommentInk = themeDynamic(light: rgbStatic(0x8A6D1D), dark: rgbStatic(0xD9BE6C))
        static let suggestionHighlightFill = themeDynamic(light: rgbStatic(0xFCE9B8), dark: rgbStatic(0x5D5330))
        static let tableRule = themeDynamic(
            light: rgbStatic(0x000000, alpha: 0.07), dark: rgbStatic(0xFFFFFF, alpha: 0.09))
    }

    /// Syntax token colors (one theme, both appearances).
    public enum CodeToken {
        public static var keyword: PlatformColor { Theme.codeColor(\.keyword) }
        public static var function: PlatformColor { Theme.codeColor(\.function) }
        public static var type: PlatformColor { Theme.codeColor(\.type) }
        public static var comment: PlatformColor { Theme.codeColor(\.comment) }
        public static var string: PlatformColor { Theme.codeColor(\.string) }
        public static var number: PlatformColor { Theme.codeColor(\.number) }
    }

    /// System accent (`controlAccentColor`); #2A6FDB is the marketing value.
    public var accent: PlatformColor {
        #if canImport(AppKit)
        .controlAccentColor
        #else
        .tintColor
        #endif
    }

    public var linkColor: PlatformColor { accent }

    /// Hairlines: 12% ink (HR), 8% (outline rules), 7% (borders).
    public var hairline: PlatformColor { Palette.hairline }

    /// Blockquote rule: 15% ink, 3pt wide.
    public var quoteRule: PlatformColor { Palette.quoteRule }

    /// Table body-row hairline: 7% ink (header rule uses `quoteRule`, 15%).
    public var tableRule: PlatformColor { Palette.tableRule }

    // MARK: Suggestions (CriticMarkup marks — docs/design/suggestions.md)

    /// Insertion underlay: quiet green, readable ink on both appearances.
    public var suggestionInsertFill: PlatformColor { Palette.suggestionInsertFill }
    public var suggestionInsertInk: PlatformColor { Palette.suggestionInsertInk }
    /// Deletion underlay: quiet red behind struck 55%-ink text.
    public var suggestionDeleteFill: PlatformColor { Palette.suggestionDeleteFill }
    /// Comment chip (annotation, not document text).
    public var suggestionCommentFill: PlatformColor { Palette.suggestionCommentFill }
    public var suggestionCommentInk: PlatformColor { Palette.suggestionCommentInk }
    /// Critic highlight `{==…==}`: amber, distinct from the `==…==` palette.
    public var suggestionHighlightFill: PlatformColor { Palette.suggestionHighlightFill }

    /// Highlight palette (≥4.5:1 with ink.body); dark variants desaturated ~15%.
    public enum Highlight: String, CaseIterable, Sendable {
        case lime, pink, yellow, blue, orange

        private static let limeColor = themeDynamic(light: rgbStatic(0xD9F59B), dark: rgbStatic(0x5A6B33))
        private static let pinkColor = themeDynamic(light: rgbStatic(0xF7D9F0), dark: rgbStatic(0x6B4462))
        private static let yellowColor = themeDynamic(light: rgbStatic(0xFDEEAA), dark: rgbStatic(0x6E6337))
        private static let blueColor = themeDynamic(light: rgbStatic(0xCFE6FB), dark: rgbStatic(0x3A5570))
        private static let orangeColor = themeDynamic(light: rgbStatic(0xFEDBC6), dark: rgbStatic(0x6E4A34))

        public var color: PlatformColor {
            switch self {
            case .lime: return Self.limeColor
            case .pink: return Self.pinkColor
            case .yellow: return Self.yellowColor
            case .blue: return Self.blueColor
            case .orange: return Self.orangeColor
            }
        }
    }

    public var searchHighlight: PlatformColor {
        #if canImport(AppKit)
        .findHighlightColor
        #else
        .systemYellow
        #endif
    }

    // MARK: - Helpers

    private func dynamic(light: PlatformColor, dark: PlatformColor) -> PlatformColor {
        themeDynamic(light: light, dark: dark)
    }

    private func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> PlatformColor {
        rgbStatic(hex, alpha: alpha)
    }
}

// Free functions so nested enums can share them.

func rgbStatic(_ hex: UInt32, alpha: CGFloat = 1) -> PlatformColor {
    PlatformColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func themeDynamic(light: PlatformColor, dark: PlatformColor) -> PlatformColor {
    #if canImport(AppKit)
    return NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
    #else
    return UIColor { traits in
        traits.userInterfaceStyle == .dark ? dark : light
    }
    #endif
}

// MARK: - MermaidKit adapter

extension Theme {
    /// Quoin's design system projected onto MermaidKit's theme seam — the
    /// same seven values the diagram renderers used before extraction.
    public var diagramTheme: DiagramTheme {
        DiagramTheme(
            ink: ink,
            secondaryTextColor: secondaryTextColor,
            tertiaryTextColor: tertiaryTextColor,
            canvas: canvas,
            accent: accent,
            hairline: hairline,
            prefersDark: prefersDark
        )
    }

    /// Quoin's design system projected onto the math render seam — the two
    /// values (ink + appearance) the typesetter needs. Mirrors
    /// `diagramTheme`; when the math engine is extracted into its own
    /// package this is the adapter the host keeps.
    public var mathTheme: MathTheme {
        MathTheme(ink: ink, prefersDark: prefersDark)
    }
}
#endif


// MARK: - Code palettes (#63)

/// One curated syntax palette: six token roles + canvas. Values are the
/// canonical hues from each MIT-licensed theme (One Dark/Light — Atom;
/// Dracula; GitHub — Primer; Solarized — Ethan Schoonover; Nord; Tokyo
/// Night; Catppuccin), plus Quoin's house Graphite.
public struct CodePalette: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isDark: Bool
    public let surface: UInt32
    public let text: UInt32
    public let keyword: UInt32
    public let function: UInt32
    public let type: UInt32
    public let comment: UInt32
    public let string: UInt32
    public let number: UInt32

    /// The pair "Match appearance" composes.
    public static let matchLightID = "github-light"
    public static let matchDarkID = "graphite"

    public static let registry: [CodePalette] = [
        CodePalette(id: "graphite", name: "Graphite", isDark: true,
                    surface: 0x1E2430, text: 0xD6DCE6, keyword: 0xC792EA,
                    function: 0x82AAFF, type: 0xFFCB6B, comment: 0x697794,
                    string: 0xC3E88D, number: 0xF78C6C),
        CodePalette(id: "one-dark", name: "One Dark", isDark: true,
                    surface: 0x282C34, text: 0xABB2BF, keyword: 0xC678DD,
                    function: 0x61AFEF, type: 0xE5C07B, comment: 0x5C6370,
                    string: 0x98C379, number: 0xD19A66),
        CodePalette(id: "dracula", name: "Dracula", isDark: true,
                    surface: 0x282A36, text: 0xF8F8F2, keyword: 0xFF79C6,
                    function: 0x50FA7B, type: 0x8BE9FD, comment: 0x6272A4,
                    string: 0xF1FA8C, number: 0xBD93F9),
        CodePalette(id: "github-dark", name: "GitHub Dark", isDark: true,
                    surface: 0x0D1117, text: 0xE6EDF3, keyword: 0xFF7B72,
                    function: 0xD2A8FF, type: 0xFFA657, comment: 0x8B949E,
                    string: 0xA5D6FF, number: 0x79C0FF),
        CodePalette(id: "solarized-dark", name: "Solarized Dark", isDark: true,
                    surface: 0x002B36, text: 0x839496, keyword: 0x859900,
                    function: 0x268BD2, type: 0xB58900, comment: 0x586E75,
                    string: 0x2AA198, number: 0xD33682),
        CodePalette(id: "nord", name: "Nord", isDark: true,
                    surface: 0x2E3440, text: 0xD8DEE9, keyword: 0x81A1C1,
                    function: 0x88C0D0, type: 0x8FBCBB, comment: 0x616E88,
                    string: 0xA3BE8C, number: 0xB48EAD),
        CodePalette(id: "tokyo-night", name: "Tokyo Night", isDark: true,
                    surface: 0x1A1B26, text: 0xA9B1D6, keyword: 0xBB9AF7,
                    function: 0x7AA2F7, type: 0x2AC3DE, comment: 0x565F89,
                    string: 0x9ECE6A, number: 0xFF9E64),
        CodePalette(id: "catppuccin-mocha", name: "Catppuccin Mocha", isDark: true,
                    surface: 0x1E1E2E, text: 0xCDD6F4, keyword: 0xCBA6F7,
                    function: 0x89B4FA, type: 0xF9E2AF, comment: 0x6C7086,
                    string: 0xA6E3A1, number: 0xFAB387),
        CodePalette(id: "one-light", name: "One Light", isDark: false,
                    surface: 0xFAFAFA, text: 0x383A42, keyword: 0xA626A4,
                    function: 0x4078F2, type: 0xC18401, comment: 0xA0A1A7,
                    string: 0x50A14F, number: 0x986801),
        CodePalette(id: "github-light", name: "GitHub Light", isDark: false,
                    surface: 0xF6F8FA, text: 0x24292F, keyword: 0xCF222E,
                    function: 0x8250DF, type: 0x953800, comment: 0x6E7781,
                    string: 0x0A3069, number: 0x0550AE),
        CodePalette(id: "solarized-light", name: "Solarized Light", isDark: false,
                    surface: 0xFDF6E3, text: 0x657B83, keyword: 0x859900,
                    function: 0x268BD2, type: 0xB58900, comment: 0x93A1A1,
                    string: 0x2AA198, number: 0xD33682),
        CodePalette(id: "catppuccin-latte", name: "Catppuccin Latte", isDark: false,
                    surface: 0xEFF1F5, text: 0x4C4F69, keyword: 0x8839EF,
                    function: 0x1E66F5, type: 0xDF8E1D, comment: 0x9CA0B0,
                    string: 0x40A02B, number: 0xFE640B),
    ]
}
