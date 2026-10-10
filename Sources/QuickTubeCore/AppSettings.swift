import CoreGraphics
import Foundation

public enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case displayUnderCursor, selectArea, selectWindow

    public var label: String {
        switch self {
        case .displayUnderCursor: "Display under cursor"
        case .selectArea: "Select area"
        case .selectWindow: "Select window"
        }
    }
}

public enum CameraSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    public var points: CGFloat {
        switch self {
        case .small: 160
        case .medium: 220
        case .large: 300
        }
    }

    public var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

public enum Corner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    public var label: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
}

/// All user-facing settings. Decoding tolerates missing keys, so older stored values keep working.
public struct AppSettings: Codable, Sendable, Equatable {
    public var captureMode: CaptureMode = .displayUnderCursor
    public var cameraEnabled = false
    public var cameraAlwaysOn = false
    public var cameraSize: CameraSize = .medium
    public var cameraCorner: Corner = .bottomLeft
    public var pauseEnabled = false
    public var systemAudioEnabled = false
    public var microphoneEnabled = true
    public var historyEnabled = true
    public var clickHighlightEnabled = false
    public var keystrokeOverlayEnabled = false
    public var overlaysInRecording = true
    public var trimTailSeconds = 1.0
    public var trimHeadSeconds = 0.0
    public var titleTemplate = "{date}"
    public var deleteAfterUpload = false
    public var deleteOlderThanDays = 0
    public var automaticUpdates = true
    public var gifEnabled = false
    public var gifFPS = 10
    public var gifMaxWidth = 800
    public var gifMaxSeconds = 30
    public var quality = RecordingQuality.default

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case captureMode, cameraEnabled, cameraAlwaysOn, cameraSize, cameraCorner, pauseEnabled
        case systemAudioEnabled, microphoneEnabled, historyEnabled, clickHighlightEnabled
        case keystrokeOverlayEnabled, overlaysInRecording, trimTailSeconds, trimHeadSeconds
        case titleTemplate, deleteAfterUpload, deleteOlderThanDays, automaticUpdates
        case gifEnabled, gifFPS, gifMaxWidth, gifMaxSeconds, quality
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        captureMode = try c.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? d.captureMode
        cameraEnabled = try c.decodeIfPresent(Bool.self, forKey: .cameraEnabled) ?? d.cameraEnabled
        cameraAlwaysOn = try c.decodeIfPresent(Bool.self, forKey: .cameraAlwaysOn) ?? d.cameraAlwaysOn
        cameraSize = try c.decodeIfPresent(CameraSize.self, forKey: .cameraSize) ?? d.cameraSize
        cameraCorner = try c.decodeIfPresent(Corner.self, forKey: .cameraCorner) ?? d.cameraCorner
        pauseEnabled = try c.decodeIfPresent(Bool.self, forKey: .pauseEnabled) ?? d.pauseEnabled
        systemAudioEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .systemAudioEnabled) ?? d.systemAudioEnabled
        microphoneEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? d.microphoneEnabled
        historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? d.historyEnabled
        clickHighlightEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .clickHighlightEnabled) ?? d.clickHighlightEnabled
        keystrokeOverlayEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .keystrokeOverlayEnabled)
            ?? d.keystrokeOverlayEnabled
        overlaysInRecording =
            try c.decodeIfPresent(Bool.self, forKey: .overlaysInRecording) ?? d.overlaysInRecording
        trimTailSeconds =
            try c.decodeIfPresent(Double.self, forKey: .trimTailSeconds) ?? d.trimTailSeconds
        trimHeadSeconds =
            try c.decodeIfPresent(Double.self, forKey: .trimHeadSeconds) ?? d.trimHeadSeconds
        titleTemplate = try c.decodeIfPresent(String.self, forKey: .titleTemplate) ?? d.titleTemplate
        deleteAfterUpload =
            try c.decodeIfPresent(Bool.self, forKey: .deleteAfterUpload) ?? d.deleteAfterUpload
        deleteOlderThanDays =
            try c.decodeIfPresent(Int.self, forKey: .deleteOlderThanDays) ?? d.deleteOlderThanDays
        automaticUpdates =
            try c.decodeIfPresent(Bool.self, forKey: .automaticUpdates) ?? d.automaticUpdates
        gifEnabled = try c.decodeIfPresent(Bool.self, forKey: .gifEnabled) ?? d.gifEnabled
        gifFPS = try c.decodeIfPresent(Int.self, forKey: .gifFPS) ?? d.gifFPS
        gifMaxWidth = try c.decodeIfPresent(Int.self, forKey: .gifMaxWidth) ?? d.gifMaxWidth
        gifMaxSeconds = try c.decodeIfPresent(Int.self, forKey: .gifMaxSeconds) ?? d.gifMaxSeconds
        quality = try c.decodeIfPresent(RecordingQuality.self, forKey: .quality) ?? d.quality
    }

    /// UserDefaults key holding the JSON-encoded settings.
    public static let storageKey = "settings.v2"
    /// Pre-v2 key holding only the `RecordingQuality`; seeds `quality` until `storageKey` exists.
    public static let legacyQualityKey = "recording.quality"

    /// Stored settings, else defaults seeded from the legacy quality key.
    public static func load(from defaults: UserDefaults) -> AppSettings {
        if let data = defaults.data(forKey: storageKey),
            let stored = try? JSONDecoder().decode(AppSettings.self, from: data)
        {
            return stored
        }
        var settings = AppSettings()
        if let data = defaults.data(forKey: legacyQualityKey),
            let legacy = try? JSONDecoder().decode(RecordingQuality.self, from: data)
        {
            settings.quality = legacy
        }
        return settings
    }
}
