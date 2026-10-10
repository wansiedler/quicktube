import Foundation
import Testing

@testable import QuickTubeCore

@Suite struct AppSettingsTests {
    @Test func defaultsMatchSpec() {
        let s = AppSettings()
        #expect(s.captureMode == .displayUnderCursor)
        #expect(!s.cameraEnabled && !s.cameraAlwaysOn)
        #expect(s.cameraSize == .medium && s.cameraCorner == .bottomLeft)
        #expect(!s.pauseEnabled)
        #expect(!s.systemAudioEnabled && s.microphoneEnabled)
        #expect(s.historyEnabled)
        #expect(!s.clickHighlightEnabled && !s.keystrokeOverlayEnabled && s.overlaysInRecording)
        #expect(s.trimTailSeconds == 1.0 && s.trimHeadSeconds == 0.0)
        #expect(s.titleTemplate == "{date}")
        #expect(!s.deleteAfterUpload && s.deleteOlderThanDays == 0)
        #expect(s.automaticUpdates)
        #expect(!s.gifEnabled && s.gifFPS == 10 && s.gifMaxWidth == 800 && s.gifMaxSeconds == 30)
        #expect(s.quality == .default)
        #expect(s.telegramCompressToFit && s.telegramLimitMB == 50)
        #expect(s.telegramLimitBytes == 50 << 20)
    }

    @Test func telegramLimitBytesIsClamped() {
        var s = AppSettings()
        s.telegramLimitMB = 2
        #expect(s.telegramLimitBytes == 10 << 20)
        s.telegramLimitMB = 5000
        #expect(s.telegramLimitBytes == 2000 << 20)
    }

    @Test func roundTrip() throws {
        let s = Self.allNonDefault()
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
    }

    static func allNonDefault() -> AppSettings {
        var s = AppSettings()
        s.captureMode = .selectWindow
        s.cameraEnabled = true
        s.cameraAlwaysOn = true
        s.cameraSize = .large
        s.cameraCorner = .topRight
        s.pauseEnabled = true
        s.systemAudioEnabled = true
        s.microphoneEnabled = false
        s.historyEnabled = false
        s.clickHighlightEnabled = true
        s.keystrokeOverlayEnabled = true
        s.overlaysInRecording = false
        s.trimTailSeconds = 2.5
        s.trimHeadSeconds = 0.5
        s.titleTemplate = "Demo {date}"
        s.deleteAfterUpload = true
        s.deleteOlderThanDays = 14
        s.automaticUpdates = false
        s.gifEnabled = true
        s.gifFPS = 15
        s.gifMaxWidth = 640
        s.gifMaxSeconds = 12
        s.quality = RecordingQuality(resolution: .fullHD, fps: 30)
        s.telegramCompressToFit = false
        s.telegramLimitMB = 2000
        return s
    }

    @Test func unknownEnumValueResetsOnlyThatField() throws {
        let json = #"{"captureMode":"hologram","gifFPS":15,"cameraSize":"large","titleTemplate":7}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        var expected = AppSettings()
        expected.gifFPS = 15
        expected.cameraSize = .large
        #expect(decoded == expected)
    }

    // MARK: load(from:)

    private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func loadSeedsQualityFromLegacyKey() throws {
        try withSuite { defaults in
            let legacy = RecordingQuality(resolution: .uhd4K, fps: 30)
            defaults.set(try JSONEncoder().encode(legacy), forKey: AppSettings.legacyQualityKey)
            var expected = AppSettings()
            expected.quality = legacy
            #expect(AppSettings.load(from: defaults) == expected)
        }
    }

    @Test func loadPrefersV2OverLegacy() throws {
        try withSuite { defaults in
            defaults.set(
                try JSONEncoder().encode(RecordingQuality(resolution: .uhd4K, fps: 30)),
                forKey: AppSettings.legacyQualityKey)
            let v2 = Self.allNonDefault()
            defaults.set(try JSONEncoder().encode(v2), forKey: AppSettings.storageKey)
            #expect(AppSettings.load(from: defaults) == v2)
        }
    }

    @Test func loadWithNothingStoredGivesDefaults() {
        withSuite { defaults in
            #expect(AppSettings.load(from: defaults) == AppSettings())
        }
    }

    @Test func loadWithCorruptBlobFallsBackAndLogs() {
        withSuite { defaults in
            defaults.set(Data("not json".utf8), forKey: AppSettings.storageKey)
            var logged: [String] = []
            let loaded = AppSettings.load(from: defaults, log: { logged.append($0) })
            #expect(loaded == AppSettings())
            #expect(logged.count == 1)
            // The corrupt blob is left untouched by load.
            #expect(defaults.data(forKey: AppSettings.storageKey) == Data("not json".utf8))
        }
    }

    @Test func emptyObjectDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(decoded == AppSettings())
    }

    @Test func partialJSONKeepsOtherDefaults() throws {
        let json = #"{"captureMode":"selectWindow","gifMaxSeconds":12,"cameraSize":"small"}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        var expected = AppSettings()
        expected.captureMode = .selectWindow
        expected.gifMaxSeconds = 12
        expected.cameraSize = .small
        #expect(decoded == expected)
    }

    @Test func cameraSizePoints() {
        #expect(CameraSize.small.points == 160)
        #expect(CameraSize.medium.points == 220)
        #expect(CameraSize.large.points == 300)
    }
}
