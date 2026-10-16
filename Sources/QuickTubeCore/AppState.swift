import Foundation
import Observation

/// A recording is a list of segments: pausing closes one, resuming opens the next.
public protocol ScreenRecorder: Sendable {
    func start(target: CaptureTarget) async throws
    /// Closes the current segment. `RecorderError.notRecording` unless recording.
    func pause() async throws
    /// Opens a new segment with the same target. `RecorderError.notPaused` unless paused.
    func resume() async throws
    /// Returns the segment files, in order; works while recording or paused.
    func stop() async throws -> [URL]
}

public enum RecorderError: Error, Equatable {
    case screenPermissionDenied
    case microphonePermissionDenied
    case noDisplay
    /// The window chosen for a window recording is no longer on screen.
    case windowGone
    case alreadyRecording
    case notRecording
    case notPaused
    /// The last segment was not finalized in time; all segments are kept so finishing can be retried.
    case stopTimedOut(segments: [URL])
    /// Joining or trimming the segments failed; the segments are kept.
    case finishFailed(String)
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
    case vimeo
    /// Not an upload: a GIF next to the recording; the link is its file URL.
    case gif
    /// Not an upload: the recording stays where it is; the link is its file URL.
    case local

    public var label: String {
        switch self {
        case .youtube: "YouTube"
        case .telegram: "Telegram"
        case .drive: "Google Drive"
        case .slack: "Slack"
        case .vimeo: "Vimeo"
        case .gif: "GIF"
        case .local: "Save only"
        }
    }
}

/// One successful upload, as listed under "Recent Links".
public struct HistoryItem: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let link: URL
    public let destination: Destination
    public let date: Date
    public let title: String

    public init(id: UUID = UUID(), link: URL, destination: Destination, date: Date, title: String) {
        self.id = id
        self.link = link
        self.destination = destination
        self.date = date
        self.title = title
    }
}

public enum DestinationError: Error, Equatable {
    case unavailable(Destination)
}

public enum Phase: Equatable, Sendable {
    case idle
    case recording
    case paused
    case uploading(progress: Double)
    case done(link: URL)
    case failed(message: String, file: URL?)
}

/// An upload that keeps running after the hotkey started the next recording.
public struct BackgroundUpload: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let destination: Destination
    /// Stage text as in `AppState.uploadStage`.
    public var stage: String
    public var progress: Double
    public let file: URL

    public init(id: UUID = UUID(), destination: Destination, stage: String, progress: Double, file: URL) {
        self.id = id
        self.destination = destination
        self.stage = stage
        self.progress = progress
        self.file = file
    }
}

/// The newest background upload that failed; `retry()` uploads its file again once nothing else is shown.
public struct BackgroundFailure: Sendable, Equatable {
    public let message: String
    public let file: URL
    public let destination: Destination
    public let title: String
    public let display: String?
}

/// idle → recording ⇄ paused → (finish) → uploading → done; failed keeps the file or the segments for a retry.
/// The hotkey during an upload moves it to `backgroundUploads` and starts the next recording.
@MainActor
@Observable
public final class AppState {
    public private(set) var phase: Phase = .idle
    public private(set) var lastLink: URL?
    /// Classifies the most recent failure; meaningful while `phase` is `.failed`.
    public private(set) var failureKind: FailureKind = .other

    /// Where the last (or current) upload went; `retry()` reuses it.
    public private(set) var destination: Destination = .youtube
    /// Current upload stage text: "Uploading", or "Compressing · details" while a copy is made.
    public private(set) var uploadStage: String = "Uploading"
    /// What the current (or last) recording captures; set just before the recorder starts.
    public private(set) var recordingTarget: CaptureTarget?
    /// True while the recorder is starting, after `onRecordingWillStart` ran and before `phase` settles.
    public private(set) var isStarting = false
    /// Called right before the recorder starts, once the target is known, so windows that belong in the
    /// recording (the camera bubble) can already be on screen for its first frame.
    @ObservationIgnored public var onRecordingWillStart: (@MainActor (CaptureTarget) -> Void)?

    /// Uploads that run on while `phase` shows something else, oldest first.
    public private(set) var backgroundUploads: [BackgroundUpload] = []
    /// Kept until `retry()` uploads it again; a newer background failure replaces it.
    public private(set) var lastBackgroundFailure: BackgroundFailure?

    /// The last `Self.historyLimit` successful uploads, newest first.
    public private(set) var history: [HistoryItem]
    public static let historyLimit = 20

