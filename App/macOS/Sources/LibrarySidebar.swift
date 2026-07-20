import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuoinCore
import QuoinRender

/// The library sidebar: classic tree per the handoff (icons, disclosure
/// chevrons, accent-filled selection), documents open on click, assets
/// grayed, footer with the document count.
struct LibrarySidebar: View {
    @Bindable var library: LibraryModel
    @Binding var selection: URL?
    @Binding var isSearchVisible: Bool
    let onOpen: (URL) -> Void

    @FocusState private var searchFocused: Bool
    /// Keyboard highlight into `librarySearchResults` (#11). Owned here so the
    /// search field (which receives the keypresses) and the results list
    /// (which renders the selection) agree on one index.
    @State private var searchHighlighted = 0

    var body: some View {
        VStack(spacing: 0) {
            if isSearchVisible {
                searchField
            }
            if isSearchVisible && !library.librarySearchQuery.isEmpty {
                searchResults
            } else {
                tree
            }

            Divider()
            HStack {
                Text(library.documentCount == 1 ? "1 document" : "\(library.documentCount) documents")
                Spacer()
            }
            .quoinScaledFont(size: 10.5)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    if let url = library.createDocument() { onOpen(url) }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New document (⌘N)")
                .accessibilityLabel("New Document")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .onChange(of: isSearchVisible) { _, visible in
            if visible { searchFocused = true } else { library.librarySearchQuery = "" }
        }
    }

    private var tree: some View {
        List(selection: $selection) {
            if let children = library.root?.children {
                ForEach(children) { node in
                    LibraryRow(node: node, onOpen: onOpen, library: library)
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            // Empty-area context menu: root-level file management (UI #9).
            Button("New Document") {
                if let url = library.createDocument() { onOpen(url) }
            }
            Button("New Folder") { library.createFolder() }
        }
        .overlay {
            // Null state: a fresh library shouldn't read as broken (UI #17).
            if library.root?.children?.isEmpty ?? true {
                VStack(spacing: 6) {
                    Text("No documents yet")
                        .quoinScaledFont(size: 11, weight: .medium)
                        .foregroundStyle(.secondary)
                    Text("Press ⌘N to create one")
                        .quoinScaledFont(size: 10.5)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        // Dropping onto empty sidebar space moves (internal) or imports
        // (external markdown) into the library root. The delegate reflects
        // move / copy / forbidden in the drag badge and highlights the zone.
        .onDrop(of: [.fileURL], delegate: LibraryDropDelegate(
            target: library.rootURL, library: library, highlight: $rootDropHighlight))
        .overlay {
            if rootDropHighlight != .none {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        rootDropHighlight == .rejected
                            ? Color.red.opacity(0.6)
                            : Color.accentColor.opacity(0.6),
                        lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    @State private var rootDropHighlight: DropHighlight = .none

    // MARK: - Library-wide search (⇧⌘F, persistent per handoff)

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .quoinScaledFont(size: 11)
            TextField("Search library", text: $library.librarySearchQuery)
                .textFieldStyle(.plain)
                .quoinScaledFont(size: 12)
                .focused($searchFocused)
                .onExitCommand { isSearchVisible = false }
                .onSubmit { openHighlightedSearchResult() }
                // ↑/↓/Home/End move a VISIBLE highlight through the results,
                // Return opens it, Escape dismisses — the sidebar search list
                // is now keyboard-operable like Quick Open (#11). Shared
                // movement math (ListSelection) keeps the two identical.
                .onKeyPress(.downArrow) {
                    guard !library.librarySearchResults.isEmpty else { return .ignored }
                    searchHighlighted = ListSelection.next(searchHighlighted, count: library.librarySearchResults.count)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard !library.librarySearchResults.isEmpty else { return .ignored }
                    searchHighlighted = ListSelection.previous(searchHighlighted, count: library.librarySearchResults.count)
                    return .handled
                }
                .onKeyPress(.home) {
                    guard !library.librarySearchResults.isEmpty else { return .ignored }
                    searchHighlighted = ListSelection.first(count: library.librarySearchResults.count)
                    return .handled
                }
                .onKeyPress(.end) {
                    guard !library.librarySearchResults.isEmpty else { return .ignored }
                    searchHighlighted = ListSelection.last(count: library.librarySearchResults.count)
                    return .handled
                }
                .onChange(of: library.librarySearchQuery) { _, _ in
                    searchHighlighted = 0
                    library.runLibrarySearch()
                }
                // Results arrive async; fold a stale highlight back into range.
                .onChange(of: library.librarySearchResults) { _, results in
                    searchHighlighted = ListSelection.clamped(searchHighlighted, count: results.count)
                }
            if !library.librarySearchQuery.isEmpty {
                Button {
                    library.librarySearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .quoinScaledFont(size: 10)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var searchResults: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(library.librarySearchResults.enumerated()), id: \.element.id) { index, result in
                        let isHighlighted = index == searchHighlighted
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title)
                                .quoinScaledFont(size: 12.5, weight: .medium)
                                .foregroundStyle(isHighlighted ? Color.white : Color.primary)
                            if !result.snippet.isEmpty {
                                Text(result.snippet)
                                    .quoinScaledFont(size: 10.5)
                                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isHighlighted ? Color.accentColor : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                        .id(index)
                        .onTapGesture {
                            searchHighlighted = index
                            onOpen(result.url)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
                    }
                    if library.librarySearchResults.isEmpty {
                        Text("No matches")
                            .quoinScaledFont(size: 11)
                            .foregroundStyle(.tertiary)
                            .padding(10)
                    }
                }
                .padding(.horizontal, 4)
            }
            .onChange(of: searchHighlighted) { _, index in
                proxy.scrollTo(index)
            }
        }
    }

    /// Return in the search field opens the highlighted match (#11).
    private func openHighlightedSearchResult() {
        guard library.librarySearchResults.indices.contains(searchHighlighted) else { return }
        onOpen(library.librarySearchResults[searchHighlighted].url)
    }
}

/// A drag provider for a library item (#31, drag-out-to-Finder).
///
/// It vends TWO representations so one drag serves both directions:
///   • `public.file-url` (from the `NSURL` object) — what the intra-sidebar
///     move drop reads back in `performLibraryDrop`, so library moves are
///     unchanged; and
///   • for a leaf file, a *file representation* of the item's real content
///     type, so dragging OUT lands as a genuine file copy in Finder or an
///     attachment in another app, not a bare URL reference.
///
/// The file representation is registered `coordinated: true`: the item
/// provider reads the existing file with file coordination and MUST NOT move
/// or delete the original — dragging a document out never removes it from the
/// library. Folders keep the URL-only provider (Finder still copies the tree).
func documentDragProvider(for url: URL, isDirectory: Bool) -> NSItemProvider {
    let provider = NSItemProvider(object: url as NSURL)
    provider.suggestedName = url.lastPathComponent
    guard !isDirectory else { return provider }
    let typeIdentifier = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier)
        ?? UTType(filenameExtension: url.pathExtension)?.identifier
        ?? UTType.data.identifier
    provider.registerFileRepresentation(
        forTypeIdentifier: typeIdentifier,
        fileOptions: [],
        visibility: .all
    ) { completion in
        // The file already exists on disk. `coordinated: true` tells the item
        // provider to read it via file coordination and leave the original in
        // place — never move or delete it.
        completion(url, true, nil)
        return nil
    }
    return provider
}

/// The visible drop-target state for a folder row or the root zone.
enum DropHighlight: Equatable { case none, accepted, rejected }

/// Thin `DropDelegate` for a library sidebar drop target (a folder row or the
/// root zone). It defers every "what does this drop do?" question to the
/// `DropValidation` seam and translates the answer into the drag badge
/// (move / copy / forbidden) plus the row highlight. The actual file operation
/// is performed — and RE-VALIDATED against the real dropped URL — in
/// `LibraryModel.performValidatedDrop`, so the cosmetic badge can never move
/// the wrong file.
///
/// The badge classifies the item ACTUALLY under the cursor by reading the live
/// drag pasteboard (`NSPasteboard(name: .drag)`) synchronously. The drop-type
/// registration (`.onDrop(of: [.fileURL], …)`) guarantees these callbacks only
/// fire while file URLs are on that pasteboard, so the read is reliable for BOTH
/// internal drags and external Finder drags — and it can never go stale the way
/// a value stashed at `.onDrag` time does (a cancelled or dragged-out internal
/// drag would leave that stashed value pointing at the wrong item and silently
/// misclassify — or outright block, via a `.forbidden` proposal — the next
/// external import).
struct LibraryDropDelegate: DropDelegate {
    /// Destination folder; nil means no library is configured (reject).
    let target: URL?
    let library: LibraryModel
    @Binding var highlight: DropHighlight

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        highlight = badge(for: proposedOperation())
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let operation = proposedOperation()
        highlight = badge(for: operation)
        return DropProposal(operation: operation)
    }

    func dropExited(info: DropInfo) {
        highlight = .none
    }

    func performDrop(info: DropInfo) -> Bool {
        highlight = .none
        guard let target else { return false }
        return performLibraryDrop(info.itemProviders(for: [.fileURL]), into: target, library: library)
    }

    /// The dragged file URL for the live drag, read synchronously from the drag
    /// pasteboard. Returns nil only if the pasteboard somehow holds no file URL
    /// (should not happen: the `.fileURL` drop registration is what invoked us).
    private func liveDraggedURL() -> URL? {
        let objects = NSPasteboard(name: .drag).readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return objects?.first
    }

    /// The operation for the live badge, decided from the real dragged URL. An
    /// unreadable pasteboard falls back to an optimistic `.copy` (the drop then
    /// re-validates and beeps on a genuine reject) rather than blocking a
    /// possibly-legitimate import.
    private func proposedOperation() -> DropOperation {
        guard let target, let root = library.rootURL else { return .forbidden }
        guard let dragged = liveDraggedURL() else { return .copy }
        switch DropValidation.libraryDrop(dragged: dragged, onto: target, libraryRoot: root) {
        case .move: return .move
        case .copy: return .copy
        case .reject: return .forbidden
        }
    }

    private func badge(for operation: DropOperation) -> DropHighlight {
        operation == .forbidden ? .rejected : .accepted
    }
}

/// Loads file URLs off the drag pasteboard and performs the validated drop.
/// The operation (move / copy / reject) is re-decided from the real URL inside
/// `performValidatedDrop`, so this stays a thin loader.
@discardableResult
func performLibraryDrop(_ providers: [NSItemProvider], into folder: URL, library: LibraryModel) -> Bool {
    var handled = false
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        handled = true
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url else { return }
            Task { @MainActor in
                library.performValidatedDrop(url: url, into: folder)
            }
        }
    }
    return handled
}

private struct LibraryRow: View {
    let node: LibraryNode
    let onOpen: (URL) -> Void
    var library: LibraryModel

    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var dropHighlight: DropHighlight = .none

    var body: some View {
        if node.kind == .folder {
            DisclosureGroup(isExpanded: Binding(
                get: { library.expandedFolders.contains(node.url.standardizedFileURL.path) },
                set: { expanded in
                    if expanded {
                        library.expandedFolders.insert(node.url.standardizedFileURL.path)
                    } else {
                        library.expandedFolders.remove(node.url.standardizedFileURL.path)
                    }
                }
            )) {
                ForEach(node.children ?? []) { child in
                    LibraryRow(node: child, onOpen: onOpen, library: library)
                }
            } label: {
                Group {
                    if isRenaming {
                        TextField("Name", text: $draftName, onCommit: {
                            isRenaming = false
                            _ = library.rename(url: node.url, to: draftName)
                        })
                        .textFieldStyle(.roundedBorder)
                        .quoinScaledFont(size: 12.5)
                    } else {
                        Label(node.name, systemImage: "folder")
                            .quoinScaledFont(size: 12.5)
                    }
                }
                .onDrag {
                    // Drop targets classify the badge by reading the live drag
                    // pasteboard (see LibraryDropDelegate), so nothing needs to
                    // be stashed here — the provider IS the source of truth.
                    documentDragProvider(for: node.url, isDirectory: true)
                }
                // Dropping onto a folder MOVES internal items there (⌘Z undoes)
                // or IMPORTS an external markdown file as a copy; invalid drops
                // (a folder onto itself or a descendant, a non-markdown file)
                // show the forbidden badge and a red highlight (UI #21).
                .onDrop(of: [.fileURL], delegate: LibraryDropDelegate(
                    target: node.url, library: library, highlight: $dropHighlight))
                .background(dropBackground, in: RoundedRectangle(cornerRadius: 4))
                .contextMenu {
                    Button("New Document in “\(node.name)”") {
                        if let url = library.createDocument(in: node.url) { onOpen(url) }
                    }
                    Button("New Folder") { library.createFolder(in: node.url) }
                    Button("Rename") {
                        draftName = node.name
                        isRenaming = true
                    }
                    Button("Duplicate") { Task { await library.duplicateFlushingSession(url: node.url) } }
                    Divider()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([node.url])
                    }
                    Divider()
                    Button("Move to Trash", role: .destructive) {
                        library.trash(url: node.url)
                    }
                }
            }
        } else {
            row
                .onDrag {
                    documentDragProvider(for: node.url, isDirectory: false)
                }
        }
    }

    /// The folder row's drop tint: accent when the drop is accepted, red when
    /// the target is forbidden (self / descendant / no-op).
    private var dropBackground: Color {
        switch dropHighlight {
        case .none: return .clear
        case .accepted: return Color.accentColor.opacity(0.15)
        case .rejected: return Color.red.opacity(0.15)
        }
    }

    private var row: some View {
        Group {
            if isRenaming {
                TextField("Name", text: $draftName, onCommit: {
                    isRenaming = false
                    _ = library.rename(url: node.url, to: draftName)
                })
                .textFieldStyle(.roundedBorder)
                .quoinScaledFont(size: 12.5)
            } else {
                Label {
                    Text(node.name)
                        .quoinScaledFont(size: 12.5)
                        .foregroundStyle(node.kind == .asset ? Color.primary.opacity(0.35) : Color.primary)
                } icon: {
                    Image(systemName: node.kind == .asset ? "photo" : "doc.text")
                        .foregroundStyle(node.kind == .asset ? Color.primary.opacity(0.35) : Color.secondary)
                }
            }
        }
        .tag(node.url)
        .contentShape(Rectangle())
        .onTapGesture {
            if node.kind == .document { onOpen(node.url) }
        }
        .contextMenu {
            if node.kind == .document {
                Button("Open") { onOpen(node.url) }
                Button("Rename") {
                    draftName = node.name
                    isRenaming = true
                }
            }
            Button("Duplicate") {
                Task {
                    if let copy = await library.duplicateFlushingSession(url: node.url) {
                        if node.kind == .document { onOpen(copy) }
                    }
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                library.trash(url: node.url)
            }
        }
    }
}

// MARK: - Quick open (⇧⌘O)

/// Centered floating panel: search row + fuzzy-title / full-text results.
struct QuickOpenPanel: View {
    @Bindable var library: LibraryModel
    @Binding var isPresented: Bool
    let onOpen: (URL) -> Void

    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Open document…", text: $library.quickOpenQuery)
                    .textFieldStyle(.plain)
                    .quoinScaledFont(size: 15)
                    .focused($fieldFocused)
                    .onSubmit { openHighlighted() }
                    .onExitCommand { close() }
                    // ↑/↓/Home/End walk the results with wrap (UI #10 — the
                    // highlight state existed but nothing ever moved it). The
                    // movement math lives in ListSelection so Quick Open and
                    // the library search list stay identical.
                    .onKeyPress(.downArrow) {
                        guard !library.quickOpenResults.isEmpty else { return .ignored }
                        highlighted = ListSelection.next(highlighted, count: library.quickOpenResults.count)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !library.quickOpenResults.isEmpty else { return .ignored }
                        highlighted = ListSelection.previous(highlighted, count: library.quickOpenResults.count)
                        return .handled
                    }
                    .onKeyPress(.home) {
                        guard !library.quickOpenResults.isEmpty else { return .ignored }
                        highlighted = ListSelection.first(count: library.quickOpenResults.count)
                        return .handled
                    }
                    .onKeyPress(.end) {
                        guard !library.quickOpenResults.isEmpty else { return .ignored }
                        highlighted = ListSelection.last(count: library.quickOpenResults.count)
                        return .handled
                    }
            }
            .padding(12)

            if !library.quickOpenResults.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(library.quickOpenResults.enumerated()), id: \.element.id) { index, result in
                                resultRow(result, isHighlighted: index == highlighted)
                                    .id(index)
                                    .onTapGesture {
                                        onOpen(result.url)
                                        close()
                                    }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: highlighted) { _, index in
                        proxy.scrollTo(index)
                    }
                }
            } else {
                Divider()
                Text(library.quickOpenQuery.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Recent documents appear here as you work"
                     : "No matches")
                    .quoinScaledFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            }
        }
        .frame(width: 480)
        .background(reduceTransparency
            ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
            : AnyShapeStyle(Material.regularMaterial),
            in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.14), radius: 32, y: 12)
        .onAppear { fieldFocused = true }
        .onChange(of: library.quickOpenQuery) { _, _ in
            highlighted = 0
            library.runQuickOpen()
        }
    }

    private func resultRow(_ result: QuickOpen.Result, isHighlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.title)
                .quoinScaledFont(size: 13, weight: .medium)
                .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            if !result.snippet.isEmpty {
                Text(result.snippet)
                    .quoinScaledFont(size: 11)
                    .lineLimit(1)
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHighlighted ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }

    private func openHighlighted() {
        guard library.quickOpenResults.indices.contains(highlighted) else { return }
        onOpen(library.quickOpenResults[highlighted].url)
        close()
    }

    private func close() {
        isPresented = false
        library.quickOpenQuery = ""
    }
}

