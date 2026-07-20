import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuoinCore
import QuoinRender

/// The export sheet (⇧⌘E) per handoff §3: format grid (3-up cards, PDF
/// default-selected), accent primary button, native save panel.
struct ExportSheet: View {
    let documentName: String
    let document: QuoinDocument
    /// The open document's directory, for resolving relative image paths in
    /// PDF/RTF/HTML export (issue #3). Nil for unsaved documents.
    var documentDirectory: URL?
    @Binding var isPresented: Bool

    @State private var selected: ExportFormat = .pdf
    @State private var exportError: String?
    @State private var includeFootnotes = true
    /// Standalone HTML export is private-by-default: raw HTML is scrubbed of
    /// scripts, event handlers, and remote trackers (issue #4). Users who need
    /// byte-exact raw HTML can turn this off.
    @State private var sanitizeHTML = true
    @State private var appearance: ExportAppearance = .auto
    @State private var escapeMonitor: Any?

    /// PDF/print theme override (handoff: options row theme picker).
    enum ExportAppearance: String, CaseIterable, Identifiable {
        case auto = "Match System"
        case light = "Light"
        case dark = "Dark"
        var id: String { rawValue }

        var nsAppearance: NSAppearance? {
            switch self {
            case .auto: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    enum ExportFormat: String, CaseIterable, Identifiable {
        case pdf = "PDF"
        case html = "HTML"
        case markdown = "MD"
        case rtf = "RTF"
        case txt = "TXT"

        var id: String { rawValue }

        var caption: String {
            switch self {
            case .pdf: return "Paginated, print-ready"
            case .html: return "Self-contained"
            case .markdown: return "Normalized source"
            case .rtf: return "For word processors"
            case .txt: return "Plain text"
            }
        }

        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .html: return "html"
            case .markdown: return "md"
            case .rtf: return "rtf"
            case .txt: return "txt"
            }
        }

        var contentType: UTType {
            switch self {
            case .pdf: return .pdf
            case .html: return .html
            case .markdown: return UTType(filenameExtension: "md") ?? .plainText
            case .rtf: return .rtf
            case .txt: return .plainText
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export “\(documentName)”")
                .quoinScaledFont(size: 15, weight: .semibold)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(ExportFormat.allCases) { format in
                    formatCard(format)
                }
            }

            // Options row per handoff §3.
            HStack(spacing: 16) {
                Toggle("Include footnotes", isOn: $includeFootnotes)
                    .toggleStyle(.checkbox)
                    .quoinScaledFont(size: 12)
                Toggle("Sanitize HTML", isOn: $sanitizeHTML)
                    .toggleStyle(.checkbox)
                    .quoinScaledFont(size: 12)
                    .disabled(selected != .html)
                    .help("Remove scripts, event handlers, and remote trackers from raw HTML so the exported file is private and self-contained. Turn off for byte-exact raw HTML.")
                Spacer()
                Picker("Theme", selection: $appearance) {
                    ForEach(ExportAppearance.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .quoinScaledFont(size: 12)
                .fixedSize()
                .disabled(selected != .pdf)
                .help("PDF color theme")
            }

            if let exportError {
                Text(exportError)
                    .quoinScaledFont(size: 11)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { runExport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 470)
        // Escape reliably cancels the sheet even when focus sits in the
        // format grid (cancelAction alone doesn't fire from every responder).
        .onAppear(perform: installEscapeMonitor)
        .onDisappear(perform: removeEscapeMonitor)
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                isPresented = false
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    private func formatCard(_ format: ExportFormat) -> some View {
        let isSelected = format == selected
        return VStack(spacing: 5) {
            Text(format.rawValue)
                .quoinScaledFont(size: 14, weight: .semibold)
            Text(format.caption)
                .quoinScaledFont(size: 10)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.05) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { selected = format }
    }

    // MARK: - Export

    private func runExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [selected.contentType]
        panel.nameFieldStringValue = "\(documentName).\(selected.fileExtension)"
        // The Escape monitor would eat the save panel's own cancel key —
        // suspend it while the panel runs (it reinstalls afterwards
        // unless the sheet is going away).
        removeEscapeMonitor()
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url {
                write(to: url)
            }
            if isPresented { installEscapeMonitor() }
        }
        // Window-modal, not app-modal: other windows stay usable.
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private func write(to url: URL) {
        // Include-footnotes off: export a copy without the gathered
        // footnote definitions (inline refs remain, like a print excerpt).
        let exported = includeFootnotes ? document : QuoinDocument(
            source: document.source,
            blocks: document.blocks,
            outline: document.outline,
            footnotes: [],
            stats: document.stats,
            sourceHash: document.sourceHash
        )

        do {
            let data: Data
            switch selected {
            case .pdf:
                data = try DocumentExporters.pdf(
                    from: exported,
                    title: documentName,
                    baseURL: documentDirectory,
                    forcedAppearance: appearance.nsAppearance
                )
            case .html:
                data = Data(HTMLExporter.export(exported, title: documentName, baseURL: documentDirectory, sanitizeRawHTML: sanitizeHTML).utf8)
            case .markdown:
                data = Data(MarkdownExporter.export(exported).utf8)
            case .rtf:
                data = try DocumentExporters.rtf(from: exported, baseURL: documentDirectory)
            case .txt:
                data = Data(PlainTextExporter.export(exported).utf8)
            }
            try data.write(to: url)
            isPresented = false
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }
}
