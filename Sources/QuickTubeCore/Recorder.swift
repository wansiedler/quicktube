import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Records the display under the cursor with microphone audio to an HEVC .mp4.
public actor Recorder: ScreenRecorder {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Movies/QuickTube")

    private let directory: URL
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var fileURL: URL?
    private let delegate = RecorderDelegate()

    public init(directory: URL = Recorder.defaultDirectory) {
        self.directory = directory
    }

    public func start() async throws {
        guard stream == nil else { throw RecorderError.alreadyRecording }
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
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
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

        delegate.reset()
        let output = SCRecordingOutput(configuration: recording, delegate: delegate)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        self.stream = stream
        self.output = output
        self.fileURL = url
    }

    public func stop() async throws -> URL {
        guard let stream, let output, let fileURL else { throw RecorderError.notRecording }
        self.stream = nil
        self.output = nil
        self.fileURL = nil
        try await stream.stopCapture()
        try await delegate.waitUntilFinished()
        try? stream.removeRecordingOutput(output)
        return fileURL
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

    func reset() {
        lock.withLock {
            finished = false
            failure = nil
            waiter = nil
        }
    }

    func waitUntilFinished() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock {
                if finished {
                    if let failure { continuation.resume(throwing: failure) } else { continuation.resume() }
                } else {
                    waiter = continuation
                }
            }
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
