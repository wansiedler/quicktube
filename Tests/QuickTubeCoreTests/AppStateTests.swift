import Foundation
import QuickTubeCore
import Testing

final class FakeRecorder: ScreenRecorder, @unchecked Sendable {
    var startError: Error?
    var stopError: Error?
    var file = URL(fileURLWithPath: "/tmp/rec.mp4")
    var starts = 0
    var stops = 0
    /// While true, start() and stop() suspend after counting the call.
    var hold = false

    func start() async throws {
        starts += 1
        while hold { await Task.yield() }
        if let startError { throw startError }
    }

    func stop() async throws -> URL {
        stops += 1
        while hold { await Task.yield() }
        if let stopError { throw stopError }
        return file
    }
}

final class FakeUploader: VideoUploader, @unchecked Sendable {
    var result = UploadResult(videoID: "abc123", privacyStatus: "unlisted")
    var error: Error?
    var progressValues: [Double] = []
    var uploads: [(URL, String)] = []
    /// Called on the main actor after each progress value has had time to land.
    var onProgress: (@MainActor @Sendable (Double) -> Void)?
    var lastProgress: (@Sendable (Double) -> Void)?

    func upload(
        file: URL, title: String, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UploadResult {
        uploads.append((file, title))
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

@MainActor
@Suite struct AppStateTests {
    let recorder = FakeRecorder()
    let uploader = FakeUploader()
    let notifier = FakeNotifier()
    let now = Date(timeIntervalSince1970: 1_791_624_600)

    func makeState() -> AppState {
        AppState(recorder: recorder, uploader: uploader, notifier: notifier)
    }

    @Test func toggleStartsRecording() async {
        let state = makeState()
        await state.toggle()
        #expect(state.phase == .recording)
        #expect(recorder.starts == 1)
    }

    @Test func secondToggleStopsUploadsAndPublishesLink() async {
        recorder.file = URL(fileURLWithPath: "/tmp").appending(path: RecordingNaming.fileName(for: now))
        let state = makeState()
        await state.toggle()
        await state.toggle()
        let link = URL(string: "https://youtu.be/abc123")!
        #expect(state.phase == .done(link: link))
        #expect(state.lastLink == link)
        #expect(uploader.uploads.count == 1)
        #expect(uploader.uploads[0].0 == recorder.file)
        // Title is the file's own stem, i.e. the recording's start timestamp.
        #expect(uploader.uploads[0].1 == recorder.file.deletingPathExtension().lastPathComponent)
        #expect(uploader.uploads[0].1 == RecordingNaming.title(for: now))
        #expect(notifier.links.count == 1)
        #expect(notifier.links[0].1 == true)
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
                    message: "Upload failed: exhaustedRetries", file: recorder.file))

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

    @Test func stopTimeoutKeepsFileForRetry() async {
        let kept = URL(fileURLWithPath: "/tmp/kept.mp4")
        recorder.stopError = RecorderError.stopTimedOut(file: kept)
        let state = makeState()
        await state.toggle()
        await state.toggle()
        #expect(
            state.phase
                == .failed(
                    message: "Recording did not finalize in time; the file was kept. Try Retry Upload.",
                    file: kept))
        #expect(uploader.uploads.isEmpty)

        await state.retry()
        #expect(uploader.uploads.count == 1)
        #expect(uploader.uploads[0].0 == kept)
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
            recorder: recorder, uploaders: [.youtube: uploader, .telegram: telegram], notifier: notifier)
        await state.toggle()
        await state.toggle(destination: .telegram)
        #expect(
            state.phase
                == .failed(message: AppState.message(for: TelegramError.notConfigured), file: recorder.file))
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
                    file: recorder.file))
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
            AppState.message(for: RecorderError.stopTimedOut(file: URL(fileURLWithPath: "/tmp/x.mp4")))
                == "Recording did not finalize in time; the file was kept. Try Retry Upload.")
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
