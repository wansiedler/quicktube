import Foundation
import QuickTubeCore
import Testing

final class FakeRecorder: ScreenRecorder, @unchecked Sendable {
    var startError: Error?
    var stopError: Error?
    var file = URL(fileURLWithPath: "/tmp/rec.mp4")
    var starts = 0
    var stops = 0

    func start() async throws {
        starts += 1
        if let startError { throw startError }
    }

    func stop() async throws -> URL {
        stops += 1
        if let stopError { throw stopError }
        return file
    }
}

final class FakeUploader: VideoUploader, @unchecked Sendable {
    var result = UploadResult(videoID: "abc123", privacyStatus: "unlisted")
    var error: Error?
    var progressValues: [Double] = []
    var uploads: [(URL, String)] = []

    func upload(
        file: URL, title: String, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UploadResult {
        uploads.append((file, title))
        for value in progressValues {
            progress(value)
            for _ in 0..<5 { await Task.yield() }
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

@MainActor
@Suite struct AppStateTests {
    let recorder = FakeRecorder()
    let uploader = FakeUploader()
    let notifier = FakeNotifier()
    let now = Date(timeIntervalSince1970: 1_791_624_600)

    func makeState() -> AppState {
        AppState(recorder: recorder, uploader: uploader, notifier: notifier, now: { now })
    }

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
        #expect(uploader.uploads[0].0 == recorder.file)
        #expect(uploader.uploads[0].1 == RecordingNaming.title(for: now))
        #expect(notifier.links.count == 1)
        #expect(notifier.links[0].1 == true)
    }

    @Test func progressUpdatesPhaseWhileUploading() async {
        uploader.progressValues = [0.25, 0.75]
        let state = makeState()
        await state.toggle()
        await state.toggle()
        #expect(state.phase == .done(link: URL(string: "https://youtu.be/abc123")!))
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
                    message: AppState.message(for: RecorderError.screenPermissionDenied), file: nil))
        #expect(notifier.failures.count == 1)
    }

    @Test func uploadFailureKeepsFileAndRetryWorks() async {
        uploader.error = UploadError.exhaustedRetries
        let state = makeState()
        await state.toggle()
        await state.toggle()
        #expect(
            state.phase
                == .failed(
                    message: AppState.message(for: UploadError.exhaustedRetries), file: recorder.file))

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

    @Test func toggleAfterDoneStartsAgain() async {
        let state = makeState()
        await state.toggle()
        await state.toggle()
        await state.toggle()
        #expect(state.phase == .recording)
        #expect(recorder.starts == 2)
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
        #expect(AppState.message(for: UploadError.badResponse(500)) == "Upload failed: badResponse(500)")
    }
}