    private let recorder: ScreenRecorder
    private let uploaders: [Destination: VideoUploader]
    private let notifier: Notifier
    private let finisher: RecordingFinishing
    private let trim: @Sendable () -> TrimSettings
    private let captureTarget: @Sendable () -> CaptureTarget
    /// Shows the area/window selection in the select capture modes.
    private let picker: CaptureTargetPicker?
    private let captureMode: @Sendable () -> CaptureMode
    private let clock: @Sendable () -> Date
    private let titleProvider: @Sendable () -> TitleContext
    private let titleTemplate: @Sendable () -> String
    /// Diagnostics sink for failures that are not surfaced to the user.
    private let log: @Sendable (String) -> Void
    private let historyEnabled: @Sendable () -> Bool
    /// Called with the whole list after every change, so the app can persist it.
    private let onHistoryChange: (@MainActor @Sendable ([HistoryItem]) -> Void)?
    /// Called once per successful upload with the uploaded file; a failure is logged, never surfaced.
    private let afterUpload: (@Sendable (URL) throws -> Void)?
    /// Captured when a recording starts: the app and display it was made of.
    private var titleContext = TitleContext()
    /// Title and context of the file being uploaded; `retry()` reuses them.
    private var pendingTitle: String?
    private var pendingUploadContext = UploadContext()
    /// Segments of a recording whose finishing failed; `retry()` finishes them again.
    private var pendingSegments: [URL]?
    /// Recorded time before the current stretch, and when that stretch began (nil while paused).
    private var recordedBefore: TimeInterval = 0
    private var stretchStart: Date?
    /// The upload `phase` shows; nil once it ended or moved to `backgroundUploads`.
    private var foregroundUpload: BackgroundUpload?
    /// Set while a recording transition is in flight, so a second hotkey press cannot re-enter it.
    /// Uploads run outside it: the hotkey can start the next recording while one is in progress.
    private var busy = false

    public convenience init(
        recorder: ScreenRecorder,
        uploader: VideoUploader,
        notifier: Notifier,
        finisher: RecordingFinishing = RecordingFinisher(),
        trim: @escaping @Sendable () -> TrimSettings = { .none },
        titleProvider: @escaping @Sendable () -> TitleContext = { TitleContext() },
        titleTemplate: @escaping @Sendable () -> String = { "{date}" },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.init(
            recorder: recorder, uploaders: [.youtube: uploader], notifier: notifier, finisher: finisher,
            trim: trim, titleProvider: titleProvider, titleTemplate: titleTemplate, log: log)
    }

    /// `trim`, `captureMode` and `captureTarget` are read at stop and start, so Settings changes apply to the
    /// next recording. In the select modes `picker` chooses the target; without one `captureTarget` is used.
    public init(
        recorder: ScreenRecorder,
        uploaders: [Destination: VideoUploader],
        notifier: Notifier,
        finisher: RecordingFinishing = RecordingFinisher(),
        trim: @escaping @Sendable () -> TrimSettings = { .none },
        captureTarget: @escaping @Sendable () -> CaptureTarget = { CaptureTarget.displayUnderCursor() },
        picker: CaptureTargetPicker? = nil,
        captureMode: @escaping @Sendable () -> CaptureMode = { .displayUnderCursor },
        clock: @escaping @Sendable () -> Date = { Date() },
        titleProvider: @escaping @Sendable () -> TitleContext = { TitleContext() },
        titleTemplate: @escaping @Sendable () -> String = { "{date}" },
        log: @escaping @Sendable (String) -> Void = { _ in },
        history: [HistoryItem] = [],
        historyEnabled: @escaping @Sendable () -> Bool = { true },
        onHistoryChange: (@MainActor @Sendable ([HistoryItem]) -> Void)? = nil,
        afterUpload: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.afterUpload = afterUpload
        self.history = Array(history.prefix(Self.historyLimit))
        self.historyEnabled = historyEnabled
        self.onHistoryChange = onHistoryChange
        self.recorder = recorder
        self.uploaders = uploaders
        self.notifier = notifier
        self.finisher = finisher
        self.trim = trim
        self.captureTarget = captureTarget
        self.picker = picker
        self.captureMode = captureMode
        self.clock = clock
        self.titleProvider = titleProvider
        self.titleTemplate = titleTemplate
        self.log = log
    }

    /// True while `.failed` left something `retry()` can pick up: a file to upload or segments to finish.
    public var canRetry: Bool {
        guard case .failed(_, let file) = phase else { return false }
        return file != nil || pendingSegments != nil
    }

    /// Recorded time of the current recording at `now`, excluding pauses.
    public func recordedDuration(at now: Date) -> TimeInterval {
        let running = stretchStart.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return recordedBefore + running
    }

