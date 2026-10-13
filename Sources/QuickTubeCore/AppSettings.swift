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
    /// The keystroke pill shows only combos with ⌘, ⌃ or ⌥ and standalone keys, never plain typing.
    public var keystrokeShortcutsOnly = true
    public var overlaysInRecording = true
    /// The status pill is invisible to every screen capture (Zoom, Meet, QuickTime), not only to QuickTube's.
    public var hudHiddenFromCapture = true
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
    /// Re-encode recordings over `telegramLimitMB` so they still go through.
    public var telegramCompressToFit = true
    /// The Bot API accepts 50 MB; self-hosted Bot API servers allow up to 2000 MB.
    public var telegramLimitMB = 50
    /// Compression only lowers bitrate by default; when true it may also step the frame size down.
    public var telegramAllowDownscale = false
    /// Always send H.264 at most 1080p: Telegram's phone apps show a white screen for 6K HEVC.
    public var telegramMobileFriendly = true
    /// `privacy.view` of Vimeo uploads; some plans refuse `unlisted`, and the API error says so.
    public var vimeoPrivacy: VimeoPrivacy = .unlisted

    /// The Telegram limit in bytes, clamped to the range Settings offers.
    public var telegramLimitBytes: Int { min(max(telegramLimitMB, 10), 2000) << 20 }

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case captureMode, cameraEnabled, cameraAlwaysOn, cameraSize, cameraCorner, pauseEnabled
        case systemAudioEnabled, microphoneEnabled, historyEnabled, clickHighlightEnabled
        case keystrokeOverlayEnabled, keystrokeShortcutsOnly, overlaysInRecording, hudHiddenFromCapture
        case trimTailSeconds, trimHeadSeconds
        case titleTemplate, deleteAfterUpload, deleteOlderThanDays, automaticUpdates
        case gifEnabled, gifFPS, gifMaxWidth, gifMaxSeconds, quality
        case telegramCompressToFit, telegramLimitMB, telegramAllowDownscale, telegramMobileFriendly
        case vimeoPrivacy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        captureMode = c.lenient(CaptureMode.self, .captureMode) ?? d.captureMode
        cameraEnabled = c.lenient(Bool.self, .cameraEnabled) ?? d.cameraEnabled
        cameraAlwaysOn = c.lenient(Bool.self, .cameraAlwaysOn) ?? d.cameraAlwaysOn
        cameraSize = c.lenient(CameraSize.self, .cameraSize) ?? d.cameraSize
        cameraCorner = c.lenient(Corner.self, .cameraCorner) ?? d.cameraCorner
        pauseEnabled = c.lenient(Bool.self, .pauseEnabled) ?? d.pauseEnabled
        systemAudioEnabled =
            c.lenient(Bool.self, .systemAudioEnabled) ?? d.systemAudioEnabled
        microphoneEnabled =
            c.lenient(Bool.self, .microphoneEnabled) ?? d.microphoneEnabled
        historyEnabled = c.lenient(Bool.self, .historyEnabled) ?? d.historyEnabled
        clickHighlightEnabled =
            c.lenient(Bool.self, .clickHighlightEnabled) ?? d.clickHighlightEnabled
        keystrokeOverlayEnabled =
            c.lenient(Bool.self, .keystrokeOverlayEnabled)
            ?? d.keystrokeOverlayEnabled
        keystrokeShortcutsOnly =
            c.lenient(Bool.self, .keystrokeShortcutsOnly) ?? d.keystrokeShortcutsOnly
        overlaysInRecording =
            c.lenient(Bool.self, .overlaysInRecording) ?? d.overlaysInRecording
        hudHiddenFromCapture =
            c.lenient(Bool.self, .hudHiddenFromCapture) ?? d.hudHiddenFromCapture
        trimTailSeconds =
            c.lenient(Double.self, .trimTailSeconds) ?? d.trimTailSeconds
        trimHeadSeconds =
            c.lenient(Double.self, .trimHeadSeconds) ?? d.trimHeadSeconds
        titleTemplate = c.lenient(String.self, .titleTemplate) ?? d.titleTemplate
        deleteAfterUpload =
            c.lenient(Bool.self, .deleteAfterUpload) ?? d.deleteAfterUpload
        deleteOlderThanDays =
            c.lenient(Int.self, .deleteOlderThanDays) ?? d.deleteOlderThanDays
        automaticUpdates =
            c.lenient(Bool.self, .automaticUpdates) ?? d.automaticUpdates
        gifEnabled = c.lenient(Bool.self, .gifEnabled) ?? d.gifEnabled
        gifFPS = c.lenient(Int.self, .gifFPS) ?? d.gifFPS
        gifMaxWidth = c.lenient(Int.self, .gifMaxWidth) ?? d.gifMaxWidth
        gifMaxSeconds = c.lenient(Int.self, .gifMaxSeconds) ?? d.gifMaxSeconds
        quality = c.lenient(RecordingQuality.self, .quality) ?? d.quality
        telegramCompressToFit =
            c.lenient(Bool.self, .telegramCompressToFit) ?? d.telegramCompressToFit
        telegramLimitMB = c.lenient(Int.self, .telegramLimitMB) ?? d.telegramLimitMB
        telegramAllowDownscale =
            c.lenient(Bool.self, .telegramAllowDownscale) ?? d.telegramAllowDownscale
        telegramMobileFriendly =
            c.lenient(Bool.self, .telegramMobileFriendly) ?? d.telegramMobileFriendly
        vimeoPrivacy = c.lenient(VimeoPrivacy.self, .vimeoPrivacy) ?? d.vimeoPrivacy
    }

    /// UserDefaults key holding the JSON-encoded settings.
    public static let storageKey = "settings.v2"
    /// Pre-v2 key holding only the `RecordingQuality`; seeds `quality` until `storageKey` exists.
    public static let legacyQualityKey = "recording.quality"

    /// Stored settings, else defaults seeded from the legacy quality key.
    /// An undecodable `settings.v2` blob is reported through `log` and falls back like an absent one.
    public static func load(
        from defaults: UserDefaults, log: (String) -> Void = { _ in }
    ) -> AppSettings {
        if let data = defaults.data(forKey: storageKey) {
            do {
                return try JSONDecoder().decode(AppSettings.self, from: data)
            } catch {
                log("settings.v2 could not be decoded, using defaults: \(error)")
            }
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

extension KeyedDecodingContainer {
    /// A missing key or a value of the wrong type/unknown enum case yields nil, so one bad field resets only itself.
    fileprivate func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
