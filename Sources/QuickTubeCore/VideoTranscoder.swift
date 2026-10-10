import AVFoundation
import Foundation
import VideoToolbox

/// Output size and bitrates for a transcode, chosen by `VideoTranscoder.plan`.
public struct TranscodePlan: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let videoBitrate: Int
    public let audioBitrate: Int

    public init(width: Int, height: Int, videoBitrate: Int, audioBitrate: Int) {
        self.width = width
        self.height = height
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
    }
}

public enum TranscodeError: Error, Equatable {
    case cannotRead
    case cannotWrite
    case failed(String)
}

/// How a transcode treats the source audio.
public enum AudioStrategy: Sendable, Equatable {
    /// No audio track; the output has none either.
    case none
    /// One track, copied as is (no re-encode); `bitrate` is what it costs in the size budget.
    case passthrough(bitrate: Int)
    /// Several tracks (microphone + system audio), mixed and encoded to stereo 48 kHz AAC at `bitrate`.
    case mix(bitrate: Int)

    /// Bit/s the audio takes out of the size budget.
    public var bitrate: Int {
        switch self {
        case .none: 0
        case .passthrough(let bitrate), .mix(let bitrate): bitrate
        }
    }
}

/// Re-encodes a recording's video to HEVC at a target size and bitrate (used to fit Telegram's limit), keeping
/// a single audio track untouched and mixing several into one AAC track.
public enum VideoTranscoder {
    /// Below this the picture falls apart regardless of size.
    public static let minimumVideoBitrate = 150_000
    /// Container overhead and encoder overshoot.
    static let headroom = 0.92
    /// Under this many bits per pixel per frame screen text smears, so the size steps down.
    static let minimumBitsPerPixel = 0.1
    static let longSideSteps = [1920, 1280, 960, 640]
    static let fallbackFPS = 30.0
    /// AAC bitrate for a mix of several audio tracks.
    public static let mixedAudioBitrate = 160_000
    /// Budget for a passed-through track whose data rate is unknown.
    public static let passthroughFallbackBitrate = 160_000
    /// The range the AAC encoder accepts for 48 kHz stereo; a mix bitrate is clamped into it.
    static let aacBitrateRange = 64_000...320_000

    /// Pure: one track is passed through (budgeted at its estimated data rate, else 160 kbit/s), several are
    /// mixed to AAC at 160 kbit/s, none means no audio. `canPassThrough` false (a track the MP4 writer cannot
    /// take as is) mixes even a single track.
    public static func audioStrategy(
        trackCount: Int, estimatedDataRate: Float?, canPassThrough: Bool = true
    ) -> AudioStrategy {
        guard trackCount > 0 else { return .none }
        guard trackCount == 1, canPassThrough else { return .mix(bitrate: mixedAudioBitrate) }
        guard let rate = estimatedDataRate, rate.isFinite, rate > 0 else {
            return .passthrough(bitrate: passthroughFallbackBitrate)
        }
        return .passthrough(bitrate: Int(rate.rounded(.up)))
    }

    /// Requires the hardware HEVC encoder so a slow software fallback cannot happen silently; `transcode` retries
    /// without it (and logs that) when the machine has none.
    public static func encoderSpecification() -> [String: Any] {
        [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
        ]
    }

    /// "transcoded 2640 frames in 61.2 s (43 fps)".
    public static func throughputLine(frames: Int, seconds: Double) -> String {
        let fps = seconds > 0 ? Int((Double(frames) / seconds).rounded()) : 0
        return "transcoded \(frames) frames in \(String(format: "%.1f", seconds)) s (\(fps) fps)"
    }

    /// The software encoder's spec: hardware explicitly off, so "using software" is what actually happens.
    static func softwareEncoderSpecification() -> [String: Any] {
        [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]
    }