    /// True while a background upload failed and nothing else is shown, so `retry()` can re-run it.
    public var canRetryBackgroundFailure: Bool {
        guard lastBackgroundFailure != nil else { return false }
        switch phase {
        case .idle, .done: return true
        default: return false
        }
    }

    /// The hotkey action; the destination only matters when it stops a recording. During an upload it
    /// starts a new recording and the upload carries on in `backgroundUploads`.
    public func toggle(destination: Destination = .youtube) async {
        guard !busy else { return }
        busy = true
        switch phase {
        case .idle, .done, .failed, .uploading:
            moveUploadToBackground()
            await startRecording()
            busy = false
        case .recording, .paused:
            let file = await stopAndFinish()
            // The upload can take minutes; the hotkey must be able to start the next recording meanwhile.
            busy = false
            if let file { await upload(file, to: destination) }
        }
    }

    /// Hands the foreground upload over to `backgroundUploads` with its current stage and progress.
    private func moveUploadToBackground() {
        guard var upload = foregroundUpload, case .uploading(let progress) = phase else { return }
        upload.stage = uploadStage
        upload.progress = progress
        backgroundUploads.append(upload)
        foregroundUpload = nil
        phase = .idle
    }

    /// The pause hotkey: pauses while recording, resumes while paused, otherwise does nothing.
    public func togglePause() async {
        switch phase {
        case .recording: await pause()
        case .paused: await resume()
        default: break
        }
    }

    /// Closes the current segment. A failure is logged and still ends in `.paused`: the stream is gone
    /// either way, and stopping from `.paused` hands whatever was recorded to the finisher.
    public func pause() async {
        guard !busy, phase == .recording else { return }
        busy = true
        defer { busy = false }
        do {
            try await recorder.pause()
        } catch {
            log("Pause failed: \(error)")
        }
        recordedBefore = recordedDuration(at: clock())
        stretchStart = nil
        phase = .paused
    }

    /// Opens a new segment. On failure the recording stays paused (it can still be stopped) and the
    /// error is reported.
    public func resume() async {
        guard !busy, phase == .paused else { return }
        busy = true
        defer { busy = false }
        do {
            try await recorder.resume()
            stretchStart = clock()
            phase = .recording
        } catch {
            log("Resume failed: \(error)")
            notifier.failed(Self.message(for: error, stage: .recording))
        }
    }

    /// Retries the failed cycle; without one, the last failed background upload (see `canRetryBackgroundFailure`).
    public func retry() async {
        guard !busy else { return }
        guard case .failed(_, let file) = phase else {
            await retryLastBackgroundFailure()
            return
        }
        busy = true
        let ready: URL?
        if let segments = pendingSegments {
            ready = await finish(segments)
        } else {
            ready = file
        }
        busy = false
        if let ready { await upload(ready, to: destination) }
    }

    /// Uploads the file of the last failed background upload again, as a foreground upload.
    public func retryLastBackgroundFailure() async {
        guard !busy, canRetryBackgroundFailure, let failure = lastBackgroundFailure else { return }
        lastBackgroundFailure = nil
        await upload(
            failure.file, to: failure.destination, title: failure.title,
            context: UploadContext(display: failure.display))
    }

    /// In the select modes the picker runs first; cancelling it returns to `.idle` without a notification.
    private func startRecording() async {
        let context = titleProvider()
        let target: CaptureTarget
        if let picker, case let mode = captureMode(), mode != .displayUnderCursor {
            guard let picked = await picker.pick(mode: mode) else {
                phase = .idle
                return
            }
            target = picked
        } else {
            target = captureTarget()
        }
        recordingTarget = target
        isStarting = true
        onRecordingWillStart?(target)
        defer { isStarting = false }
        do {
            try await recorder.start(target: target)
            titleContext = context
            pendingSegments = nil
            recordedBefore = 0
            stretchStart = clock()
            phase = .recording
        } catch {
            fail(error, file: nil, stage: .recording)
        }
    }

    /// Stops the recorder and finishes the segments; nil after a failure, which is already reported.
    private func stopAndFinish() async -> URL? {
        pendingTitle = RecordingNaming.render(template: titleTemplate(), context: titleContext)
        pendingUploadContext = UploadContext(display: titleContext.display)
        recordedBefore = recordedDuration(at: clock())
        stretchStart = nil
        let segments: [URL]
        do {
            segments = try await recorder.stop()
        } catch {
            // The segments survive a timeout; finishing them may work once the last one is closed.
            if case RecorderError.stopTimedOut(let kept) = error { pendingSegments = kept }
            fail(error, file: nil, stage: .recording)
            return nil
        }
        return await finish(segments)
    }

