import Foundation
import QuoinCore

/// Untitled ("scratch") documents — the "frictionless creation, deferred
/// commitment" principle (docs/design/principles.md). ⌘N with no library creates
/// a real, autosaved `.md` in a hidden per-user folder inside the app container,
/// so a new document opens INSTANTLY (no save panel), keeps autosaving, and
/// survives quit (reopened on relaunch). Saving one (⌘S → Save As) relocates it
/// out of the scratch folder to a user-chosen home, at which point it is an
/// ordinary document.
///
/// Because Quoin is file-backed (no in-memory "untitled" buffer), "untitled" is
/// a real file that simply hasn't chosen a home yet. The scratch folder lives in
/// Application Support (persistent — NOT the OS temp, which is purged) and is
/// sandbox-writable without any user grant.
enum ScratchStore {

    /// The scratch folder, created on demand. `nil` only if Application Support
    /// itself is unavailable (never, in practice).
    static var directory: URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("Untitled Documents", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        return dir
    }

    /// Create a new, empty untitled document and return its URL (collision-free
    /// `Untitled.md`, `Untitled 2.md`, …).
    static func createUntitled() -> URL? {
        guard let dir = directory else { return nil }
        let url = Library.uniqueURL(baseName: "Untitled", extension: "md", in: dir)
        guard (try? Data("".utf8).write(to: url)) != nil else { return nil }
        return url
    }

    /// True when `url` is an untitled scratch document (lives under the scratch
    /// folder) — the signal that ⌘S should Save-As rather than no-op.
    static func isScratch(_ url: URL) -> Bool {
        guard let dir = directory else { return false }
        let base = dir.standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(base + "/")
    }

    /// Every untitled document still in the scratch folder, for relaunch
    /// restoration (unsaved work survives quit), in a stable order.
    static func existingUntitled() -> [URL] {
        guard let dir = directory,
              let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        return items
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
