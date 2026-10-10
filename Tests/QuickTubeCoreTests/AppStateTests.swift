import Foundation
import QuickTubeCore
import Testing

final class FakeRecorder: ScreenRecorder, @unchecked Sendable {
    var startError: Error?
    var stopError: Error?
    var pauseError: Error?
    var resumeError: Error?
    /// What stop() returns; defaults to the single `file`.
    var segments: [URL]?
    /// A real empty file in a private temp directory, removed with the fake.
    let directory = FileManager.default.temporaryDirectory.appending(path: "qt-rec-\(UUID().uuidString)")
    var file: URL

    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appending(path: "rec.mp4")
        FileManager.default.createFile(atPath: file.path, contents: Data([0]))
    }

    deinit {
        // A test may have made the directory read-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    var starts = 0
    var stops = 0
    var pauses = 0
    var resumes = 0
    var targets: [CaptureTarget] = []
    /// While true, start() and stop() suspend after counting the call.
    var hold = false

    func start(target: CaptureTarget) async throws {
        starts += 1
        targets.append(target)
        while hold { await Task.yield() }
        if let startError { throw startError }
    }

    func pause() async throws {
        pauses += 1
        if let pauseError { throw pauseError }
    }

    func resume() async throws {
        resumes += 1
        if let resumeError { throw resumeError }
    }

    func stop() async throws -> [URL] {
        stops += 1
        while hold { await Task.yield() }
        if let stopError { throw stopError }
        return segments ?? [file]
    }
}

final class FakeFinisher: RecordingFinishing, @unchecked Sendable {
    var error: Error?
    var calls: [(segments: [URL], trim: TrimSettings, output: URL)] = []

    func finish(segments: [URL], trim: TrimSettings, output: URL) async throws -> URL {
        calls.append((segments, trim, output))
        if let error { throw error }
        return output
    }
}

/// A clock the test moves by hand.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 0)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

final class FakeUploader: VideoUploader, @unchecked Sendable {
    var result = UploadResult(videoID: "abc123", privacyStatus: "unlisted")
    var error: Error?
    var progressValues: [Double] = []
    var uploads: [(URL, String)] = []
    var contexts: [UploadContext] = []
    /// Called on the main actor after each progress value has had time to land.
    var onProgress: (@MainActor @Sendable (Double) -> Void)?
    var lastProgress: (@Sendable (Double) -> Void)?

    func upload(
        file: URL, title: String, context: UploadContext,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UploadResult {
        uploads.append((file, title))
        contexts.append(context)
        lastProgress = progress
        for value in progressValues {
            progress(value)
            for _ in 0..<5 { await Task.yield() }
            await onProgress?(value)
        }
        if let error { throw error }
        return result
    }
}

@MainActor final class FakeNotifier: Notifier {
    var links: [(URL, Bool)] = []
    var failures: [String] = []

    func linkReady(_ url: URL, isUnlisted: Bool) { links.append((url, isUnlisted)) }
    func failed(_ message: String) { failures.append(message) }
}

@MainActor final class PhaseLog {
    var phases: [Phase] = []
}

final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

@MainActor
@Suite struct AppStateTests {
    let recorder = FakeRecorder()
    let uploader = FakeUploader()
    let notifier = FakeNotifier()
    let now = Date(timeIntervalSince1970: 1_791_624_600)

    func makeState() -> AppState {
        AppState(
            recorder: recorder, uploader: uploader, notifier: notifier,
            titleProvider: { [now] in TitleContext(date: now) })
    }

    /// Where the fake recording ends up after the post-stop rename with the default template.
    var renamed: URL { recorder.directory.appending(path: RecordingNaming.fileName(for: now)) }

    @Test func toggleStartsRecording() async {
        let state = makeState()
        await state.toggle()
        #expect(state.phase == .recording)
        #expect(recorder.starts == 1)
    }

    @Test func secondToggleStopsUploadsAndPublishesLink() async {
        let state = makeState()
        await state.toggle()
        await state.toggle()
        let link = URL(string: "https://youtu.be/abc123")!
        #expect(state.phase == .done(link: link))
        #expect(state.lastLink == link)
        #expect(uploader.uploads.count == 1)
        #expect(uploader.uploads[0].0 == renamed)
        #expect(uploader.uploads[0].1 == RecordingNaming.title(for: now))
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(notifier.links.count == 1)
        #expect(notifier.links[0].1 == true)
    }