// MARK: - Tab bar

/// One open document. Identity is STABLE across renames — the editor is
/// keyed by `id`, so a first-H1 rename mutates `url` without tearing the
/// live session down (ledger senior #13).
struct DocumentTab: Identifiable, Hashable {
    let id = UUID()
    var url: URL
}

/// Custom tab strip per the handoff: hidden with one document, active tab
/// emphasized, ⌘1–9 handled by the window.
struct DocumentTabBar: View {
    let tabs: [DocumentTab]
    @Binding var activeTabID: DocumentTab.ID?
    let onClose: (DocumentTab) -> Void

    @State private var hoveredTab: DocumentTab.ID?

    /// Safari-style width band (#75): tabs share the bar equally, clamped so
    /// a crowd compresses (titles truncate) and a pair doesn't sprawl. Below
    /// the floor the strip scrolls sideways instead of widening the window.
    private static let minTabWidth: CGFloat = 72
    private static let maxTabWidth: CGFloat = 240
    private static let tabSpacing: CGFloat = 1
    /// Grows with Dynamic Type so the scaled tab titles never clip against the
    /// bar's `.clipped()` bound (#28); base height is the handoff's 27pt.
    @ScaledMetric(relativeTo: .body) private var barHeight: CGFloat = 27

    var body: some View {
        if tabs.count > 1 {
            // GeometryReader accepts ANY proposed width, so the strip never
            // contributes to the window's minimum width no matter how many
            // tabs are open (#75) — tabs divide whatever the window grants.
            GeometryReader { proxy in
                let available = proxy.size.width - Self.tabSpacing * CGFloat(tabs.count - 1)
                let tabWidth = min(max(available / CGFloat(tabs.count), Self.minTabWidth),
                                   Self.maxTabWidth)
                if tabWidth * CGFloat(tabs.count) <= available + 0.5 {
                    // The fitting case stays a plain HStack, NOT a horizontal
                    // ScrollView: on macOS Tahoe the toolbar's scroll-edge
                    // effect gives any scroll view abutting the toolbar a
                    // glass "pocket" overlay that sat ON TOP of the tabs and
                    // swallowed every click and hover (tabs became
                    // unselectable by mouse; ⌘1–9 still worked).
                    strip(tabWidth: tabWidth)
                } else {
                    // More tabs than the floor allows: the strip scrolls.
                    // The pocket overlay above is suppressed explicitly —
                    // scrollEdgeEffectHidden exists exactly for this (26+;
                    // the effect itself doesn't exist before Tahoe).
                    scrollEdgeSafe(
                        ScrollView(.horizontal, showsIndicators: false) {
                            strip(tabWidth: Self.minTabWidth)
                        }
                    )
                }
            }
            .frame(height: barHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04))
            .overlay(alignment: .bottom) { Divider() }
            .clipped()
        }
    }

    @ViewBuilder
    private func scrollEdgeSafe(_ scroll: some View) -> some View {
        if #available(macOS 26.0, *) {
            scroll.scrollEdgeEffectHidden(true, for: .all)
        } else {
            scroll
        }
    }

    private func strip(tabWidth: CGFloat) -> some View {
        HStack(spacing: Self.tabSpacing) {
            ForEach(tabs) { tab in
                tabView(tab, width: tabWidth)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func tabView(_ tab: DocumentTab, width: CGFloat) -> some View {
        let isActive = tab.id == activeTabID
        let isHovered = tab.id == hoveredTab
        let name = tab.url.deletingPathExtension().lastPathComponent
        // Selecting a tab is a Button, NOT `.onTapGesture` — the horizontal
        // ScrollView's pan gesture was swallowing the taps, so clicking a tab
        // did nothing (activeTabID never changed). The close ✕ is a SIBLING
        // button (never nested inside the select button) so each owns its hit
        // area cleanly.
        return HStack(spacing: 6) {
            Button {
                activeTabID = tab.id
            } label: {
                Text(name)
                    .quoinScaledFont(size: 12, weight: isActive ? .medium : .regular)
                    .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.5))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name) tab")
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            // Close affordance appears on hover (handoff: the unsaved dot
            // swaps to ✕ on hover; ✕ stays hidden otherwise).
            Button {
                onClose(tab)
            } label: {
                Image(systemName: "xmark")
                    .quoinScaledFont(size: 8, weight: .bold)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .accessibilityLabel("Close tab")
        }
        .padding(.horizontal, 12)
        // The tab's width is ASSIGNED, never demanded — the title truncates
        // into whatever share of the bar it gets (#75).
        .frame(width: width, height: barHeight)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .onHover { inside in
            hoveredTab = inside ? tab.id : (hoveredTab == tab.id ? nil : hoveredTab)
        }
    }
}