    /// Joins and trims the segments into `<recordings folder>/<title>.mp4` and returns that file.
    /// On failure the segments are remembered so `retry()` can finish them again.
    private func finish(_ segments: [URL]) async -> URL? {
        guard let first = segments.first else {
            pendingSegments = nil
            fail(RecorderError.finishFailed("No segments were recorded."), file: nil, stage: .recording)
            return nil
        }
        let title = pendingTitle ?? RecordingNaming.title(for: titleContext.date)
        let output = Self.availableURL(in: first.deletingLastPathComponent(), title: title)
        let file: URL
        do {
            file = try await finisher.finish(segments: segments, trim: trim(), output: output)
        } catch {
            log("Finishing \(segments.map(\.lastPathComponent)) failed: \(error)")
            pendingSegments = segments
            fail(error, file: nil, stage: .recording)
            return nil
        }
        pendingSegments = nil
        return file
    }

    /// `<title>.mp4` in `directory`; on a name clash " (2)", " (3)", … is appended. Only the file name
    /// changes: after a clash the file is "Title (2).mp4" while the upload title stays "Title".
    nonisolated static func availableURL(in directory: URL, title: String) -> URL {
        var target = directory.appending(path: "\(title).mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appending(path: "\(title) (\(counter)).mp4")
            counter += 1
        }
        return target
    }

    /// Starts as the foreground upload; if the hotkey moves it to `backgroundUploads` meanwhile, it ends
    /// there: the link is copied and announced as usual, but the phase only changes when nothing else shows.
    private func upload(
        _ file: URL, to destination: Destination, title: String? = nil, context: UploadContext? = nil
    ) async {
        self.destination = destination
        let id = UUID()
        foregroundUpload = BackgroundUpload(
            id: id, destination: destination, stage: "Uploading", progress: 0, file: file)
        uploadStage = "Uploading"
        phase = .uploading(progress: 0)
        let title = title ?? pendingTitle ?? file.deletingPathExtension().lastPathComponent
        var context = context ?? pendingUploadContext
        // `retry()` of this upload reuses them, also when they were passed in (a background failure's retry).
        pendingTitle = title
        pendingUploadContext = UploadContext(display: context.display)
        guard let uploader = uploaders[destination] else {
            uploadFailed(
                id, error: DestinationError.unavailable(destination), file: file, destination: destination,
                title: title, display: context.display)
            return
        }
        do {
            context.onStatus = { stage in
                Task { @MainActor in self.setStage(stage, upload: id) }
            }
            let result = try await uploader.upload(
                file: file, title: title, context: context
            ) {
                value in
                Task { @MainActor in self.setProgress(value, upload: id) }
            }
            let link = result.link
            lastLink = link
            if foregroundUpload?.id == id {
                foregroundUpload = nil
                phase = .done(link: link)
            } else {
                backgroundUploads.removeAll { $0.id == id }
                // Not while a recording is starting (`busy`), nor over a recording, upload or failure on
                // screen: the notification carries the link.
                switch phase {
                case .idle, .done:
                    if !busy {
                        self.destination = destination
                        phase = .done(link: link)
                    }
                default:
                    break
                }
            }
            record(link: link, destination: destination, title: title)
            notifier.linkReady(link, isUnlisted: result.isUnlisted)
            // A GIF is made from the recording and "Save only" keeps it; neither uploaded the recording.
            if destination != .gif, destination != .local { runAfterUpload(file) }
        } catch {
            uploadFailed(
                id, error: error, file: file, destination: destination, title: title, display: context.display
            )
        }
    }

    /// A foreground failure ends in `.failed` as before; a background one is announced and remembered for
    /// `retry()`, and the phase stays as it is.
    private func uploadFailed(
        _ id: UUID, error: Error, file: URL, destination: Destination, title: String, display: String?
    ) {
        if foregroundUpload?.id == id {
            foregroundUpload = nil
            fail(error, file: file, stage: .upload)
            return
        }
        backgroundUploads.removeAll { $0.id == id }
        let message = Self.message(for: error, stage: .upload)
        log("Background upload of \(file.lastPathComponent) to \(destination.label) failed: \(error)")
        lastBackgroundFailure = BackgroundFailure(
            message: message, file: file, destination: destination, title: title, display: display)
        notifier.failed(message)
    }

    private func runAfterUpload(_ file: URL) {
        guard let afterUpload else { return }
        do {
            try afterUpload(file)
        } catch {
            log("Cleanup after upload of \(file.lastPathComponent) failed: \(error)")
        }
    }

