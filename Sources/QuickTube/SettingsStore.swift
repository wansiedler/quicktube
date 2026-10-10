import Foundation
import Observation
import QuickTubeCore

/// UserDefaults-backed home of `AppSettings`; every change is persisted immediately.
@MainActor
@Observable
final class SettingsStore {
    static let key = AppSettings.storageKey

    var settings: AppSettings {
        didSet { persist() }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let hadStored = defaults.data(forKey: Self.key) != nil
        self.settings = AppSettings.load(from: defaults, log: { DiagnosticsLog.append($0) })
        // Persist only a fresh/migrated value; never overwrite a stored blob that failed to decode.
        if !hadStored { persist() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
