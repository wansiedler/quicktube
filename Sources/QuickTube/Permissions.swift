import AVFoundation
import CoreGraphics
import Foundation

/// The two TCC grants a recording needs, asked for up front instead of on the first hotkey press.
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
    private static let securityPane = "x-apple.systempreferences:com.apple.preference.security?"
    static let microphonePane = URL(string: securityPane + "Privacy_Microphone")!
    static let screenRecordingPane = URL(string: securityPane + "Privacy_ScreenCapture")!

    static var microphone: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
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

    static func requestMicrophone() async -> Status {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return microphone
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
