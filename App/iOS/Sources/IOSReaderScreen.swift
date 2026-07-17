import SwiftUI
import UniformTypeIdentifiers
import QuoinCore
import QuoinRender

/// One open document on iOS/iPadOS: full native rendering (math, diagrams,
/// everything), outline and statistics as sheets, exports through the
/// share sheet. Reading-first; interactive checkboxes write back.
struct IOSReaderScreen: View {
    let fileURL: URL?
    let initialText: String

    @StateObject private var model = IOSReaderModel()

    @State private var isOutlineVisible = false
    @State private var isStatsVisible = false
    @State private var scrollTarget: BlockID?
    @State private var shareItem: ShareItem?

    struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        MarkdownReaderViewIOS(
            rendered: model.rendered,
            scrollTarget: scrollTarget,
            onTaskToggle: { offset in model.toggleTask(markerOffset: offset) },
            anchorResolver: { slug in model.blockID(forSlug: slug) }
        )
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(fileURL?.deletingPathExtension().lastPathComponent ?? "Document")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    isOutlineVisible = true
                } label: {
                    Image(systemName: "list.bullet.indent")
                }
                Menu {
                    Button("Statistics") { isStatsVisible = true }
                    Divider()
                    Button("Export Markdown") { share(.markdown) }
                    Button("Export HTML") { share(.html) }
                    Button("Export Plain Text") { share(.text) }
                    Button("Export PDF") { share(.pdf) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isOutlineVisible) {
            OutlineSheet(outline: model.outline) { blockID in
                scrollTarget = blockID
                isOutlineVisible = false
            }
        }
        .sheet(isPresented: $isStatsVisible) {
            StatsSheet(stats: model.stats)
        }
        .sheet(item: $shareItem) { item in
            ActivityView(url: item.url)
        }
        .onAppear { model.start(fileURL: fileURL, initialText: initialText) }
        .onDisappear { model.stop() }
    }

    // MARK: - Exports

    enum ExportKind {
        case markdown, html, text, pdf
    }

    private func share(_ kind: ExportKind) {
        let name = fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
        let baseURL = fileURL?.deletingLastPathComponent()
        let document = model.document
        do {
            let data: Data
            let ext: String
            switch kind {
            case .markdown:
                data = Data(MarkdownExporter.export(document).utf8)
                ext = "md"
            case .html:
                // Standalone export is private-by-default: raw HTML is scrubbed
                // of scripts/handlers/remote trackers (issue #4).
                data = Data(HTMLExporter.export(document, title: name, baseURL: baseURL, sanitizeRawHTML: true).utf8)
                ext = "html"
            case .text:
                data = Data(PlainTextExporter.export(document).utf8)
                ext = "txt"
            case .pdf:
                data = try DocumentExporters.pdf(from: document, title: name, baseURL: baseURL)
                ext = "pdf"
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(name)
                .appendingPathExtension(ext)
            try data.write(to: url)
            shareItem = ShareItem(url: url)
        } catch {
            // Export failures are non-fatal; the menu simply closes.
        }
    }
}

// MARK: - Model

@MainActor
final class IOSReaderModel: ObservableObject {
    @Published private(set) var rendered: RenderedDocument = .empty
    @Published private(set) var outline: [HeadingInfo] = []
    @Published private(set) var stats = DocumentStats()

    private(set) var document: QuoinDocument = .empty
    private var session: DocumentSession?
    private var snapshotTask: Task<Void, Never>?
    private var renderer = AttributedRenderer()
    private var slugToBlock: [String: BlockID] = [:]

    func start(fileURL: URL?, initialText: String) {
        guard session == nil else { return }
        renderer = AttributedRenderer(theme: Theme(), baseURL: fileURL?.deletingLastPathComponent())

        let session: DocumentSession
        if let fileURL, let opened = try? DocumentSession.open(fileURL: fileURL) {
            session = opened
        } else {
            session = DocumentSession(source: initialText, fileURL: fileURL)
        }
        self.session = session

        snapshotTask = Task { [weak self] in
            await session.startWatching()
            let snapshots = await session.snapshots()
            for await document in snapshots {
                await self?.ingest(document)
            }
        }
    }

    func stop() {
        snapshotTask?.cancel()
        snapshotTask = nil
        let session = session
        Task {
            try? await session?.saveNow()
            await session?.stopWatching()
        }
    }

    private func ingest(_ document: QuoinDocument) {
        guard document.sourceHash != self.document.sourceHash else { return }
        self.document = document
        rendered = renderer.render(document)
        outline = document.outline
        stats = document.stats
        slugToBlock = Dictionary(
            document.outline.map { ($0.slug, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func toggleTask(markerOffset: Int) {
        guard let session else { return }
        Task {
            try? await session.toggleTask(markerRange: ByteRange(offset: markerOffset, length: 3))
        }
    }

    func blockID(forSlug slug: String) -> BlockID? {
        slugToBlock[slug]
    }
}

// MARK: - Sheets

struct OutlineSheet: View {
    let outline: [HeadingInfo]
    let onSelect: (BlockID) -> Void

    var body: some View {
        NavigationStack {
            List(outline) { heading in
                Button {
                    onSelect(heading.id)
                } label: {
                    Text(heading.title)
                        .quoinScaledFont(size: 15, weight: heading.level == 1 ? .semibold : .regular)
                        .padding(.leading, CGFloat(max(0, heading.level - 1)) * 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Outline")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if outline.isEmpty {
                    Text("No headings").foregroundStyle(.secondary)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct StatsSheet: View {
    let stats: DocumentStats

    var body: some View {
        NavigationStack {
            List {
                row("Words", stats.wordCount.formatted())
                row("Characters", stats.characterCount.formatted())
                row("Reading time", "\(stats.readingTimeMinutes) min")
                row("Headings", "\(stats.headingCount)")
                row("Links", "\(stats.linkCount)")
                row("Images", "\(stats.imageCount)")
                row("Code blocks", "\(stats.codeBlockCount)")
                row("Tables", "\(stats.tableCount)")
                if stats.taskTotal > 0 {
                    row("Tasks", "\(stats.taskDone) of \(stats.taskTotal) done")
                }
            }
            .navigationTitle("Statistics")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// UIActivityViewController bridge for the share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
