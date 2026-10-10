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
    /// The file was not finalized in time; it is kept so the upload can still be retried.
    case stopTimedOut(file: URL)
}

/// Side effects of a finished or failed cycle: clipboard, notification.
@MainActor
public protocol Notifier: AnyObject {
    func linkReady(_ url: URL, isUnlisted: Bool)
    func failed(_ message: String)
}

/// Which step of the cycle an error came from; names it in the fallback message.
public enum Stage: Sendable {
    case recording, upload, signIn
}

/// What the UI can offer for the current failure, e.g. a link to the matching Privacy pane.
public enum FailureKind: Equatable, Sendable {
    case screenPermission
    case microphonePermission
    /// Sign-in is missing, revoked or rejected; the UI should re-check its auth state.
    case auth
    case other

    public init(_ error: Error) {
        switch error {
        case RecorderError.screenPermissionDenied: self = .screenPermission
        case RecorderError.microphonePermissionDenied: self = .microphonePermission
        case is AuthError, UploadError.unauthorized: self = .auth
        default: self = .other
        }
    }
}

/// Where a recording is uploaded to.
public enum Destination: String, Sendable, CaseIterable, Codable {
    case youtube
    case telegram

    public var label: String {
        switch self {
        case .youtube: "YouTube"
        case .telegram: "Telegram"
        }
    }
}

public enum DestinationError: Error, Equatable {
    case unavailable(Destination)
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
    /// Classifies the most recent failure; meaningful while `phase` is `.failed`.
    public private(set) var failureKind: FailureKind = .other

    /// Where the last (or current) upload went; `retry()` reuses it.
    public private(set) var destination: Destination = .youtube

    private let recorder: ScreenRecorder
    private let uploaders: [Destination: VideoUploader]
    private let notifier: Notifier
    /// Set while a transition is in flight, so a second hotkey press cannot re-enter it.
    private var busy = false

    public convenience init(
        recorder: ScreenRecorder,
        uploader: VideoUploader,
        notifier: Notifier
    ) {
        self.init(recorder: recorder, uploaders: [.youtube: uploader], notifier: notifier)
    }

    public init(
        recorder: ScreenRecorder,
        uploaders: [Destination: VideoUploader],
        notifier: Notifier
    ) {
        self.recorder = recorder
        self.uploaders = uploaders
        self.notifier = notifier
    }

    /// The hotkey action; the destination only matters when it stops a recording.
    public func toggle(destination: Destination = .youtube) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        switch phase {
        case .idle, .done, .failed:
            await startRecording()
        case .recording:
            await stopAndUpload(to: destination)
        case .uploading:
            break
        }
    }

    public func retry() async {
        guard !busy else { return }
        guard case .failed(_, let file?) = phase else { return }
        busy = true
        defer { busy = false }
        await upload(file, to: destination)
    }

    private func startRecording() async {
        do {
            try await recorder.start()
            phase = .recording
        } catch {
            fail(error, file: nil, stage: .recording)
        }
    }

    private func stopAndUpload(to destination: Destination) async {
        let file: URL
        do {
            file = try await recorder.stop()
        } catch RecorderError.stopTimedOut(let kept) {
            fail(RecorderError.stopTimedOut(file: kept), file: kept, stage: .recording)
            return
        } catch {
            fail(error, file: nil, stage: .recording)
            return
        }
        await upload(file, to: destination)
    }

    private func upload(_ file: URL, to destination: Destination) async {
        self.destination = destination
        phase = .uploading(progress: 0)
        guard let uploader = uploaders[destination] else {
            fail(DestinationError.unavailable(destination), file: file, stage: .upload)
            return
        }
        // The Recorder names files after the start time, so the stem is the recording's timestamp.
        let title = file.deletingPathExtension().lastPathComponent
        do {
            let result = try await uploader.upload(file: file, title: title) {
                value in
                Task { @MainActor in self.setProgress(value) }
            }
            let link = result.link
            lastLink = link
            phase = .done(link: link)
            notifier.linkReady(link, isUnlisted: result.isUnlisted)
        } catch {
            fail(error, file: file, stage: .upload)
        }
    }

    private func setProgress(_ value: Double) {
        guard case .uploading = phase else { return }
        phase = .uploading(progress: value)
    }

    private func fail(_ error: Error, file: URL?, stage: Stage) {
        let message = Self.message(for: error, stage: stage)
        failureKind = FailureKind(error)
        phase = .failed(message: message, file: file)
        notifier.failed(message)
    }

    public static func message(for error: Error, stage: Stage = .upload) -> String {
        switch error {
        case AuthError.notSignedIn, UploadError.unauthorized:
            return "Sign in to Google in Settings, then retry the upload."
        case DestinationError.unavailable(let destination):
            return "\(destination.label) is not set up in Settings."
        case TelegramError.notConfigured:
            return "Telegram is not set up: add the bot token and channel in Settings."
        case TelegramError.fileTooLarge(let limit, let actual):
            return "File is \(actual / (1 << 20)) MB; Telegram bots accept at most \(limit / (1 << 20)) MB."
        case TelegramError.apiError(let description):
            return "Telegram refused the upload: \(description)"
        case UploadError.apiError(let status, let message):
            if message.contains("exceeded the number of videos") {
                return "YouTube's daily upload limit for this channel is reached; "
                    + "the file is kept. Retry tomorrow."
            }
            return "Upload failed (HTTP \(status)): \(message)"
        case AuthError.missingClient:
            return "Enter and save the OAuth client ID and secret in Settings."
        case AuthError.tokenRevoked:
            return "Google sign-in expired. Sign in again in Settings."
        case AuthError.cancelled:
            return "Sign-in cancelled."
        case is CancellationError where stage == .signIn:
            return "Sign-in cancelled."
        case AuthError.timedOut:
            return "Sign-in timed out. Try again."
        case AuthError.badCallback:
            return "Sign-in failed: the browser returned an unexpected response."
        case UploadError.quotaExceeded:
            return "YouTube API quota exhausted for today. Retry tomorrow."
        case UploadError.sessionExpired:
            return "YouTube upload session expired. Retry the upload."
        case RecorderError.screenPermissionDenied:
            return "Allow Screen Recording for QuickTube in System Settings → Privacy & Security."
        case RecorderError.microphonePermissionDenied:
            return "Allow Microphone for QuickTube in System Settings → Privacy & Security."
        case RecorderError.stopTimedOut:
            return "Recording did not finalize in time; the file was kept. Try Retry Upload."
        default:
            switch stage {
            case .recording: return "Recording failed: \(error)"
            case .upload: return "Upload failed: \(error)"
            case .signIn: return "Sign-in failed: \(error)"
            }
        }
    }
}
