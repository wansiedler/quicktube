import Foundation
import Sparkle

/// Sparkle auto-updates from the appcast in `SUFeedURL`, verified with `SUPublicEDKey`.
///
/// Inert unless the running bundle is configured: a `swift run` binary has no bundle, and a build whose
/// Info.plist still carries the placeholder key could never verify an update, so Sparkle is not started
/// at all there (it would only log an error and show an alert on every check).
@MainActor
final class Updater {
    nonisolated static let placeholderKey = "REPLACE_WITH_PUBLIC_KEY"

    private let controller: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        guard Self.isConfigured(bundle.infoDictionary) else {
            controller = nil
            DiagnosticsLog.append("Updates off: no Sparkle feed or public key in this build")
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// True when the bundle names a feed and a real EdDSA public key.
    nonisolated static func isConfigured(_ info: [String: Any]?) -> Bool {
        guard let feed = info?["SUFeedURL"] as? String, !feed.isEmpty,
            let key = info?["SUPublicEDKey"] as? String, !key.isEmpty, key != placeholderKey
        else { return false }
        return true
    }

    /// False in builds without a feed or key; the UI disables its update controls then.
    var isAvailable: Bool { controller != nil }

    /// Sparkle's own background check schedule; follows `AppSettings.automaticUpdates`.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Checks now and shows Sparkle's window with the result.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
