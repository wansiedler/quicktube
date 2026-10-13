import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Writes one recording segment from ScreenCaptureKit sample buffers: the screen as HEVC at a set bitrate
/// (hardware encoder, software fallback), system audio and microphone as two separate AAC tracks.
///
/// All writer state is confined to a private serial queue, so the `append` methods can be called from any
/// queue (the stream's sample handler queue in practice). The session starts at the first complete frame;
/// audio from before it is dropped. Samples the writer is not ready for are dropped and counted. An audio
/// source that changes its format mid-segment (a microphone switching from mono to stereo) is converted back
/// to its first format, since AVAssetWriter fails the whole file on such a change.
public final class RecordingWriter: @unchecked Sendable {
    /// The three kinds of sample a recording takes.
    public enum Track: Sendable {
        case screen, system, microphone
    }

    /// What a finished (or running) segment holds.
    public struct Stats: Sendable, Equatable {
        public var frames = 0
        /// Screen frames the writer was not ready for.
        public var droppedFrames = 0
        /// System audio and microphone buffers the writer was not ready for or could not convert.
        public var droppedAudio = 0
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
    private var loggedDrops: Set<Track> = []
    private var loggedFailure = false
    private var finished = false
    private var startError: Error?
    private let systemConformer = AudioConformer()
    private let microphoneConformer = AudioConformer()

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
                AVVideoColorPropertiesKey: colorProperties,
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

    /// BT.709 primaries, transfer and matrix: the capture is configured for it, and an explicit tag keeps
    /// players from guessing.
    static let colorProperties: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

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
                drop(.screen)
                return
            }
            guard inputs.video.append(sample) || retryFirstFrameInSoftware(sample, at: pts) else {
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
                drop(kind)
                return
            }
            let conformer = kind == .system ? systemConformer : microphoneConformer
            guard let conformed = conformer.conform(sample) else {
                counts.droppedAudio += 1
                logOnce(
                    kind,
                    "Recorder: \(Self.name(kind)) changed format and could not be converted, dropping it")
                return
            }
            if conformer.converted == 1 {
                log("Recorder: \(Self.name(kind)) changed format mid-segment, converting to its first format")
            }
            if !input.append(conformed) { reportFailure() }
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

    /// Runs on `queue`. The hardware encoder can also refuse the session only at the first frame (-11800
    /// ← -12903); then the segment is rebuilt once in software and the frame appended again.
    private func retryFirstFrameInSoftware(_ sample: CMSampleBuffer, at pts: CMTime) -> Bool {
        let error = inputs.writer.error
        guard counts.frames == 0,
            VideoEncoding.shouldRetryInSoftware(hardware: hardware, inputRejected: false, error: error)
        else { return false }
        inputs.writer.cancelWriting()
        log(
            "Recorder: hardware HEVC encoder refused the first frame (\(VideoEncoding.describe(error))), using software"
        )
        guard
            let rebuilt = try? Self.makeInputs(
                url: url, width: width, height: height, fps: fps, bitrate: videoBitrate,
                systemAudio: systemAudio, microphone: microphone, hardware: false)
        else { return false }
        hardware = false
        inputs = rebuilt
        startTime = nil
        guard start(at: pts) else { return false }
        return inputs.video.append(sample)
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
        startError = error ?? RecorderError.finishFailed("Writing could not start.")
        finished = true
        return false
    }

    /// Runs on `queue`.
    private var writing: Bool { inputs.writer.status == .writing }

    /// Runs on `queue`.
    private func drop(_ track: Track) {
        if track == .screen { counts.droppedFrames += 1 } else { counts.droppedAudio += 1 }
        logOnce(
            track,
            "Recorder: the writer was not ready, dropping \(Self.name(track)) samples (logged once per segment)"
        )
    }

    /// Runs on `queue`. One drop line per track and segment.
    private func logOnce(_ track: Track, _ line: String) {
        guard loggedDrops.insert(track).inserted else { return }
        log(line)
    }

    static func name(_ track: Track) -> String {
        switch track {
        case .screen: "screen"
        case .system: "system audio"
        case .microphone: "microphone"
        }
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
                if let startError {
                    throw RecorderError.finishFailed(
                        "Writing could not start: \(VideoEncoding.describe(startError))")
                }
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

    /// Runs on `queue`. The encoder (a slow software one above all) may still be busy with the last
    /// real frame, so this waits briefly for the input instead of dropping the held frame.
    private func appendTail(at stopTime: CMTime) {
        guard let lastFrame, stopTime.isValid, stopTime - lastFramePTS > Self.tailThreshold else { return }
        var waited = 0
        while !inputs.video.isReadyForMoreMediaData && waited < 200 {
            usleep(5_000)
            waited += 1
        }
        guard inputs.video.isReadyForMoreMediaData else { return }
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

    /// "Recorder: segment 2 — 1800 frames, 3 frames dropped, 0 audio buffers dropped, 30.0 s, 52.4 MB,
    /// target 14.7 Mbit/s" (MB = 10⁶ bytes).
    public static func summaryLine(segment: Int, stats: Stats, bytes: Int, bitrate: Int) -> String {
        let megabytes = String(format: "%.1f", Double(bytes) / 1_000_000)
        let mbit = String(format: "%.1f", Double(bitrate) / 1_000_000)
        return
            "Recorder: segment \(segment) — \(stats.frames) frames, \(stats.droppedFrames) frames dropped, "
            + "\(stats.droppedAudio) audio buffers dropped, \(String(format: "%.1f", stats.seconds)) s, "
            + "\(megabytes) MB, target \(mbit) Mbit/s"
    }
}

/// Keeps one audio track in the format of its first buffer. AVAssetWriter fails the whole file when a source
/// changes its channel layout mid-stream (a microphone switching from mono to stereo when a headset connects),
/// so later buffers in another PCM format are converted back with `AVAudioConverter`. Used on one queue only.
final class AudioConformer {
    private var target: AVAudioFormat?
    private var source: AVAudioFormat?
    private var converter: AVAudioConverter?
    /// Buffers converted so far.
    private(set) var converted = 0

    /// `sample` itself while it matches the first format, else a converted copy with the same timestamp;
    /// nil when it cannot be converted (not PCM, converter error).
    func conform(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let target else {
            target = format
            return sample
        }
        if format == target { return sample }
        guard let output = convert(sample, from: format, to: target) else { return nil }
        converted += 1
        return output
    }

    private func convert(_ sample: CMSampleBuffer, from format: AVAudioFormat, to target: AVAudioFormat)
        -> CMSampleBuffer?
    {
        if source != format {
            source = format
            converter = AVAudioConverter(from: format, to: target)
        }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard let converter, frames > 0,
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        // The buffer list's byte sizes follow `frameLength`, so it is set before the copy.
        input.frameLength = AVAudioFrameCount(frames)
        guard
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList) == noErr
        else { return nil }
        let ratio = target.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let feed = InputOnce(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in feed.next(status) }
        guard status != .error, output.frameLength > 0 else { return nil }
        return Self.sampleBuffer(output, at: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    /// Hands the converter its one input buffer, then reports "no data now" so it returns. The
    /// converter calls back synchronously on this queue, so the unchecked conformance is safe.
    private final class InputOnce: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let buffer else {
                status.pointee = .noDataNow
                return nil
            }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }

    static func sampleBuffer(_ buffer: AVAudioPCMBuffer, at pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: buffer.format.formatDescription, sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample)
        guard let sample,
            CMSampleBufferSetDataBufferFromAudioBufferList(
                sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
                bufferList: buffer.audioBufferList) == noErr
        else { return nil }
        return sample
    }
}
