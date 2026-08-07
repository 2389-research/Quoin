import SwiftUI
import QuoinCore
import QuoinRender

/// First-run guidance card (design: first-run-and-return, Part B). When the app
/// opens the auto-untitled document because nothing else claimed the window, this
/// sits just below the caret: it tells the user their note is already safe
/// (autosaved), how to give it a real home (⌘S), and offers the two demoted
/// library/open paths without ever forcing a filing decision. It fades on the
/// first keystroke — the moment the document stops being empty — or on the ×.
///
/// Styling models the empty-state `sampleOfferCard`: an accent-tinted card
/// (handoff callout style — radius 8, low-alpha accent fill + hairline border)
/// with the handoff type ramp (12.5pt semibold title, 11.5pt secondary body).
struct FirstRunBanner: View {
    /// The active tab's model. Read only for `stats.characterCount` — the
    /// observable signal that the user has typed, which fades the banner.
    let model: ReaderModel
    var onOpenFile: () -> Void
    var onConnectLibrary: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Untitled note — saved automatically.")
                    .quoinScaledFont(size: 12.5, weight: .semibold)
                Text("⌘S to give it a home.")
                    .quoinScaledFont(size: 11.5)
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Button("Open a File…") { onOpenFile() }
                    Button("Connect a Library…") { onConnectLibrary() }
                }
                .buttonStyle(.link)
                .quoinScaledFont(size: 11.5)
                .padding(.top, 3)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .quoinScaledFont(size: 10.5, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 440, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.15))
        )
        // Fade on the first keystroke: an empty untitled document has
        // characterCount 0; the first typed character bumps it, and the banner
        // has served its purpose. The parent animates the actual removal.
        .onChange(of: model.stats.characterCount) { _, count in
            if count > 0 { onDismiss() }
        }
    }
}
