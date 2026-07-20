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
    private var asyncRerenderTask: Task<Void, Never>?
    private var backgroundRenderTask: Task<Void, Never>?
    /// Bumped on every re-render trigger; a background projection adopts its
    /// result only if the generation still matches, so a stale async render
    /// (superseded by a newer one, or by teardown) drops instead of clobbering.
    private var renderGeneration = 0

    func start(fileURL: URL?, initialText: String) {
        guard session == nil else { return }
        renderer = AttributedRenderer(
            theme: Theme(),
            baseURL: fileURL?.deletingLastPathComponent(),
            // Mirror macOS (ReaderModel.makeRenderer): async local-image decode
            // shows a placeholder on first render, then fires this off-main once
            // the image is ready so the document re-renders to pick it up (#2).
            onContentReady: { [weak self] in
                Task { @MainActor in self?.scheduleAsyncContentRerender() }
            }
        )

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
        asyncRerenderTask?.cancel()
        asyncRerenderTask = nil
        backgroundRenderTask?.cancel()
        backgroundRenderTask = nil
        // Make teardown authoritative over any in-flight image decode (#2): the
        // shared `AsyncImageStore` decode can't be cancelled, so its
        // `onContentReady` may still fire after this. Clearing `session` (and
        // bumping the generation) means the late callback's rerender guard
        // fails and it no-ops — no wasted projection on a torn-down model.
        let session = session
        self.session = nil
        renderGeneration += 1
        Task {
            try? await session?.saveNow()
            await session?.stopWatching()
        }
    }

    private func ingest(_ document: QuoinDocument) {
        guard document.sourceHash != self.document.sourceHash else { return }
        // Invalidate any in-flight async re-render: this publish supersedes it,
        // so a background projection of the previous document must not adopt
        // itself over the newer one (its `generation == renderGeneration` guard
        // now fails). Mirrors the counter discipline every macOS publish path
        // upholds. Without this, an async image finishing mid-edit could revert
        // a just-toggled checkbox to a stale projection.
        renderGeneration += 1
        backgroundRenderTask?.cancel()
        backgroundRenderTask = nil
        self.document = document
        rendered = renderer.render(document)
        outline = document.outline
        stats = document.stats
        slugToBlock = Dictionary(
            document.outline.map { ($0.slug, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Coalesces re-renders when async images finish decoding — a document
    /// with 30 photos triggers one re-render, not 30 (mirrors macOS
    /// `ReaderModel.scheduleAsyncContentRerender`). No render loop: once
    /// `AsyncImageStore` has the decoded image cached, the re-render's
    /// `image(at:…)` is a cache hit that does NOT re-arm `onReady`, so the
    /// callback fires only while content is genuinely still pending.
    func scheduleAsyncContentRerender() {
        guard session != nil else { return }
        asyncRerenderTask?.cancel()
        asyncRerenderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.rerenderCurrentDocument()
        }
    }

    /// Re-projects the CURRENT document without a source change — used when an
    /// async image decode completes so the placeholder is replaced in place.
    /// Only the rendered projection is republished; the outline/stats/slug map
    /// are functions of the source and haven't changed. Reusing the same
    /// document keeps the offsets identical, and `MarkdownReaderViewIOS` pins
    /// the top fragment across the swap, so scroll position stays put.
    ///
    /// The heavy projection runs OFF the main actor (mirrors macOS
    /// `ReaderModel.rerenderAsync`, issue #33): for a photo-heavy document this
    /// fires 120ms after the decode and a full main-thread render would hitch
    /// scrolling on exactly the documents this feature targets. The result is
    /// adopted under `renderGeneration`, so a projection superseded by a newer
    /// trigger — or by `stop()` clearing the session — is dropped.
    private func rerenderCurrentDocument() {
        guard session != nil else { return }
        renderGeneration += 1
        let generation = renderGeneration
        let renderer = self.renderer
        let document = self.document
        backgroundRenderTask?.cancel()
        backgroundRenderTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let projection = await Self.project(renderer: renderer, document: document)
            guard let self, !Task.isCancelled,
                  generation == self.renderGeneration, self.session != nil else { return }
            self.rendered = projection
        }
    }

    /// The pure, off-main portion of the async re-render. `nonisolated`, so
    /// awaiting it from the main-actor task runs the block walk on a background
    /// executor; the non-Sendable result crosses back as a single `sending`
    /// value (built here, adopted once on the main actor, never aliased).
    private nonisolated static func project(
        renderer: AttributedRenderer,
        document: QuoinDocument
    ) async -> sending RenderedDocument {
        renderer.render(document)
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
