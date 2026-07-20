import Foundation

/// Pure decision logic for drag-and-drop: given a dragged item and a proposed
/// target, decide what the operation IS (move / copy / reject). This is the
/// testable seam — the AppKit drop-delegate wiring stays thin and defers every
/// "is this valid?" question here, and the same decision runs twice: once for
/// the live drag badge (best-effort, from the recorded drag source) and again
/// at drop time against the real dropped URL (authoritative, so a stale badge
/// can never cause a wrong file operation).
public enum DropValidation {

    /// Image file types Quoin copies into `assets/` on an editor drop. Canonical
    /// home for the set (ReaderModel aliases this) so the editor-drop decision
    /// and the model's copy step never drift.
    public static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]

    // MARK: - Library sidebar drops

    /// What a library sidebar drop should do.
    public enum Operation: Equatable, Sendable {
        /// Internal drag → a real file move (default sidebar semantics).
        case move
        /// External file → import a COPY (the original never vanishes).
        case copy
        /// Invalid target: self-drop, a folder into its own descendant, a
        /// no-op same-folder drop, or a non-markdown external file.
        case reject
    }

    /// Decide the operation for dropping `dragged` onto the folder `target`.
    ///
    /// - Internal items (anything already under `libraryRoot`) MOVE, except:
    ///   dropping onto themselves, dropping a folder into one of its own
    ///   descendants, or dropping onto the folder they already live in (a
    ///   no-op) — all rejected so the badge shows "forbidden" and nothing runs.
    /// - External items (outside `libraryRoot`) are COPIED when they are
    ///   markdown files, and rejected otherwise (non-markdown, or a folder).
    public static func libraryDrop(
        dragged: URL,
        onto target: URL,
        libraryRoot: URL
    ) -> Operation {
        let draggedPath = dragged.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        let rootPath = libraryRoot.standardizedFileURL.path

        let isInternal = draggedPath == rootPath
            || draggedPath.hasPrefix(rootPath + "/")

        if isInternal {
            // Can't move the library root itself.
            if draggedPath == rootPath { return .reject }
            // Dropping onto itself.
            if targetPath == draggedPath { return .reject }
            // Dropping a folder into its own subtree.
            if targetPath.hasPrefix(draggedPath + "/") { return .reject }
            // Dropping into the folder it already lives in: nothing to do.
            if dragged.deletingLastPathComponent().standardizedFileURL.path == targetPath {
                return .reject
            }
            return .move
        }

        // External: import markdown, reject everything else.
        return Library.markdownExtensions.contains(dragged.pathExtension.lowercased())
            ? .copy
            : .reject
    }

    // MARK: - Editor image / document drops

    /// What a file dropped onto the document editor should do.
    public enum EditorDrop: Equatable, Sendable {
        /// An image: copy into `assets/` and insert a reference.
        case insertImage
        /// A markdown file: open it as a document (inserting its bytes would
        /// be surprising — a tab is what the gesture means).
        case openDocument
        /// Anything else: rejected with feedback (never a silent no-op).
        case reject
    }

    /// Classify a file dropped onto the editor by extension.
    public static func editorDrop(_ url: URL) -> EditorDrop {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .insertImage }
        if Library.markdownExtensions.contains(ext) { return .openDocument }
        return .reject
    }
}
