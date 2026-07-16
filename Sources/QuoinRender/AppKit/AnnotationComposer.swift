#if canImport(AppKit)
import AppKit

/// The small compose popover behind Add Comment… / Suggest Replacement…
/// (suggestions §3.6, S3a): one field, Return commits, Esc cancels (the
/// popover is transient). Pure AppKit — it anchors to the selection rect
/// the text view reports, which SwiftUI cannot reach.
final class AnnotationComposerController: NSViewController, NSTextFieldDelegate {

    private let prompt: String
    private let initialText: String
    private let commitTitle: String
    private let onCommit: (String) -> Void
    /// Set by the presenter so Return/button can close the popover.
    weak var popover: NSPopover?

    private let field = NSTextField()

    init(prompt: String, initialText: String, commitTitle: String,
         onCommit: @escaping (String) -> Void) {
        self.prompt = prompt
        self.initialText = initialText
        self.commitTitle = commitTitle
        self.onCommit = onCommit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 64))

        field.frame = NSRect(x: 12, y: 32, width: 276, height: 22)
        field.placeholderString = prompt
        field.stringValue = initialText
        field.font = .systemFont(ofSize: 12)
        field.delegate = self
        field.target = self
        field.action = #selector(commit)
        container.addSubview(field)

        let commitButton = NSButton(title: commitTitle, target: self, action: #selector(commit))
        commitButton.bezelStyle = .rounded
        commitButton.controlSize = .small
        commitButton.keyEquivalent = "\r"
        commitButton.sizeToFit()
        commitButton.setFrameOrigin(NSPoint(
            x: 288 - commitButton.frame.width, y: 6))
        container.addSubview(commitButton)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.sizeToFit()
        cancelButton.setFrameOrigin(NSPoint(
            x: 288 - commitButton.frame.width - cancelButton.frame.width - 6, y: 6))
        container.addSubview(cancelButton)

        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
        // Replacement pre-fills with the selection: select-all so typing
        // replaces it in one stroke.
        field.currentEditor()?.selectAll(nil)
    }

    @objc private func commit() {
        let text = field.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return
        }
        popover?.performClose(nil)
        onCommit(text)
    }

    @objc private func cancel() {
        popover?.performClose(nil)
    }
}
#endif
