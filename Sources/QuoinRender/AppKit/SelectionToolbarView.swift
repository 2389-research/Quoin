#if canImport(AppKit)
import AppKit

/// The Google-Docs-style floating toolbar that appears anchored to a text
/// selection (#45): format the selection or start a review comment on it,
/// without reaching for a right-click. Contents mirror the format pill
/// (`ReaderScreen.formatPill`) — Bold / Italic / Strikethrough / Inline code /
/// Highlight / Link — plus a Comment button (the review loop is the
/// differentiator, so it's front-and-center). Owned + positioned by
/// `ReaderCoordinator`; a plain `NSView` subview of the text view, like
/// `PreviewPanelView`.
final class SelectionToolbarView: NSView {

    /// Fires the format command for the current selection.
    var onFormat: ((FormatCommand) -> Void)?
    /// Starts a comment on the current selection.
    var onComment: (() -> Void)?

    private let stack = NSStackView()
    static let height: CGFloat = 34
    private static let buttonSize = NSSize(width: 30, height: 26)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 4
        layer?.shadowOffset = NSSize(width: 0, height: -1)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Format buttons (symbol, command, tooltip) — same set + glyphs as the
        // format pill so the two read as one vocabulary.
        let formats: [(String, FormatCommand, String)] = [
            ("bold", .bold, "Bold (⌘B)"),
            ("italic", .italic, "Italic (⌘I)"),
            ("strikethrough", .strikethrough, "Strikethrough"),
            ("chevron.left.forwardslash.chevron.right", .code, "Inline code"),
            ("highlighter", .highlight, "Highlight (⇧⌘H)"),
            ("link", .link, "Link (⌘K)"),
        ]
        for (symbol, command, help) in formats {
            stack.addArrangedSubview(iconButton(symbol: symbol, help: help) { [weak self] in
                self?.onFormat?(command)
            })
        }

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 16).isActive = true
        stack.addArrangedSubview(divider)

        let comment = NSButton(title: " Comment", target: nil, action: nil)
        comment.bezelStyle = .recessed
        comment.isBordered = false
        comment.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: "Comment")
        comment.imagePosition = .imageLeading
        comment.font = .systemFont(ofSize: 12, weight: .medium)
        comment.contentTintColor = .controlAccentColor
        comment.toolTip = "Comment on the selection"
        comment.setButtonType(.momentaryChange)
        comment.target = self
        comment.action = #selector(commentPressed)
        stack.addArrangedSubview(comment)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func iconButton(symbol: String, help: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .recessed
        button.setButtonType(.momentaryChange)
        button.toolTip = help
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Self.buttonSize.width).isActive = true
        button.heightAnchor.constraint(equalToConstant: Self.buttonSize.height).isActive = true
        return button
    }

    @objc private func commentPressed() { onComment?() }

    /// Intrinsic width: buttons + divider + the Comment label. Left to Auto
    /// Layout via the stack; callers read `fittingSize`.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    // MARK: - Geometry (pure, testable)

    /// The toolbar's frame in the text view's (flipped, top-left-origin)
    /// coordinates: centered horizontally over `selectionRect`, clamped inside
    /// `bounds`, positioned just ABOVE the selection — flipped to just BELOW when
    /// there isn't room above (near the top of the document).
    static func toolbarFrame(
        selectionRect: CGRect, barSize: CGSize, inBounds bounds: CGRect, gap: CGFloat = 8
    ) -> CGRect {
        let inset: CGFloat = 4
        var x = selectionRect.midX - barSize.width / 2
        x = max(bounds.minX + inset, min(x, bounds.maxX - barSize.width - inset))
        // Flipped coords: smaller y is higher on screen. Prefer above.
        var y = selectionRect.minY - barSize.height - gap
        if y < bounds.minY + inset {
            y = selectionRect.maxY + gap   // no room above → below the selection
        }
        return CGRect(x: x, y: y, width: barSize.width, height: barSize.height)
    }
}

/// A borderless `NSButton` that fires a closure — the toolbar's format buttons.
private final class ClosureButton: NSButton {
    private let handler: () -> Void
    init(action: @escaping () -> Void) {
        self.handler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(fire)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
#endif
