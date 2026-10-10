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
        self.settings = AppSettings.load(from: defaults)
        // Writing the migrated value makes the Recorder's UserDefaults handoff see it at once.
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
