import Foundation
import Observation

public protocol ScreenRecorder: Sendable {
    func start() async throws
    /// Returns the finished file.
    func stop() async throws -> URL
}

public enum RecorderError: Error, Equatable {
    case screenPermissionDenied
    case microphonePermissionDenied
    case noDisplay
    case alreadyRecording
    case notRecording
}

/// Side effects of a finished or failed cycle: clipboard, notification.
@MainActor
public protocol Notifier: AnyObject {
    func linkReady(_ url: URL, isUnlisted: Bool)
    func failed(_ message: String)
}

public enum Phase: Equatable, Sendable {
    case idle
    case recording
    case uploading(progress: Double)
    case done(link: URL)
    case failed(message: String, file: URL?)
}

/// idle → recording → uploading → done; failed keeps the file for a retry.
@MainActor
@Observable
public final class AppState {
    public private(set) var phase: Phase = .idle
    public private(set) var lastLink: URL?

    private let recorder: ScreenRecorder
    private let uploader: VideoUploader
    private let notifier: Notifier
    private let now: @Sendable () -> Date

    public init(
        recorder: ScreenRecorder,
        uploader: VideoUploader,
        notifier: Notifier,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.recorder = recorder
        self.uploader = uploader
        self.notifier = notifier
        self.now = now
    }

    /// The hotkey action.
    public func toggle() async {
        switch phase {
        case .idle, .done, .failed:
            await startRecording()
        case .recording:
            await stopAndUpload()
        case .uploading:
            break
        }
    }

    public func retry() async {
        guard case .failed(_, let file?) = phase else { return }
        await upload(file)
    }

    private func startRecording() async {
        do {
            try await recorder.start()
            phase = .recording
        } catch {
            fail(error, file: nil)
        }
    }

    private func stopAndUpload() async {
        let file: URL
        do {
            file = try await recorder.stop()
        } catch {
            fail(error, file: nil)
            return
        }
        await upload(file)
    }

    private func upload(_ file: URL) async {
        phase = .uploading(progress: 0)
        do {
            let result = try await uploader.upload(file: file, title: RecordingNaming.title(for: now())) {
                value in
                Task { @MainActor in self.setProgress(value) }
            }
            let link = ShareLink.url(forVideoID: result.videoID)
            lastLink = link
            phase = .done(link: link)
            notifier.linkReady(link, isUnlisted: result.isUnlisted)
        } catch {
            fail(error, file: file)
        }
    }

    private func setProgress(_ value: Double) {
        guard case .uploading = phase else { return }
        phase = .uploading(progress: value)
    }

    private func fail(_ error: Error, file: URL?) {
        let message = Self.message(for: error)
        phase = .failed(message: message, file: file)
        notifier.failed(message)
    }

    public static func message(for error: Error) -> String {
        switch error {
        case AuthError.notSignedIn, AuthError.missingClient, UploadError.unauthorized:
            return "Sign in to Google in Settings, then retry the upload."
        case AuthError.tokenRevoked:
            return "Google sign-in expired. Sign in again in Settings."
        case UploadError.quotaExceeded:
            return "YouTube API quota exhausted for today. Retry tomorrow."
        case UploadError.sessionExpired:
            return "YouTube upload session expired. Retry the upload."
        case RecorderError.screenPermissionDenied:
            return "Allow Screen Recording for QuickTube in System Settings → Privacy & Security."
        case RecorderError.microphonePermissionDenied:
            return "Allow Microphone for QuickTube in System Settings → Privacy & Security."
        default:
            return "Upload failed: \(error)"
        }
    }
}