    @Test func renderedTitleNamesTheFileAndTheUpload() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "qt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorded = directory.appending(path: RecordingNaming.fileName(for: now))
        try Data([1, 2, 3]).write(to: recorded)
        recorder.file = recorded
        let context = TitleContext(
            date: now, app: "Xcode", display: "Studio Display", timeZone: TimeZone(identifier: "UTC")!)
        let state = AppState(
            recorder: recorder, uploader: uploader, notifier: notifier,
            titleProvider: { context }, titleTemplate: { "{date} {app} {display}" })
        await state.toggle()
        await state.toggle()

        let title = "2026-10-10 09.30.00 Xcode Studio Display"
        let renamed = directory.appending(path: "\(title).mp4")
        #expect(uploader.uploads.count == 1)
        #expect(uploader.uploads[0].1 == title)
        #expect(uploader.uploads[0].0 == renamed)
        #expect(uploader.contexts[0] == UploadContext(display: "Studio Display"))
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(!FileManager.default.fileExists(atPath: recorded.path))
    }

    @Test func finishFailureKeepsSegmentsAndRetryFinishesAgain() async throws {
        let lines = LogLines()
        // A read-only directory: the segment cannot be moved to its final name inside it.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: recorder.directory.path)
        let state = AppState(
            recorder: recorder, uploader: uploader, notifier: notifier,
            titleProvider: { [now] in TitleContext(date: now) }, log: { lines.append($0) })
        await state.toggle()
        await state.toggle()

        let message = "Could not finalize the recording; segments are kept in the recordings folder."
        #expect(state.phase == .failed(message: message, file: nil))
        #expect(state.canRetry)
        #expect(uploader.uploads.isEmpty)
        #expect(notifier.failures == [message])
        #expect(FileManager.default.fileExists(atPath: recorder.file.path))
        #expect(lines.all.count == 1)
        #expect(lines.all[0].contains(recorder.file.lastPathComponent))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: recorder.directory.path)
        await state.retry()
        #expect(state.phase == .done(link: URL(string: "https://youtu.be/abc123")!))
        #expect(uploader.uploads.count == 1)
        #expect(uploader.uploads[0].0 == renamed)
        #expect(uploader.uploads[0].1 == RecordingNaming.title(for: now))
        #expect(!state.canRetry)
    }

    /// On a name clash only the file name changes; the upload keeps the plain title.
    @Test func titleCollisionAppendsCounter() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "qt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([9]).write(to: directory.appending(path: "Talk.mp4"))
        let recorded = directory.appending(path: "raw.mp4")
        try Data([1]).write(to: recorded)
        recorder.file = recorded
        let state = AppState(
            recorder: recorder, uploader: uploader, notifier: notifier,
            titleProvider: { TitleContext() }, titleTemplate: { "Talk" })
        await state.toggle()
        await state.toggle()

