import SwiftUI

#if canImport(Sparkle)
import Sparkle

/// Owns the app's Sparkle updater.
///
/// Sparkle fetches an EdDSA-signed *appcast* (an XML feed of available
/// versions) and installs updates atomically with rollback. The appcast URL
/// and the public signing key live in `Info.plist` as `SUFeedURL` and
/// `SUPublicEDKey`; only the matching private key (kept in the keychain, never
/// the repo) can sign a release the app will accept.
///
/// The update check is Quoin's *only* network traffic. It is user-toggleable
/// in Settings and disclosed on first run; nothing else here ever reaches the
/// network.
@MainActor
final class SoftwareUpdater: ObservableObject {
    let controller: SPUStandardUpdaterController

    /// Mirrors `SPUUpdater.canCheckForUpdates` so the menu item can disable
    /// itself while a check is already in flight.
    @Published var canCheckForUpdates = false

    /// True once a real EdDSA public key is present. Until then the updater is
    /// left dormant: Sparkle validates `SUPublicEDKey` when it starts, and the
    /// placeholder key makes it fail to start with a visible "updater failed to
    /// start" alert on launch. We must not start it before signing is set up
    /// (see docs/reference/distribution.md).
    let isConfigured: Bool

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = !key.isEmpty && !key.hasPrefix("REPLACE_WITH")

        // Only start (and thus schedule background checks) when a real key
        // exists. Dormant otherwise — no launch alert, no network traffic.
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        if isConfigured {
            controller.updater.publisher(for: \.canCheckForUpdates)
                .assign(to: &$canCheckForUpdates)
        }
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        controller.updater.checkForUpdates()
    }
}

/// The "Check for Updates…" item that sits under the Quoin menu.
struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: SoftwareUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
#endif