    private func record(link: URL, destination: Destination, title: String) {
        guard historyEnabled() else { return }
        let item = HistoryItem(link: link, destination: destination, date: clock(), title: title)
        history = Array(([item] + history).prefix(Self.historyLimit))
        onHistoryChange?(history)
    }

    public func clearHistory() {
        history = []
        onHistoryChange?(history)
    }

    /// The HUD's done line: "GIF ready · 1.5 MB" for a GIF, "Saved · 1.5 MB" for a local save,
    /// otherwise "Link copied · host/path".
    public static func doneText(link: URL, destination: Destination) -> String {
        let prefix: String
        switch destination {
        case .gif where link.isFileURL: prefix = "GIF ready"
        case .local where link.isFileURL: prefix = "Saved"
        default: return "Link copied · \(link.host ?? "")\(link.path)"
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: link.path)[.size] as? Int) ?? 0
        let megabytes = Double(bytes) / Double(1 << 20)
        let size = megabytes.formatted(
            .number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US_POSIX")))
        return "\(prefix) · \(size) MB"
    }

    /// "Compressing · details" at 21% → "Compressing 21% · details"; a plain stage → "Uploading 60%".
    public static func uploadText(stage: String, progress: Double) -> String {
        let percent = "\(Int(progress * 100))%"
        guard let split = stage.range(of: " · ") else { return "\(stage) \(percent)" }
        return "\(stage[..<split.lowerBound]) \(percent) · \(stage[split.upperBound...])"
    }

    /// "Uploading to Telegram 43%, YouTube 10% in background"; nil without background uploads.
    public static func backgroundStatus(_ uploads: [BackgroundUpload]) -> String? {
        guard !uploads.isEmpty else { return nil }
        let parts = uploads.map { "\($0.destination.label) \(Int($0.progress * 100))%" }
        return "Uploading to \(parts.joined(separator: ", ")) in background"
    }

    /// Updates whichever upload `id` is: the foreground one in `phase`, or its background entry. A late
    /// callback from an upload that already ended matches neither and is dropped.
    private func setStage(_ stage: String, upload id: UUID) {
        // Progress is per stage: a new stage starts again at 0.
        if foregroundUpload?.id == id, case .uploading = phase {
            uploadStage = stage
            phase = .uploading(progress: 0)
        } else if let index = backgroundUploads.firstIndex(where: { $0.id == id }) {
            backgroundUploads[index].stage = stage
            backgroundUploads[index].progress = 0
        }
    }

    private func setProgress(_ value: Double, upload id: UUID) {
        if foregroundUpload?.id == id, case .uploading = phase {
            phase = .uploading(progress: value)
        } else if let index = backgroundUploads.firstIndex(where: { $0.id == id }) {
            backgroundUploads[index].progress = value
        }
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
        case TelegramError.network(let description):
            return "Could not reach Telegram: \(description)"
        case TelegramError.apiError(let description):
            return "Telegram refused the upload: \(description)"
        case DriveError.insufficientScope:
            return "Google Drive access was not granted. Sign out and sign in again in Settings."
        case SlackError.notConfigured:
            return "Slack is not set up: add the bot token and channel ID in Settings."
        case SlackError.apiError(let code):
            return "Slack refused the upload: \(code)"
        case VimeoError.notConfigured:
            return "Vimeo is not set up: add the access token in Settings."
        case VimeoError.apiError(_, let message):
            return "Vimeo: \(message)"
        case VimeoError.uploadIncomplete(let offset, let size):
            return
                "Vimeo: the upload stopped at \(offset / (1 << 20)) of \(size / (1 << 20)) MB. Retry the upload."
        case VimeoError.badResponse(let status):
            return "Vimeo: unexpected response (HTTP \(status))."
        case GIFError.cannotRead:
            return "Could not read the recording to make a GIF."
        case GIFError.cannotWrite:
            return "Could not write the GIF next to the recording."
        case GIFError.noFrames:
            return "The recording has no frames to make a GIF from."
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
        case RecorderError.windowGone:
            return "The chosen window is gone."
        case RecorderError.stopTimedOut:
            return
                "Recording did not finalize in time; segments are kept in the recordings folder. Try Retry."
        case RecorderError.finishFailed:
            return "Could not finalize the recording; segments are kept in the recordings folder."
        default:
            // An error's description can embed a request URL or header; never show a token on screen.
            let text = VimeoUploader.redact(TelegramUploader.redact("\(error)"))
            switch stage {
            case .recording: return "Recording failed: \(text)"
            case .upload: return "Upload failed: \(text)"
            case .signIn: return "Sign-in failed: \(text)"
            }
        }
    }
}