        #expect(uploader.uploads[0].0 == directory.appending(path: "Talk (2).mp4"))
        #expect(uploader.uploads[0].1 == "Talk")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "Talk.mp4").path))
    }

    @Test func progressUpdatesPhaseWhileUploading() async {
        uploader.progressValues = [0.25, 0.75]
        let state = makeState()
        let log = PhaseLog()
        uploader.onProgress = { _ in log.phases.append(state.phase) }
        await state.toggle()
        await state.toggle()
        #expect(log.phases == [.uploading(progress: 0.25), .uploading(progress: 0.75)])
        #expect(state.phase == .done(link: URL(string: "https://youtu.be/abc123")!))
    }

    @Test func lateProgressAfterDoneIsIgnored() async {
        uploader.progressValues = [0.5]
        let state = makeState()
        await state.toggle()
        await state.toggle()
        let done = state.phase
        #expect(done == .done(link: URL(string: "https://youtu.be/abc123")!))
        uploader.lastProgress?(0.9)
        for _ in 0..<5 { await Task.yield() }
        #expect(state.phase == done)
    }

    @Test func privateUploadStillPublishesLinkWithWarning() async {
        uploader.result = UploadResult(videoID: "p1", privacyStatus: "private")
        let state = makeState()
        await state.toggle()
        await state.toggle()
        #expect(notifier.links[0].1 == false)
        #expect(state.phase == .done(link: URL(string: "https://youtu.be/p1")!))
    }

    @Test func recorderStartFailureGoesToFailedWithoutFile() async {
        recorder.startError = RecorderError.screenPermissionDenied
        let state = makeState()
        await state.toggle()
        #expect(
            state.phase
                == .failed(
                    message: AppState.message(for: RecorderError.screenPermissionDenied, stage: .recording),
                    file: nil))
        #expect(notifier.failures.count == 1)
    }

    @Test func permissionFailuresAreClassified() async {
        recorder.startError = RecorderError.screenPermissionDenied
        let state = makeState()
        await state.toggle()
        #expect(state.failureKind == .screenPermission)

        recorder.startError = RecorderError.microphonePermissionDenied
        await state.toggle()
        #expect(state.failureKind == .microphonePermission)

        recorder.startError = RecorderError.noDisplay
        await state.toggle()
        #expect(state.failureKind == .other)
    }

    @Test func authFailuresAreClassified() async {
        uploader.error = AuthError.tokenRevoked
        let state = makeState()
        await state.toggle()
        await state.toggle()
        #expect(state.failureKind == .auth)

        uploader.error = UploadError.unauthorized
        await state.retry()
        #expect(state.failureKind == .auth)

        uploader.error = UploadError.quotaExceeded
        await state.retry()
        #expect(state.failureKind == .other)
        #expect(FailureKind(AuthError.notSignedIn) == .auth)
        #expect(FailureKind(AuthError.missingClient) == .auth)
    }

    @Test func uploadFailureKeepsFileAndRetryWorks() async {
        uploader.error = UploadError.exhaustedRetries
        let state = makeState()
        await state.toggle()
        await state.toggle()
        #expect(
            state.phase
                == .failed(
                    message: "Upload failed: exhaustedRetries", file: renamed))

        uploader.error = nil
        await state.retry()
        #expect(state.phase == .done(link: URL(string: "https://youtu.be/abc123")!))
        #expect(uploader.uploads.count == 2)
    }

    @Test func retryWithoutFileIsNoop() async {
        let state = makeState()
        await state.retry()
        #expect(state.phase == .idle)
        #expect(uploader.uploads.isEmpty)
    }

    @Test func toggleIsIgnoredWhileUploading() async {
        uploader.progressValues = [0.5]
        let state = makeState()
        await state.toggle()
        async let upload: Void = state.toggle()
        for _ in 0..<100 where state.phase == .recording { await Task.yield() }
        await state.toggle()  // ignored: still uploading
        await upload
        #expect(recorder.starts == 1)
        #expect(uploader.uploads.count == 1)
    }

    @Test func stopFailureGoesToFailedWithoutUpload() async {
        recorder.stopError = RecorderError.notRecording
        let state = makeState()
        await state.toggle()
        await state.toggle()
        #expect(
            state.phase
                == .failed(message: "Recording failed: notRecording", file: nil))
        #expect(uploader.uploads.isEmpty)
        #expect(notifier.failures.count == 1)
    }

    @Test func stopTimeoutKeepsSegmentsForRetry() async {
        recorder.stopError = RecorderError.stopTimedOut(segments: [recorder.file])
        let state = makeState()
        await state.toggle()
        await state.toggle()
        #expect(
            state.phase
                == .failed(
                    message: AppState.message(for: RecorderError.stopTimedOut(segments: [])), file: nil))
        #expect(state.canRetry)
        #expect(uploader.uploads.isEmpty)

        await state.retry()
        #expect(uploader.uploads.count == 1)
        #expect(uploader.uploads[0].0 == renamed)
        #expect(state.phase == .done(link: URL(string: "https://youtu.be/abc123")!))
    }

    @Test func secondToggleWhileStartIsPendingIsIgnored() async {
        recorder.hold = true
        let state = makeState()
        async let first: Void = state.toggle()
        for _ in 0..<100 where recorder.starts == 0 { await Task.yield() }
        await state.toggle()  // ignored: start still in flight
        recorder.hold = false
        await first
        #expect(recorder.starts == 1)
        #expect(state.phase == .recording)
    }

    @Test func secondToggleWhileStopIsPendingIsIgnored() async {
        let state = makeState()
        await state.toggle()
        recorder.hold = true
        async let first: Void = state.toggle()
        for _ in 0..<100 where recorder.stops == 0 { await Task.yield() }
        await state.toggle()  // ignored: stop still in flight
        recorder.hold = false
        await first
        #expect(recorder.stops == 1)
        #expect(notifier.failures.isEmpty)
        #expect(uploader.uploads.count == 1)
        #expect(state.phase == .done(link: URL(string: "https://youtu.be/abc123")!))
    }

    @Test func toggleAfterDoneStartsAgain() async {
        let state = makeState()
        await state.toggle()
        await state.toggle()
        await state.toggle()
        #expect(state.phase == .recording)
        #expect(recorder.starts == 2)
    }

    @Test func stopHotkeyPicksTheDestination() async {
        let telegram = FakeUploader()
        telegram.result = UploadResult(link: URL(string: "https://t.me/c/1/2")!)
        let state = AppState(
            recorder: recorder, uploaders: [.youtube: uploader, .telegram: telegram], notifier: notifier)
        await state.toggle(destination: .telegram)
        await state.toggle(destination: .telegram)
        #expect(state.phase == .done(link: URL(string: "https://t.me/c/1/2")!))
        #expect(state.destination == .telegram)
        #expect(uploader.uploads.isEmpty)
        #expect(telegram.uploads.count == 1)
        #expect(notifier.links.last?.1 == true)
    }

    @Test func retryReusesTheFailedDestination() async {
        let telegram = FakeUploader()
        telegram.error = TelegramError.notConfigured
        let state = AppState(
            recorder: recorder, uploaders: [.youtube: uploader, .telegram: telegram], notifier: notifier,
            titleProvider: { [now] in TitleContext(date: now) })
        await state.toggle()
        await state.toggle(destination: .telegram)
        #expect(
            state.phase
                == .failed(message: AppState.message(for: TelegramError.notConfigured), file: renamed))
        telegram.error = nil
        telegram.result = UploadResult(link: URL(string: "https://t.me/c/1/3")!)
        await state.retry()
        #expect(state.phase == .done(link: URL(string: "https://t.me/c/1/3")!))
        #expect(uploader.uploads.isEmpty)
    }

    @Test func missingDestinationFailsWithFileKept() async {
        let state = makeState()
        await state.toggle()
        await state.toggle(destination: .telegram)
        #expect(
            state.phase
                == .failed(
                    message: AppState.message(for: DestinationError.unavailable(.telegram)),
                    file: renamed))
    }

    // MARK: - Pause, segments and the finisher

    func makePausableState(
        finisher: RecordingFinishing, trim: TrimSettings = .none, clock: ManualClock = ManualClock(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) -> AppState {
        AppState(
            recorder: recorder, uploaders: [.youtube: uploader], notifier: notifier, finisher: finisher,
            trim: { trim }, captureTarget: { .display(7) }, clock: { clock.now },
            titleProvider: { [now] in TitleContext(date: now) }, log: log)
    }

    @Test func startPassesTheCaptureTarget() async {
        let state = makePausableState(finisher: FakeFinisher())
        await state.toggle()
        #expect(recorder.targets == [.display(7)])
    }

    @Test func pauseAndResumeSwitchPhases() async {
        let state = makePausableState(finisher: FakeFinisher())
        await state.toggle()
        await state.pause()
        #expect(state.phase == .paused)
        #expect(recorder.pauses == 1)
        await state.resume()
        #expect(state.phase == .recording)
        #expect(recorder.resumes == 1)
        await state.togglePause()
        #expect(state.phase == .paused)
        await state.togglePause()
        #expect(state.phase == .recording)
        #expect(recorder.pauses == 2 && recorder.resumes == 2)
    }

    @Test func pauseAndResumeAreIgnoredInOtherPhases() async {
        let state = makePausableState(finisher: FakeFinisher())
        await state.togglePause()
        await state.pause()
        await state.resume()
        #expect(state.phase == .idle)
        await state.toggle()
        await state.resume()
        #expect(state.phase == .recording)
        #expect(recorder.pauses == 0 && recorder.resumes == 0)
    }

    @Test func stopWhilePausedFinishesAllSegmentsAndUploads() async {
        let finisher = FakeFinisher()
        let first = recorder.directory.appending(path: "x.seg1.mp4")
        let second = recorder.directory.appending(path: "x.seg2.mp4")
        recorder.segments = [first, second]
        let trim = TrimSettings(head: 0.5, tail: 1)
        let state = makePausableState(finisher: finisher, trim: trim)
        await state.toggle()
        await state.pause()
        await state.toggle(destination: .youtube)

        #expect(recorder.stops == 1)
        #expect(finisher.calls.count == 1)
        #expect(finisher.calls[0].segments == [first, second])
        #expect(finisher.calls[0].trim == trim)
        #expect(finisher.calls[0].output == renamed)
        #expect(uploader.uploads.count == 1)
        #expect(uploader.uploads[0].0 == renamed)
        #expect(state.phase == .done(link: URL(string: "https://youtu.be/abc123")!))
    }

    @Test func finisherFailureRetryRerunsTheFinisher() async {
        let finisher = FakeFinisher()
        finisher.error = RecorderError.finishFailed("export")
        let segments = [URL(fileURLWithPath: "/tmp/a.seg1.mp4"), URL(fileURLWithPath: "/tmp/a.seg2.mp4")]
        recorder.segments = segments
        let lines = LogLines()
        let state = makePausableState(finisher: finisher, log: { lines.append($0) })
        await state.toggle()
        await state.toggle()
        #expect(
            state.phase
                == .failed(
                    message: "Could not finalize the recording; segments are kept in the recordings folder.",
                    file: nil))
        #expect(state.canRetry)
        #expect(uploader.uploads.isEmpty)
        #expect(lines.all.count == 1)

        finisher.error = nil
        await state.retry()
        #expect(finisher.calls.count == 2)
        #expect(finisher.calls[1].segments == segments)
        #expect(uploader.uploads.count == 1)
        #expect(uploader.uploads[0].1 == RecordingNaming.title(for: now))
        #expect(state.phase == .done(link: URL(string: "https://youtu.be/abc123")!))
    }

    @Test func noSegmentsFailsWithoutRetry() async {
        recorder.segments = []
        let finisher = FakeFinisher()
        let state = makePausableState(finisher: finisher)
        await state.toggle()
        await state.toggle()
        #expect(finisher.calls.isEmpty)
        #expect(
            state.phase
                == .failed(
                    message: AppState.message(for: RecorderError.finishFailed("")), file: nil))
        #expect(!state.canRetry)
        await state.retry()
        #expect(finisher.calls.isEmpty)
    }

    @Test func canRetryOnlyWhenSomethingIsKept() async {
        let state = makePausableState(finisher: FakeFinisher())
        #expect(!state.canRetry)
        recorder.startError = RecorderError.noDisplay
        await state.toggle()
        #expect(!state.canRetry)
    }

    @Test func pauseFailureIsLoggedAndStillPauses() async {
        recorder.pauseError = RecorderError.stopTimedOut(segments: [])
        let lines = LogLines()
        let state = makePausableState(finisher: FakeFinisher(), log: { lines.append($0) })
        await state.toggle()
        await state.pause()
        #expect(state.phase == .paused)
        #expect(lines.all.count == 1)
        #expect(notifier.failures.isEmpty)
    }

    @Test func resumeFailureStaysPausedAndReports() async {
        recorder.resumeError = RecorderError.screenPermissionDenied
        let lines = LogLines()
        let state = makePausableState(finisher: FakeFinisher(), log: { lines.append($0) })
        await state.toggle()
        await state.pause()
        await state.resume()
        #expect(state.phase == .paused)
        #expect(notifier.failures == [AppState.message(for: RecorderError.screenPermissionDenied)])
        #expect(lines.all.count == 1)
    }

    @Test func recordedDurationExcludesPauses() async {
        let clock = ManualClock()
        let state = makePausableState(finisher: FakeFinisher(), clock: clock)
        await state.toggle()
        clock.advance(10)
        #expect(state.recordedDuration(at: clock.now) == 10)
        await state.pause()
        clock.advance(100)
        #expect(state.recordedDuration(at: clock.now) == 10)
        await state.resume()
        clock.advance(5)
        #expect(state.recordedDuration(at: clock.now) == 15)
        await state.toggle()
        #expect(state.recordedDuration(at: clock.now) == 15)
        await state.toggle()
        #expect(state.recordedDuration(at: clock.now) == 0)
    }

    @Test func messagesAreHumanReadable() {
        let signIn = "Sign in to Google in Settings, then retry the upload."
        #expect(AppState.message(for: AuthError.notSignedIn) == signIn)
        #expect(AppState.message(for: UploadError.unauthorized) == signIn)
        #expect(
            AppState.message(for: UploadError.sessionExpired)
                == "YouTube upload session expired. Retry the upload.")
        #expect(
            AppState.message(for: AuthError.tokenRevoked)
                == "Google sign-in expired. Sign in again in Settings.")
        #expect(
            AppState.message(for: UploadError.quotaExceeded)
                == "YouTube API quota exhausted for today. Retry tomorrow.")
        #expect(
            AppState.message(for: RecorderError.screenPermissionDenied)
                == "Allow Screen Recording for QuickTube in System Settings → Privacy & Security.")
        #expect(
            AppState.message(for: RecorderError.microphonePermissionDenied)
                == "Allow Microphone for QuickTube in System Settings → Privacy & Security.")
        #expect(
            AppState.message(for: AuthError.missingClient)
                == "Enter and save the OAuth client ID and secret in Settings.")
        #expect(AppState.message(for: AuthError.cancelled, stage: .signIn) == "Sign-in cancelled.")
        #expect(AppState.message(for: CancellationError(), stage: .signIn) == "Sign-in cancelled.")
        #expect(AppState.message(for: AuthError.timedOut, stage: .signIn) == "Sign-in timed out. Try again.")
        #expect(
            AppState.message(for: AuthError.badCallback, stage: .signIn)
                == "Sign-in failed: the browser returned an unexpected response.")
        #expect(
            AppState.message(for: RecorderError.stopTimedOut(segments: [URL(fileURLWithPath: "/tmp/x.mp4")]))
                == "Recording did not finalize in time; segments are kept in the recordings folder. Try Retry."
        )
        #expect(
            AppState.message(for: RecorderError.finishFailed("x"))
                == "Could not finalize the recording; segments are kept in the recordings folder.")
        // Fallback names the stage; upload is the default.
        #expect(AppState.message(for: UploadError.badResponse(500)) == "Upload failed: badResponse(500)")
        #expect(
            AppState.message(for: UploadError.badResponse(500), stage: .upload)
                == "Upload failed: badResponse(500)")
        #expect(
            AppState.message(for: RecorderError.noDisplay, stage: .recording) == "Recording failed: noDisplay"
        )
        #expect(
            AppState.message(for: AuthError.badResponse(503), stage: .signIn)
                == "Sign-in failed: badResponse(503)")
    }
}

