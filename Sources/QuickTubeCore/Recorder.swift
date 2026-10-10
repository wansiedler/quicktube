import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Records the display under the cursor with microphone audio to an HEVC .mp4.
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
        case stopping
    }

    private static let stopTimeout: Duration = .seconds(10)

    private let directory: URL
    private var state = State.idle

    public init(directory: URL = Recorder.defaultDirectory) {
        self.directory = directory
    }

    public func start() async throws {
        guard case .idle = state else { throw RecorderError.alreadyRecording }
        state = .starting
        do {
            state = .recording(try await beginSession())
        } catch {
            state = .idle
            throw error
        }
    }

    private func beginSession() async throws -> Session {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw RecorderError.microphonePermissionDenied
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecorderError.screenPermissionDenied
        }
        let cursor = CGEvent(source: nil)?.location ?? .zero
        guard
            let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(cursor) })
                ?? content.displays.first
        else { throw RecorderError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        // HEVC rejects odd dimensions.
        configuration.width = Int((filter.contentRect.width * scale).rounded()) & ~1
        configuration.height = Int((filter.contentRect.height * scale).rounded()) & ~1
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.captureMicrophone = true

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: RecordingNaming.fileName(for: Date()))
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

    public func stop() async throws -> URL {
        guard case .recording(let session) = state else { throw RecorderError.notRecording }
        state = .stopping
        defer { state = .idle }
        try await session.stream.stopCapture()
        try await session.delegate.waitUntilFinished(timeout: Self.stopTimeout)
        return session.fileURL
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

    func waitUntilFinished(timeout: Duration) async throws {
        let timer = Task {
            try await Task.sleep(for: timeout)
            finish(RecorderError.stopTimedOut)
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
