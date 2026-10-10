import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Records a display with microphone audio to HEVC .mp4 segments: `<date>.seg1.mp4`, `.seg2.mp4`, …
/// Pausing closes the current segment, resuming opens the next one with the same target.
public actor Recorder: ScreenRecorder {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Movies/QuickTube")

    private struct Session {
        let stream: SCStream
        let output: SCRecordingOutput
        let fileURL: URL
        let delegate: RecorderDelegate
    }

    private enum State {
        case idle
        case starting
        case recording(Session)
        case pausing
        case paused
        case resuming
        case stopping
    }

    /// The recording in progress: where it captures, its file stem, and the closed segments.
    private struct Take {
        let target: CaptureTarget
        let stem: String
        var segments: [URL] = []
    }

    private static let stopTimeout: Duration = .seconds(10)

    private let directory: URL
    private let quality: @Sendable () -> RecordingQuality
    private var state = State.idle
    private var take: Take?

    /// `quality` is read at the start of every recording, so Settings changes apply to the next one.
    public init(
        directory: URL = Recorder.defaultDirectory,
        quality: @escaping @Sendable () -> RecordingQuality = { .default }
    ) {
        self.directory = directory
        self.quality = quality
    }

    public func start(target: CaptureTarget) async throws {
        guard case .idle = state else { throw RecorderError.alreadyRecording }
        state = .starting
        let take = Take(target: target, stem: RecordingNaming.title(for: Date()))
        do {
            state = .recording(try await beginSession(take, index: 1))
            self.take = take
        } catch {
            state = .idle
            throw error
        }
    }

    /// Closes the current segment. If closing fails the recorder is still paused (the stream is gone),
    /// keeping the segment file if one was written, and the error is rethrown.
    public func pause() async throws {
        guard case .recording(let session) = state else { throw RecorderError.notRecording }
        state = .pausing
        defer { state = .paused }
        do {
            try await end(session)
            take?.segments.append(session.fileURL)
        } catch {
            if FileManager.default.fileExists(atPath: session.fileURL.path) {
                take?.segments.append(session.fileURL)
            }
            throw error
        }
    }

    public func resume() async throws {
        guard case .paused = state, let take else { throw RecorderError.notPaused }
        state = .resuming
        do {
            state = .recording(try await beginSession(take, index: take.segments.count + 1))
        } catch {
            state = .paused
            throw error
        }
    }

    /// Lets a non-Sendable SDK result cross back into the actor; it is used from the actor only.
    private struct Unchecked<Value>: @unchecked Sendable {
        let value: Value
    }

    /// Swift 6.2 refuses to hand the non-Sendable `SCShareableContent` from the SDK's async
    /// method straight into an actor; fetching it in a nonisolated helper sidesteps that.
    private nonisolated static func shareableContent() async throws -> Unchecked<SCShareableContent> {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return Unchecked(value: content)
    }

    /// Same reason: awaiting `stopCapture()` on actor-owned stream state counts as sending it.
    private nonisolated static func stopCapture(_ stream: Unchecked<SCStream>) async throws {
        try await stream.value.stopCapture()
    }

    private func beginSession(_ take: Take, index: Int) async throws -> Session {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw RecorderError.microphonePermissionDenied
        }
        let content: SCShareableContent
        do {
            content = try await Self.shareableContent().value
        } catch {
            throw RecorderError.screenPermissionDenied
        }
        guard case .display(let displayID) = take.target,
            let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first
        else { throw RecorderError.noDisplay }

        // Keep QuickTube's own windows (the status HUD) out of the recording.
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        // HEVC rejects odd dimensions.
        let quality = quality()
        let size = quality.resolution.outputSize(
            forNative: CGSize(
                width: filter.contentRect.width * scale, height: filter.contentRect.height * scale))
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(quality.fps))
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.captureMicrophone = true

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(take.stem).seg\(index).mp4")
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mp4
        recording.videoCodecType = .hevc

        let delegate = RecorderDelegate()
        let output = SCRecordingOutput(configuration: recording, delegate: delegate)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        return Session(stream: stream, output: output, fileURL: url, delegate: delegate)
    }

    /// Closes the open segment, if any, and returns every segment. A segment that does not close in time
    /// surfaces as `stopTimedOut` carrying all segments, so finishing them can be retried.
    public func stop() async throws -> [URL] {
        let session: Session?
        switch state {
        case .recording(let current): session = current
        case .paused: session = nil
        default: throw RecorderError.notRecording
        }
        state = .stopping
        var segments = take?.segments ?? []
        defer {
            state = .idle
            take = nil
        }
        guard let session else { return segments }
        do {
            try await end(session)
        } catch RecorderError.stopTimedOut {
            throw RecorderError.stopTimedOut(segments: segments + [session.fileURL])
        }
        segments.append(session.fileURL)
        return segments
    }

    /// Stops the stream and waits (bounded) until the segment file is closed.
    private func end(_ session: Session) async throws {
        try await Self.stopCapture(Unchecked(value: session.stream))
        try await session.delegate.waitUntilFinished(
            timeout: Self.stopTimeout, timeoutError: RecorderError.stopTimedOut(segments: [session.fileURL]))
    }
}

/// Bridges the delegate callbacks to one awaitable "file is closed" signal.
private final class RecorderDelegate: NSObject, SCStreamDelegate, SCRecordingOutputDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var finished = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Void, Error>?

    func waitUntilFinished(timeout: Duration, timeoutError: Error) async throws {
        let timer = Task {
            try await Task.sleep(for: timeout)
            finish(timeoutError)
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if finished {
                        if let failure {
                            continuation.resume(throwing: failure)
                        } else {
                            continuation.resume()
                        }
                    } else {
                        waiter = continuation
                    }
                }
            }
        } onCancel: {
            finish(CancellationError())
        }
    }

    private func finish(_ error: Error?) {
        lock.withLock {
            guard !finished else { return }
            finished = true
            failure = error
            if let error { waiter?.resume(throwing: error) } else { waiter?.resume() }
            waiter = nil
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { finish(nil) }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        finish(error)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { finish(error) }
}