@Suite struct TranscodeMessageTests {
    @Test(arguments: [
        (TranscodeError.cannotRead as Error, "Could not read the recording to compress it for Telegram."),
        (TranscodeError.cannotWrite as Error, "Could not write the compressed copy for Telegram."),
        (TranscodeError.failed("x") as Error, "Compressing for Telegram failed: x"),
        (
            TelegramError.fileTooLarge(limit: 50 << 20, actual: 75 << 20) as Error,
            "File is 75 MB; the Telegram limit is 50 MB (Settings → Telegram)."
        ),
        (TelegramError.apiError("Bad Request") as Error, "Telegram refused the upload: Bad Request"),
        (
            DriveError.insufficientScope as Error,
            "Google Drive access was not granted. Sign out and sign in again in Settings."
        ),
        (
            SlackError.notConfigured as Error,
            "Slack is not set up: add the bot token and channel ID in Settings."
        ),
        (SlackError.apiError("not_in_channel") as Error, "Slack refused the upload: not_in_channel"),
        (UploadError.apiError(status: 400, message: "bad") as Error, "Upload failed (HTTP 400): bad"),
        (
            UploadError.apiError(status: 400, message: "exceeded the number of videos") as Error,
            "YouTube's daily upload limit for this channel is reached; the file is kept. Retry tomorrow."
        ),
        (
            DestinationError.unavailable(.slack) as Error,
            "Slack is not set up in Settings."
        ),
        (
            DestinationError.unavailable(.drive) as Error,
            "Google Drive is not set up in Settings."
        ),
        (
            DestinationError.unavailable(.youtube) as Error,
            "YouTube is not set up in Settings."
        ),
    ])
    @MainActor func messages(error: Error, expected: String) {
        #expect(AppState.message(for: error) == expected)
    }
}
