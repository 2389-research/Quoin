#if canImport(AppIntents)
import Foundation

/// User-facing failures for the App Intents surface. `LocalizedError` so
/// Shortcuts (and Siri) show the message verbatim instead of a generic
/// "the action could not run".
enum QuoinIntentError: LocalizedError {
    /// No library folder has been chosen yet — nothing to create into or
    /// search within.
    case noLibrary
    /// A library was chosen once but Quoin can no longer reach it (the
    /// security-scoped bookmark is dead, or the folder moved/was deleted).
    case libraryUnavailable
    /// The referenced note is no longer at its path (moved, renamed, or
    /// deleted outside Quoin).
    case documentNotFound(String)
    /// There was nothing meaningful to append (empty or whitespace-only text).
    case emptyAppendText
    /// The note could not be created on disk.
    case createFailed(String)
    /// A document could not be read for an append/export.
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .noLibrary:
            return "No Quoin library is set up yet. Open Quoin and choose a library folder first."
        case .libraryUnavailable:
            return "Quoin can't reach your library folder — it may have moved or been deleted. Open Quoin and choose it again."
        case .documentNotFound(let name):
            return "Couldn't find “\(name)” in your library. It may have been moved, renamed, or deleted."
        case .emptyAppendText:
            return "There was no text to append."
        case .createFailed(let name):
            return "Couldn't create “\(name)”. Check the disk or the folder's permissions."
        case .unreadable(let name):
            return "Couldn't read “\(name)”."
        }
    }
}
#endif