    /// The HEVC encoder settings: the bitrate and no frame reordering (no B-frame delay), since a Telegram copy
    /// only has to fit the limit, not look its best. The `hardware` encoder also gets speed over quality and a
    /// hard bitrate cap (bitrate/8 bytes per 1 s window, because the average alone overshoots at 6K). Apple's
    /// software HEVC encoder rejects both VideoToolbox keys with an uncatchable exception, so it gets only the
    /// AVFoundation ones.
    public static func compressionProperties(bitrate: Int, fps: Double, hardware: Bool) -> [String: Any] {
        var properties: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if hardware {
            properties[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = true
            properties[kVTCompressionPropertyKey_DataRateLimits as String] = [
                NSNumber(value: bitrate / 8), NSNumber(value: 1.0),
            ]
        }
        if fps > 0 { properties[AVVideoExpectedSourceFrameRateKey] = Int(fps.rounded()) }
        return properties
    }

    /// OSStatus / AVError codes that mean "this encoder cannot be used here": none on the machine
    /// (kVTCouldNotFindVideoEncoderErr -12908), none free now (kVTVideoEncoderNotAvailableNowErr -12915), no
    /// instance could be created (kVTCouldNotCreateInstanceErr -12907), or the hardware one refusing the session,
    /// as for sizes beyond its limit (kVTInvalidSessionErr -12903, seen under AVFoundation -11800).
    static let encoderUnavailableCodes: Set<Int> = [
        Int(kVTCouldNotFindVideoEncoderErr), Int(kVTVideoEncoderNotAvailableNowErr),
        Int(kVTCouldNotCreateInstanceErr), Int(kVTInvalidSessionErr),
        AVError.Code.encoderNotFound.rawValue, AVError.Code.encoderTemporarilyUnavailable.rawValue,
    ]

    /// Pure: true when `error` or one of its underlying errors says the video encoder is unavailable.
    public static func isEncoderUnavailable(_ error: Error?) -> Bool {
        var current = error.map { $0 as NSError }
        while let nsError = current {
            let osStatusLike =
                nsError.domain == NSOSStatusErrorDomain || nsError.domain == AVFoundationErrorDomain
            if osStatusLike && encoderUnavailableCodes.contains(nsError.code) { return true }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Pure: whether a failed start of the writer is retried with the software encoder. Only the hardware attempt
    /// retries, when the writer rejected its video input (the hardware settings) or `startWriting` failed with an
    /// encoder-unavailable error; the software attempt's failures are final.
    public static func shouldRetryInSoftware(hardware: Bool, inputRejected: Bool, error: Error?) -> Bool {
        hardware && (inputRejected || isEncoderUnavailable(error))
    }

    /// The error and its underlying chain as one line, e.g. "Cannot Encode (AVFoundationErrorDomain -11800
    /// ← NSOSStatusErrorDomain -12903)".
    static func describe(_ error: Error?) -> String {
        guard let error else { return "unknown error" }
        var codes: [String] = []
        var current: NSError? = error as NSError
        while let nsError = current {
            codes.append("\(nsError.domain) \(nsError.code)")
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return "\(error.localizedDescription) (\(codes.joined(separator: " ← ")))"
    }

    /// Pure: pick an output size and bitrates so the file fits `limitBytes` with 8 % headroom.
    /// The audio share is `audioBitrate` when given, else the `audioStrategy` for `info`'s audio tracks
    /// (160 kbit/s when the track count is unknown).
    /// The natural (even-rounded) size is always kept unless `allowDownscale` is true; then it is kept while the
    /// video bitrate gives at least 0.1 bit/pixel/frame, otherwise the long side steps down
    /// 1920 → 1280 → 960 → 640 (never up), keeping aspect and even dimensions.
    public static func plan(
        info: VideoInfo, limitBytes: Int, audioBitrate: Int? = nil, allowDownscale: Bool = false
    ) -> TranscodePlan {
        let audioBitrate =
            audioBitrate
            ?? info.audioTrackCount.map {
                audioStrategy(trackCount: $0, estimatedDataRate: info.audioDataRate).bitrate
            }
            ?? mixedAudioBitrate
        let duration = info.duration > 0 ? info.duration : 1
        let bitsPerSecond = (Double(limitBytes) * 8 * headroom / duration).rounded(.down)
        let video = max(minimumVideoBitrate, Int(bitsPerSecond) - audioBitrate)
        let fps = info.fps.flatMap { $0 > 0 ? $0 : nil } ?? fallbackFPS
        func enough(_ size: (Int, Int)) -> Bool {
            Double(video) / (Double(size.0 * size.1) * fps) >= minimumBitsPerPixel
        }

        let longSide = max(info.width, info.height)
        var size = (evenDown(info.width), evenDown(info.height))
        if allowDownscale && !enough(size) {
            for side in longSideSteps where side < longSide {
                size = scaled(width: info.width, height: info.height, longSide: side)
                if enough(size) { break }
            }
        }
        return TranscodePlan(width: size.0, height: size.1, videoBitrate: video, audioBitrate: audioBitrate)
    }

    private static func evenDown(_ value: Int) -> Int { max(2, value - value % 2) }

    private static func scaled(width: Int, height: Int, longSide: Int) -> (Int, Int) {
        func evenRound(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        if width >= height {
            return (longSide, evenRound(Double(height) * Double(longSide) / Double(width)))
        }
        return (evenRound(Double(width) * Double(longSide) / Double(height)), longSide)
    }

    /// AVAssetReader → AVAssetWriter, reporting progress 0…1. Video is re-encoded to HEVC at `plan.videoBitrate`;
    /// a single AAC audio track is copied untouched, several tracks are mixed to stereo 48 kHz AAC at
    /// `plan.audioBitrate` (clamped to 64–320 kbit/s). Replaces `output` if it exists and removes it again on failure. Returns `output`.
    /// `log` gets the software-encoder fallback and, on success, a throughput line (frames, seconds, fps).
    /// The hardware HEVC encoder is required first; only if the writer rejects its settings or starting it fails
    /// with an encoder-unavailable error does the transcode fall back to the software encoder (a hardware failure surfacing later, at an append,
    /// fails the transcode instead). `hardwareEncoder: false` skips the hardware attempt (tests use it to cover
    /// the software path on every host).
    public static func transcode(
        _ input: URL, plan: TranscodePlan, output: URL, hardwareEncoder: Bool = true,
        log: (@Sendable (String) -> Void)? = nil, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        // Reader and writer are not Sendable; they live and die inside this detached task.
        let task = Task.detached(priority: .utility) {
            try await run(
                input, plan: plan, output: output, hardwareEncoder: hardwareEncoder, log: log,
                progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func run(
        _ input: URL, plan: TranscodePlan, output: URL, hardwareEncoder: Bool,
        log: (@Sendable (String) -> Void)?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let clock = ContinuousClock()
        let start = clock.now
        let asset = AVURLAsset(url: input)
        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            tracks = try await asset.load(.tracks)
            duration = try await asset.load(.duration)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            throw TranscodeError.cannotRead
        }
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }),
            let (transform, nominalFPS) = try? await videoTrack.load(.preferredTransform, .nominalFrameRate),
            let reader = try? AVAssetReader(asset: asset)
        else {
            try Task.checkCancellation()
            throw TranscodeError.cannotRead
        }
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        // Only AAC goes into the MP4 untouched; anything else (LPCM in a .mov, say) is re-encoded.
        var audioFormats: [CMFormatDescription] = []
        if audioTracks.count == 1 {
            audioFormats = (try? await audioTracks[0].load(.formatDescriptions)) ?? []
        }
        let canPassThrough =
            !audioFormats.isEmpty
            && audioFormats.allSatisfy { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }
        let strategy = audioStrategy(
            trackCount: audioTracks.count, estimatedDataRate: nil, canPassThrough: canPassThrough)

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw TranscodeError.cannotRead }
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderOutput?
        switch strategy {
        case .none:
            break
        case .passthrough:
            let copy = AVAssetReaderTrackOutput(track: audioTracks[0], outputSettings: nil)
            copy.alwaysCopiesSampleData = false
            guard reader.canAdd(copy) else { throw TranscodeError.cannotRead }
            reader.add(copy)
            audioOutput = copy
        case .mix:
            let mix = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
            guard reader.canAdd(mix) else { throw TranscodeError.cannotRead }
            reader.add(mix)
            audioOutput = mix
        }

        // The plan is in display orientation; a rotated track is encoded in its natural orientation.
        let rotated = abs(transform.b) > 0.5 && abs(transform.c) > 0.5
        typealias Started = (writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput?)
        enum Attempt {
            case started(Started)
            case encoderUnavailable(String)
        }
        /// A started writer with its inputs, `.encoderUnavailable` when the hardware encoder cannot be used, or
        /// a thrown error (with the writer's reason, logged) for anything else.
        func startWriter(hardware: Bool) throws -> Attempt {
            try? FileManager.default.removeItem(at: output)
            guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else {
                throw TranscodeError.cannotWrite
            }
            writer.shouldOptimizeForNetworkUse = true
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: rotated ? plan.height : plan.width,
                AVVideoHeightKey: rotated ? plan.width : plan.height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: compressionProperties(
                    bitrate: plan.videoBitrate, fps: Double(nominalFPS), hardware: hardware),
                AVVideoEncoderSpecificationKey: hardware
                    ? encoderSpecification() : softwareEncoderSpecification(),
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            videoInput.transform = transform
            videoInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoInput) else {
                try? FileManager.default.removeItem(at: output)
                if shouldRetryInSoftware(hardware: hardware, inputRejected: true, error: nil) {
                    return .encoderUnavailable("the writer rejected the hardware HEVC settings")
                }
                log?("cannot add the HEVC video input")
                throw TranscodeError.cannotWrite
            }
            writer.add(videoInput)
            var audioInput: AVAssetWriterInput?
            switch strategy {
            case .none:
                break
            case .passthrough:
                let copy = AVAssetWriterInput(
                    mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormats.first)
                copy.expectsMediaDataInRealTime = false
                guard writer.canAdd(copy) else { throw TranscodeError.cannotWrite }
                writer.add(copy)
                audioInput = copy
            case .mix:
                let bitrate = min(
                    max(plan.audioBitrate, aacBitrateRange.lowerBound), aacBitrateRange.upperBound)
                let aac = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 2,
                        AVEncoderBitRateKey: bitrate,
                    ])
                aac.expectsMediaDataInRealTime = false
                guard writer.canAdd(aac) else { throw TranscodeError.cannotWrite }
                writer.add(aac)
                audioInput = aac
            }
            guard writer.startWriting() else {
                let error = writer.error
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: output)
                let reason = describe(error)
                if shouldRetryInSoftware(hardware: hardware, inputRejected: false, error: error) {
                    return .encoderUnavailable(reason)
                }
                log?("could not start writing: \(reason)")
                throw TranscodeError.failed(error?.localizedDescription ?? "writing could not start")
            }
            return .started((writer, videoInput, audioInput))
        }

        var attempt = try startWriter(hardware: hardwareEncoder)
        if case .encoderUnavailable(let reason) = attempt {
            log?("hardware HEVC encoder unavailable (\(reason)), using software")
            attempt = try startWriter(hardware: false)
        }
        guard case .started(let (writer, videoInput, audioInput)) = attempt else {
            throw TranscodeError.cannotWrite
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw TranscodeError.cannotRead
        }
        writer.startSession(atSourceTime: .zero)

        let total = duration.seconds
        let writerBox = Unchecked(writer)
        let videoPump = Pump(
            output: videoOutput, input: videoInput, writer: writerBox, label: "video",
            onSample: { seconds in
                guard total.isFinite, total > 0 else { return }
                progress(min(0.99, max(0, seconds / total)))
            })
        var pumps = [videoPump]
        if let audioOutput, let audioInput {
            pumps.append(
                Pump(
                    output: audioOutput, input: audioInput, writer: writerBox, label: "audio",
                    onSample: { _ in }))
        }
        // Stops every pump, including one parked waiting for `isReadyForMoreMediaData`, so the group always ends.
        let readerBox = Unchecked(reader)
        let pumpList = pumps
        let abortAll: @Sendable () -> Void = {
            readerBox.value.cancelReading()
            for pump in pumpList { pump.abort() }
        }
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for pump in pumpList { group.addTask { await pump.run(onFailure: abortAll) } }
            }
        } onCancel: {
            abortAll()
        }

        func discard() {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
        }
        if Task.isCancelled {
            discard()
            throw CancellationError()
        }
        if writer.status == .failed {
            discard()
            throw TranscodeError.failed(writer.error?.localizedDescription ?? "writing failed")
        }
        if reader.status == .failed {
            discard()
            throw TranscodeError.failed(reader.error?.localizedDescription ?? "reading failed")
        }
        if reader.status == .cancelled || writer.status != .writing {
            discard()
            throw TranscodeError.failed("transcoding stopped early")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            let reason = writer.error?.localizedDescription ?? "writing did not complete"
            try? FileManager.default.removeItem(at: output)
            throw TranscodeError.failed(reason)
        }
        progress(1)
        let elapsed = start.duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        log?(throughputLine(frames: videoPump.framesWritten, seconds: seconds))
        return output
    }

    private struct Unchecked<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// Moves samples from one reader output to one writer input on its own queue until either runs dry,
    /// the writer stops writing, or `abort()` is called.
    private final class Pump: @unchecked Sendable {
        private let output: AVAssetReaderOutput
        private let input: AVAssetWriterInput
        private let writer: Unchecked<AVAssetWriter>
        private let queue: DispatchQueue
        private let onSample: @Sendable (Double) -> Void
        /// Touched only on `queue`.
        private var finished = false
        private var continuation: CheckedContinuation<Void, Never>?
        /// Touched only on `queue`.
        private var appended = 0
        /// Samples appended so far.
        var framesWritten: Int { queue.sync { appended } }

        init(
            output: AVAssetReaderOutput, input: AVAssetWriterInput, writer: Unchecked<AVAssetWriter>,
            label: String, onSample: @escaping @Sendable (Double) -> Void
        ) {
            self.output = output
            self.input = input
            self.writer = writer
            self.queue = DispatchQueue(label: "QuickTube.transcode.\(label)")
            self.onSample = onSample
        }

        /// Returns once this track is done; `onFailure` runs when the writer rejects or stops taking samples.
        func run(onFailure: @escaping @Sendable () -> Void) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Registration, `abort()` and `finish()` all run on `queue`, so an input is never asked for
                // data after it was marked finished (AVFoundation raises on that).
                queue.sync {
                    self.continuation = continuation
                    guard !finished, writer.value.status == .writing else {
                        finish()
                        return
                    }
                    input.requestMediaDataWhenReady(on: queue) { [self] in pull(onFailure: onFailure) }
                }
            }
        }

        /// Runs on `queue`.
        private func pull(onFailure: @Sendable () -> Void) {
            guard !finished else { return }
            while input.isReadyForMoreMediaData {
                guard writer.value.status == .writing else {
                    finish()
                    onFailure()
                    return
                }
                guard let sample = output.copyNextSampleBuffer() else {
                    finish()
                    return
                }
                guard input.append(sample) else {
                    finish()
                    onFailure()
                    return
                }
                appended += 1
                onSample(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
            if writer.value.status != .writing {
                finish()
                onFailure()
            }
        }

        /// Ends `run` even if the writer never asks for more data again.
        func abort() {
            queue.async { [self] in finish() }
        }

        /// Runs on `queue`; marks the input finished once and resumes `run` if it is waiting.
        private func finish() {
            if !finished {
                finished = true
                if writer.value.status == .writing { input.markAsFinished() }
            }
            continuation?.resume()
            continuation = nil
        }
    }
}
