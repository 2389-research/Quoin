import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuoinCore

/// The library sidebar: classic tree per the handoff (icons, disclosure
/// chevrons, accent-filled selection), documents open on click, assets
/// grayed, footer with the document count.
struct LibrarySidebar: View {
    @Bindable var library: LibraryModel
    @Binding var selection: URL?
    @Binding var isSearchVisible: Bool
    let onOpen: (URL) -> Void

    @FocusState private var searchFocused: Bool

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
            .font(.system(size: 10.5))
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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Press ⌘N to create one")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        // Dropping onto empty sidebar space moves to the library root.
        .onDrop(of: [.fileURL], isTargeted: $isRootDropTargeted) { providers in
            guard let root = library.rootURL else { return false }
            return handleFileDrop(providers, into: root, library: library)
        }
        .overlay {
            if isRootDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    @State private var isRootDropTargeted = false

    // MARK: - Library-wide search (⇧⌘F, persistent per handoff)

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            TextField("Search library", text: $library.librarySearchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onExitCommand { isSearchVisible = false }
                .onChange(of: library.librarySearchQuery) { _, _ in
                    library.runLibrarySearch()
                }
            if !library.librarySearchQuery.isEmpty {
                Button {
                    library.librarySearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(library.librarySearchResults) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title)
                            .font(.system(size: 12.5, weight: .medium))
                        if !result.snippet.isEmpty {
                            Text(result.snippet)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(result.url) }
                }
                if library.librarySearchResults.isEmpty {
                    Text("No matches")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(10)
                }
            }
        }
    }
}

/// A drag provider for a library item (#31, drag-out-to-Finder).
///
/// It vends TWO representations so one drag serves both directions:
///   • `public.file-url` (from the `NSURL` object) — what the intra-sidebar
///     move drop reads back in `handleFileDrop`, so library moves are
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

/// Loads file URLs off the drag pasteboard and performs the library move.
@discardableResult
func handleFileDrop(_ providers: [NSItemProvider], into folder: URL, library: LibraryModel) -> Bool {
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
                library.importOrMove(url: url, into: folder)
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
    @State private var isDropTargeted = false

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
                        .font(.system(size: 12.5))
                    } else {
                        Label(node.name, systemImage: "folder")
                            .font(.system(size: 12.5))
                    }
                }
                .onDrag { documentDragProvider(for: node.url, isDirectory: true) }
                // Dropping a file onto a folder moves it there (⌘Z undoes);
                // the target folder highlights while hovered (UI #21).
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleFileDrop(providers, into: node.url, library: library)
                }
                .background(
                    isDropTargeted ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
                .contextMenu {
                    Button("New Document in “\(node.name)”") {
                        if let url = library.createDocument(in: node.url) { onOpen(url) }
                    }
                    Button("New Folder") { library.createFolder(in: node.url) }
                    Button("Rename") {
                        draftName = node.name
                        isRenaming = true
                    }
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
                .onDrag { documentDragProvider(for: node.url, isDirectory: false) }
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
                .font(.system(size: 12.5))
            } else {
                Label {
                    Text(node.name)
                        .font(.system(size: 12.5))
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
                    .font(.system(size: 15))
                    .focused($fieldFocused)
                    .onSubmit { openHighlighted() }
                    .onExitCommand { close() }
                    // ↑/↓ walk the results (UI #10 — the highlight state
                    // existed but nothing ever moved it).
                    .onKeyPress(.downArrow) {
                        guard !library.quickOpenResults.isEmpty else { return .ignored }
                        highlighted = min(highlighted + 1, library.quickOpenResults.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard highlighted > 0 else { return .ignored }
                        highlighted -= 1
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
                    .font(.system(size: 11))
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            if !result.snippet.isEmpty {
                Text(result.snippet)
                    .font(.system(size: 11))
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
    private static let barHeight: CGFloat = 27

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
            .frame(height: Self.barHeight)
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
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
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
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .accessibilityLabel("Close tab")
        }
        .padding(.horizontal, 12)
        // The tab's width is ASSIGNED, never demanded — the title truncates
        // into whatever share of the bar it gets (#75).
        .frame(width: width, height: Self.barHeight)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .onHover { inside in
            hoveredTab = inside ? tab.id : (hoveredTab == tab.id ? nil : hoveredTab)
        }
    }
}
