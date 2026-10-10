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
    case drive
    case slack

    public var label: String {
        switch self {
        case .youtube: "YouTube"
        case .telegram: "Telegram"
        case .drive: "Google Drive"
        case .slack: "Slack"
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
    private let titleProvider: @Sendable () -> TitleContext
    private let titleTemplate: @Sendable () -> String
    /// Diagnostics sink for failures that are not surfaced to the user.
    private let log: @Sendable (String) -> Void
    /// Captured when a recording starts: the app and display it was made of.
    private var titleContext = TitleContext()
    /// Title and context of the file being uploaded; `retry()` reuses them.
    private var pendingTitle: String?
    private var pendingUploadContext = UploadContext()
    /// Set while a transition is in flight, so a second hotkey press cannot re-enter it.
    private var busy = false

    public convenience init(
        recorder: ScreenRecorder,
        uploader: VideoUploader,
        notifier: Notifier,
        titleProvider: @escaping @Sendable () -> TitleContext = { TitleContext() },
        titleTemplate: @escaping @Sendable () -> String = { "{date}" },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.init(
            recorder: recorder, uploaders: [.youtube: uploader], notifier: notifier,
            titleProvider: titleProvider, titleTemplate: titleTemplate, log: log)
    }

    public init(
        recorder: ScreenRecorder,
        uploaders: [Destination: VideoUploader],
        notifier: Notifier,
        titleProvider: @escaping @Sendable () -> TitleContext = { TitleContext() },
        titleTemplate: @escaping @Sendable () -> String = { "{date}" },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.recorder = recorder
        self.uploaders = uploaders
        self.notifier = notifier
        self.titleProvider = titleProvider
        self.titleTemplate = titleTemplate
        self.log = log
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
        let context = titleProvider()
        do {
            try await recorder.start()
            titleContext = context
            phase = .recording
        } catch {
            fail(error, file: nil, stage: .recording)
        }
    }

    private func stopAndUpload(to destination: Destination) async {
        let title = RecordingNaming.render(template: titleTemplate(), context: titleContext)
        pendingTitle = title
        pendingUploadContext = UploadContext(display: titleContext.display)
        var file: URL
        do {
            file = try await recorder.stop()
        } catch RecorderError.stopTimedOut(let kept) {
            fail(RecorderError.stopTimedOut(file: kept), file: kept, stage: .recording)
            return
        } catch {
            fail(error, file: nil, stage: .recording)
            return
        }
        file = Self.rename(file, toTitle: title, log: log)
        await upload(file, to: destination)
    }

    /// Gives the finished recording its title as file name; on a name clash appends " (2)", " (3)", ….
    /// Only the file name changes: after a clash the file is "Title (2).mp4" while the upload title
    /// stays "Title". Falls back to the original file (and logs) if the rename is not possible.
    nonisolated static func rename(
        _ file: URL, toTitle title: String, log: @Sendable (String) -> Void
    ) -> URL {
        let directory = file.deletingLastPathComponent()
        let ext = file.pathExtension.isEmpty ? "mp4" : file.pathExtension
        var target = directory.appending(path: "\(title).\(ext)")
        if target == file { return file }
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appending(path: "\(title) (\(counter)).\(ext)")
            counter += 1
        }
        do {
            try FileManager.default.moveItem(at: file, to: target)
            return target
        } catch {
            log("Rename \(file.path) -> \(target.path) failed: \(error)")
            return file
        }
    }

    private func upload(_ file: URL, to destination: Destination) async {
        self.destination = destination
        phase = .uploading(progress: 0)
        guard let uploader = uploaders[destination] else {
            fail(DestinationError.unavailable(destination), file: file, stage: .upload)
            return
        }
        let title = pendingTitle ?? file.deletingPathExtension().lastPathComponent
        do {
            let result = try await uploader.upload(
                file: file, title: title, context: pendingUploadContext
            ) {
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
            return "File is \(actual / (1 << 20)) MB; the Telegram limit is \(limit / (1 << 20)) MB "
                + "(Settings → Telegram)."
        case TranscodeError.cannotRead:
            return "Could not read the recording to compress it for Telegram."
        case TranscodeError.cannotWrite:
            return "Could not write the compressed copy for Telegram."
        case TranscodeError.failed(let reason):
            return "Compressing for Telegram failed: \(reason)"
        case TelegramError.apiError(let description):
            return "Telegram refused the upload: \(description)"
        case DriveError.insufficientScope:
            return "Google Drive access was not granted. Sign out and sign in again in Settings."
        case SlackError.notConfigured:
            return "Slack is not set up: add the bot token and channel ID in Settings."
        case SlackError.apiError(let code):
            return "Slack refused the upload: \(code)"
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
