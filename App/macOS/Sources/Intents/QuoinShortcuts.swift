#if canImport(AppIntents)
import AppIntents

/// The App Shortcuts Quoin offers out of the box — discoverable in the
/// Shortcuts app, Spotlight, and by voice, with no user setup. Apple's
/// guidance is a small, focused set; these five cover the common library
/// actions. Compiled INTO the app (no extension target): the provider is
/// discovered automatically at launch.
///
/// Every phrase must contain `\(.applicationName)` — the phrases below use the
/// literal "Quoin" via the app name so "Create a note in Quoin", "Search Quoin
/// for…", etc. all resolve.
@available(macOS 14.0, *)
struct QuoinShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateNoteIntent(),
            phrases: [
                "Create a note in \(.applicationName)",
                "New \(.applicationName) note",
                "Add a note to \(.applicationName)",
            ],
            shortTitle: "Create Note",
            systemImageName: "square.and.pencil")

        AppShortcut(
            intent: AppendToNoteIntent(),
            phrases: [
                "Append to a note in \(.applicationName)",
                "Add text to a \(.applicationName) note",
            ],
            shortTitle: "Append to Note",
            systemImageName: "text.append")

        AppShortcut(
            intent: OpenNoteIntent(),
            phrases: [
                "Open a note in \(.applicationName)",
                "Open a \(.applicationName) note",
            ],
            shortTitle: "Open Note",
            systemImageName: "doc.text")

        AppShortcut(
            intent: SearchLibraryIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search my \(.applicationName) library",
                "Find a note in \(.applicationName)",
            ],
            shortTitle: "Search Library",
            systemImageName: "magnifyingglass")

        AppShortcut(
            intent: ExportNoteIntent(),
            phrases: [
                "Export a \(.applicationName) note",
                "Export a note from \(.applicationName)",
            ],
            shortTitle: "Export Note",
            systemImageName: "square.and.arrow.up")
    }
}
#endif
