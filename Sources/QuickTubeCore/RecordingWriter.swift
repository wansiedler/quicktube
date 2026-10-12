import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Writes one recording segment from ScreenCaptureKit sample buffers: the screen as HEVC at a set bitrate
/// (hardware encoder, software fallback), system audio and microphone as two separate AAC tracks.
///
/// All writer state is confined to a private serial queue, so the `append` methods can be called from any
/// queue (the stream's sample handler queue in practice). The session starts at the first complete frame;
/// audio from before it is dropped. Samples the writer is not ready for are dropped and counted.
public final class RecordingWriter: @unchecked Sendable {
    /// The three kinds of sample a recording takes.
    public enum Track: Sendable {
        case screen, system, microphone
    }

    /// What a finished (or running) segment holds.
    public struct Stats: Sendable, Equatable {
        public var frames = 0
        public var dropped = 0
        public var seconds: Double = 0
    }

    /// AAC bitrates: stereo system audio, microphone.
    static let systemAudioBitrate = 160_000
    static let microphoneBitrate = 128_000
    static let audioSampleRate = 48_000
    /// A static screen sends no frames; at stop a last frame older than this is repeated at the stop time.
    static let tailThreshold = CMTime(value: 1, timescale: 2)

    private struct Inputs {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let system: AVAssetWriterInput?
        let microphone: AVAssetWriterInput?
    }

