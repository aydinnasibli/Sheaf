import Sparkle
import SwiftUI

/// Keeps Sheaf up to date using Sparkle.
///
/// Every push to main publishes a build on GitHub (.github/workflows/mac-app.yml)
/// together with `appcast.xml`, which describes it. Sheaf reads that file from the
/// newest release (`SUFeedURL` in Info.plist) when it opens and then every hour
/// (`SUScheduledCheckInterval`), and offers to install a newer build. A download is
/// installed only if it carries an EdDSA signature matching `SUPublicEDKey`; the
/// private half of that key exists only in the repo's `SPARKLE_PRIVATE_KEY`
/// secret and in the developer's keychain (account "sheaf").
@Observable
final class Updater {
    static let shared = Updater()

    /// False while a check is already running, or in builds that don't update.
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        #if DEBUG
        // Builds run from Xcode never update, so the published build is never
        // offered over the one being worked on.
        let startsUpdater = false
        #else
        let startsUpdater = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: startsUpdater, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let canCheck = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = canCheck }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
