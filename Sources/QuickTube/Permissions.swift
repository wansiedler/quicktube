import AVFoundation
import CoreGraphics
import Foundation

/// The TCC grants QuickTube uses. Microphone and screen recording are asked for up front instead of on
/// the first hotkey press; the camera only when the camera bubble is first turned on; Input Monitoring
/// (for the keystroke overlay) only from its Settings button.
@MainActor
enum Permissions {
    enum Status: Equatable {
        case granted
        case denied
        case notDetermined

        var label: String {
            switch self {
            case .granted: "Granted"
            case .denied: "Not granted"
            case .notDetermined: "Not asked yet"
            }
        }
    }

    private static let screenAskedKey = "permissions.screenRecordingAsked"
    private static let inputMonitoringAskedKey = "permissions.inputMonitoringAsked"
    private static let securityPane = "x-apple.systempreferences:com.apple.preference.security?"
    static let microphonePane = URL(string: securityPane + "Privacy_Microphone")!
    static let screenRecordingPane = URL(string: securityPane + "Privacy_ScreenCapture")!
    static let cameraPane = URL(string: securityPane + "Privacy_Camera")!
    static let inputMonitoringPane = URL(string: securityPane + "Privacy_ListenEvent")!

    static var microphone: Status { status(for: .audio) }

    static var camera: Status { status(for: .video) }

    private static func status(for media: AVMediaType) -> Status {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// TCC has no "undetermined" query for screen capture; remember whether we asked.
    static var screenRecording: Status {
        if CGPreflightScreenCaptureAccess() { return .granted }
        return UserDefaults.standard.bool(forKey: screenAskedKey) ? .denied : .notDetermined
    }

    /// Global key events (the keystroke overlay). Like screen capture, TCC has no "undetermined" query.
    static var inputMonitoring: Status {
        if CGPreflightListenEventAccess() { return .granted }
        return UserDefaults.standard.bool(forKey: inputMonitoringAskedKey) ? .denied : .notDetermined
    }

    /// Shows the system prompt once per install; later calls only report the state.
    static func requestInputMonitoring() -> Status {
        UserDefaults.standard.set(true, forKey: inputMonitoringAskedKey)
        _ = CGRequestListenEventAccess()
        return inputMonitoring
    }

    static func requestMicrophone() async -> Status {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return microphone
    }

    static func requestCamera() async -> Status {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return camera
    }

    /// Shows the system prompt once per install; later calls only report the state.
    static func requestScreenRecording() -> Status {
        UserDefaults.standard.set(true, forKey: screenAskedKey)
        _ = CGRequestScreenCaptureAccess()
        return screenRecording
    }

    /// First-launch sequence: microphone, then screen recording, one prompt at a time.
    static func requestMissing() async {
        if microphone == .notDetermined {
            _ = await requestMicrophone()
        }
        if screenRecording == .notDetermined {
            _ = requestScreenRecording()
        }
    }
}