    public let url: URL
    private let width: Int
    private let height: Int
    private let fps: Int
    private let videoBitrate: Int
    private let systemAudio: Bool
    private let microphone: Bool
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "QuickTube.RecordingWriter")

    // Touched only on `queue`.
    private var hardware: Bool
    private var inputs: Inputs
    private var startTime: CMTime?
    private var lastFrame: CMSampleBuffer?
    private var lastFramePTS = CMTime.invalid
    private var counts = Stats()
    private var loggedDrop = false
    private var loggedFailure = false
    private var finished = false

    /// `hardware` false skips the hardware encoder (tests use it to cover the software path everywhere).
    /// Throws when the file cannot be created.
    public init(
        url: URL, width: Int, height: Int, fps: Int, videoBitrate: Int, systemAudio: Bool, microphone: Bool,
        hardware: Bool = true, log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        self.url = url
        self.width = width
        self.height = height
        self.fps = fps
        self.videoBitrate = videoBitrate
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.log = log
        if hardware,
            let inputs = try Self.makeInputs(
                url: url, width: width, height: height, fps: fps, bitrate: videoBitrate,
                systemAudio: systemAudio,
                microphone: microphone, hardware: true)
        {
            self.hardware = true
            self.inputs = inputs
            return
        }
        if hardware { log("Recorder: the writer rejected the hardware HEVC settings, using software") }
        guard
            let inputs = try Self.makeInputs(
                url: url, width: width, height: height, fps: fps, bitrate: videoBitrate,
                systemAudio: systemAudio, microphone: microphone, hardware: false)
        else { throw RecorderError.finishFailed("The HEVC encoder cannot write \(width)×\(height).") }
        self.hardware = false
        self.inputs = inputs
    }

    /// The writer with its inputs, or nil when it rejects the video input (the encoder settings).
    private static func makeInputs(
        url: URL, width: Int, height: Int, fps: Int, bitrate: Int, systemAudio: Bool, microphone: Bool,
        hardware: Bool
    ) throws -> Inputs? {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: VideoEncoding.compressionProperties(
                    bitrate: bitrate, fps: Double(fps), hardware: hardware, realTime: true),
                AVVideoEncoderSpecificationKey: hardware
                    ? VideoEncoding.encoderSpecification() : VideoEncoding.softwareEncoderSpecification(),
            ])
        video.expectsMediaDataInRealTime = true
        video.mediaTimeScale = 600
        guard writer.canAdd(video) else { return nil }
        writer.add(video)
        // Inputs cannot be added once writing has started, so the audio inputs are made up front: system
        // audio is captured as stereo, the microphone is encoded as mono (the input converts whatever the
        // device delivers).
        let system = systemAudio ? audioInput(channels: 2, bitrate: systemAudioBitrate) : nil
        let mic = microphone ? audioInput(channels: 1, bitrate: microphoneBitrate) : nil
        for input in [system, mic].compactMap(\.self) {
            guard writer.canAdd(input) else {
                throw RecorderError.finishFailed("The recording cannot take an audio track.")
            }
            writer.add(input)
        }
        return Inputs(writer: writer, video: video, system: system, microphone: mic)
    }

    private static func audioInput(channels: Int, bitrate: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitrate,
            ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    /// Frames written, frames dropped and the seconds covered so far.
    public var stats: Stats { queue.sync { counts } }

    /// Whether a sample of `track` would be taken now; true before the session starts (the first frame
    /// starts it).
    func isReady(for track: Track) -> Bool {
        queue.sync {
            guard startTime != nil else { return true }
            return input(for: track)?.isReadyForMoreMediaData ?? true
        }
    }

    /// Runs on `queue`.
    private func input(for track: Track) -> AVAssetWriterInput? {
        switch track {
        case .screen: inputs.video
        case .system: inputs.system
        case .microphone: inputs.microphone
        }
    }

    /// Appends a screen frame; frames ScreenCaptureKit marks as anything but complete (idle, blank, …)
    /// carry no new picture and are skipped. The first complete frame starts the session.
    public func append(screen sample: CMSampleBuffer) {
        queue.sync {
            guard !finished, Self.isCompleteFrame(sample) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if startTime == nil {
                guard start(at: pts) else { return }
            }
            guard writing else { return }
            guard inputs.video.isReadyForMoreMediaData else {
                drop("screen")
                return
            }
            guard inputs.video.append(sample) else {
                reportFailure()
                return
            }
            counts.frames += 1
            lastFrame = sample
            lastFramePTS = pts
        }
    }

    /// Appends system or microphone audio; ignored for a track the writer was made without and before the
    /// first frame.
    public func append(audio sample: CMSampleBuffer, kind: Track) {
        queue.sync {
            guard !finished, let startTime, writing, let input = input(for: kind), kind != .screen else {
                return
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts >= startTime else { return }
            guard input.isReadyForMoreMediaData else {
                drop(kind == .system ? "system audio" : "microphone")
                return
            }
            if !input.append(sample) { reportFailure() }
        }
    }

    /// Runs on `queue`. True when a frame header says it is complete; a buffer without the attachment
    /// (not from ScreenCaptureKit) counts as complete when it has a picture.
    static func isCompleteFrame(_ sample: CMSampleBuffer) -> Bool {
        guard CMSampleBufferGetImageBuffer(sample) != nil else { return false }
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int
        else { return true }
        return SCFrameStatus(rawValue: raw) == .complete
    }

    /// Runs on `queue`. Starts writing at `pts`; if the hardware encoder cannot start, rebuilds once with
    /// the software encoder. False when writing could not start (logged once).
    private func start(at pts: CMTime) -> Bool {
        if inputs.writer.startWriting() {
            inputs.writer.startSession(atSourceTime: pts)
            startTime = pts
            return true
        }
        let error = inputs.writer.error
        inputs.writer.cancelWriting()
        if VideoEncoding.shouldRetryInSoftware(hardware: hardware, inputRejected: false, error: error) {
            log(
                "Recorder: hardware HEVC encoder unavailable (\(VideoEncoding.describe(error))), using software"
            )
            if let rebuilt = try? Self.makeInputs(
                url: url, width: width, height: height, fps: fps, bitrate: videoBitrate,
                systemAudio: systemAudio, microphone: microphone, hardware: false)
            {
                hardware = false
                inputs = rebuilt
                return start(at: pts)
            }
        }
        if !loggedFailure {
            loggedFailure = true
            log("Recorder: could not start writing: \(VideoEncoding.describe(error))")
        }
        finished = true
        return false
    }

    /// Runs on `queue`.
    private var writing: Bool { inputs.writer.status == .writing }

    /// Runs on `queue`.
    private func drop(_ what: String) {
        counts.dropped += 1
        guard !loggedDrop else { return }
        loggedDrop = true
        log("Recorder: the writer was not ready, dropping \(what) samples (logged once per segment)")
    }

    /// Runs on `queue`.
    private func reportFailure() {
        guard !loggedFailure else { return }
        loggedFailure = true
        log("Recorder: writing failed: \(VideoEncoding.describe(inputs.writer.error))")
    }

    /// Closes the file. A last frame older than half a second is repeated at `stopTime` (the host time
    /// of the stop), so a still screen at the end is not cut short. Throws `RecorderError.finishFailed`
    /// when nothing was captured (the file is removed) or the writer failed.
    public func finish(at stopTime: CMTime) async throws -> URL {
        let writer = try queue.sync { () throws -> AVAssetWriter in
            let again = finished && startTime != nil && !writing
            finished = true
            guard !again else { throw RecorderError.finishFailed("The segment was already closed.") }
            guard let startTime, writing else {
                inputs.writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                if startTime == nil { throw RecorderError.finishFailed("No video frames were captured.") }
                throw RecorderError.finishFailed(VideoEncoding.describe(inputs.writer.error))
            }
            appendTail(at: stopTime)
            inputs.video.markAsFinished()
            inputs.system?.markAsFinished()
            inputs.microphone?.markAsFinished()
            let end = lastFramePTS.isValid ? max(lastFramePTS, stopTime) : stopTime
            counts.seconds = max(0, (end - startTime).seconds)
            return inputs.writer
        }
        await writer.finishWritingOnce()
        guard writer.status == .completed else {
            let reason = VideoEncoding.describe(writer.error)
            log("Recorder: finishing the segment failed: \(reason)")
            throw RecorderError.finishFailed(
                writer.error?.localizedDescription ?? "Writing the recording failed.")
        }
        return url
    }

    /// Runs on `queue`.
    private func appendTail(at stopTime: CMTime) {
        guard let lastFrame, stopTime.isValid, stopTime - lastFramePTS > Self.tailThreshold,
            inputs.video.isReadyForMoreMediaData
        else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(max(1, fps))), presentationTimeStamp: stopTime,
            decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: lastFrame, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleBufferOut: &copy)
        guard let copy, inputs.video.append(copy) else { return }
        counts.frames += 1
        lastFramePTS = stopTime
    }

    /// "Recorder: segment 2 — 1800 frames, 3 dropped, 30.0 s, 50.0 MB, target 14.7 Mbit/s".
    public static func summaryLine(
        segment: Int, frames: Int, dropped: Int, seconds: Double, bytes: Int, bitrate: Int
    ) -> String {
        let megabytes = String(format: "%.1f", Double(bytes) / 1_048_576)
        let mbit = String(format: "%.1f", Double(bitrate) / 1_000_000)
        return "Recorder: segment \(segment) — \(frames) frames, \(dropped) dropped, "
            + "\(String(format: "%.1f", seconds)) s, \(megabytes) MB, target \(mbit) Mbit/s"
    }
}
