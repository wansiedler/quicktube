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
    }

    @Test func roundTrip() throws {
        var s = AppSettings()
        s.captureMode = .selectArea
        s.cameraEnabled = true
        s.cameraSize = .large
        s.cameraCorner = .topRight
        s.titleTemplate = "Demo {date}"
        s.trimHeadSeconds = 0.5
        s.gifFPS = 15
        s.quality = RecordingQuality(resolution: .fullHD, fps: 30)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
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
