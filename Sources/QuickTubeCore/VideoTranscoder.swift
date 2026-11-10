import AVFoundation
import Foundation
import VideoToolbox

/// The video codec a transcode writes.
public enum VideoCodec: String, Sendable, Equatable {
    /// Small files at any size; Telegram's phone apps cannot play it at 6K.
    case hevc
    /// H.264 High profile: what every phone decodes (at up to 1080p).
    case h264

    var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
    /// "HEVC" / "H.264", for log lines.
    var label: String { self == .h264 ? "H.264" : "HEVC" }
}

/// Output size, bitrates and codec for a transcode, chosen by `VideoTranscoder.plan`.
public struct TranscodePlan: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let videoBitrate: Int
    public let audioBitrate: Int
    public let codec: VideoCodec

    public init(width: Int, height: Int, videoBitrate: Int, audioBitrate: Int, codec: VideoCodec = .hevc) {
        self.width = width
        self.height = height
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
        self.codec = codec
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

/// Re-encodes a recording's video to HEVC or H.264 at a target size and bitrate (used to fit Telegram's limit
/// and to make phone-playable copies), keeping
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
    /// Long side of the mobile-friendly (H.264) copy: 1080p.
    public static let mobileMaxLongSide = 1920
    /// H.264 bitrate ceiling at 1080p up to 30 fps: keeps the copy inside High@4.0 and quick to upload.
    public static let h264MaxBitrate30 = 12_000_000
    /// H.264 bitrate ceiling at 1080p above 30 fps (High@4.2).
    public static let h264MaxBitrateHigh = 16_000_000

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

    /// "transcoded 2640 frames in 61.2 s (43 fps)".
    public static func throughputLine(frames: Int, seconds: Double) -> String {
        let fps = seconds > 0 ? Int((Double(frames) / seconds).rounded()) : 0
        return "transcoded \(frames) frames in \(String(format: "%.1f", seconds)) s (\(fps) fps)"
    }

    /// "transcoded 2640 frames in 61.2 s (43 fps), h264 1920×1080".
    public static func throughputLine(frames: Int, seconds: Double, plan: TranscodePlan) -> String {
        throughputLine(frames: frames, seconds: seconds)
            + ", \(plan.codec.rawValue) \(plan.width)×\(plan.height)"
    }

    /// Pure: pick an output size and bitrates so the file fits `limitBytes` with 8 % headroom.
    /// The audio share is `audioBitrate` when given, else the `audioStrategy` for `info`'s audio tracks
    /// (160 kbit/s when the track count is unknown).
    /// The natural (even-rounded) size is always kept unless `allowDownscale` is true; then it is kept while the
    /// video bitrate gives at least 0.1 bit/pixel/frame, otherwise the long side steps down
    /// 1920 → 1280 → 960 → 640 (never up), keeping aspect and even dimensions.
    /// `maxLongSide` caps the starting size first (see `mobileSize`), so the budget goes to the capped size;
    /// `codec` is passed through to the plan. For `.h264` the video bitrate is then capped at
    /// `h264BitrateCap` (after the size is chosen, so the cap never forces a downscale step); HEVC is uncapped.
    public static func plan(
        info: VideoInfo, limitBytes: Int, audioBitrate: Int? = nil, allowDownscale: Bool = false,
        maxLongSide: Int? = nil, codec: VideoCodec = .hevc
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

        var size = (evenDown(info.width), evenDown(info.height))
        if let maxLongSide { size = mobileSize(for: info, maxLongSide: maxLongSide) }
        let longSide = max(size.0, size.1)
        if allowDownscale && !enough(size) {
            for side in longSideSteps where side < longSide {
                size = scaled(width: info.width, height: info.height, longSide: side)
                if enough(size) { break }
            }
        }
        var videoBitrate = video
        if codec == .h264 {
            videoBitrate = min(video, h264BitrateCap(width: size.0, height: size.1, fps: fps))
        }
        return TranscodePlan(
            width: size.0, height: size.1, videoBitrate: videoBitrate, audioBitrate: audioBitrate,
            codec: codec)
    }

    /// Pure: the most an H.264 copy may use: 12 Mbit/s up to 30 fps, 16 Mbit/s above, scaled by the pixel count
    /// for sizes below 1920×1080, never below `minimumVideoBitrate`.
    public static func h264BitrateCap(width: Int, height: Int, fps: Double) -> Int {
        let base = fps > 30 ? h264MaxBitrateHigh : h264MaxBitrate30
        let share = min(1, Double(width * height) / Double(1920 * 1080))
        return max(minimumVideoBitrate, Int((Double(base) * share).rounded(.down)))
    }

    /// Pure: `info`'s size with the long side capped at `maxLongSide` (6016×3384 → 1920×1080 for 1920), aspect
    /// kept and both sides even; a smaller size is kept (even-rounded down), never upscaled.
    public static func mobileSize(for info: VideoInfo, maxLongSide: Int) -> (Int, Int) {
        guard max(info.width, info.height) > maxLongSide else {
            return (evenDown(info.width), evenDown(info.height))
        }
        return scaled(width: info.width, height: info.height, longSide: evenDown(maxLongSide))
    }

    private static func evenDown(_ value: Int) -> Int { max(2, value - value % 2) }

    private static func scaled(width: Int, height: Int, longSide: Int) -> (Int, Int) {
        func evenRound(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        if width >= height {
            return (longSide, evenRound(Double(height) * Double(longSide) / Double(width)))
        }
        return (evenRound(Double(width) * Double(longSide) / Double(height)), longSide)
    }

    /// AVAssetReader → AVAssetWriter, reporting progress 0…1. Video is re-encoded to `plan.codec` at
    /// `plan.videoBitrate`;
    /// a single AAC audio track is copied untouched, several tracks are mixed to stereo 48 kHz AAC at
    /// `plan.audioBitrate` (clamped to 64–320 kbit/s). Each attempt writes a unique `<output>.partial-<UUID>.mp4`
    /// next to `output` and moves it into place only on success, so an abandoned attempt never touches another's
    /// file. A stale `output` is removed when the writer starts, so it never outlives a failure. Returns `output`.
    /// `log` gets the software-encoder fallback and, on success, a throughput line (frames, seconds, fps, codec,
    /// size). The hardware encoder is required first; only if the writer rejects its settings or starting it fails
    /// with an encoder-unavailable error does the transcode fall back to the software encoder (a hardware failure surfacing later, at an append,
    /// fails the transcode instead). `hardwareEncoder: false` skips the hardware attempt (tests use it to cover
    /// the software path on every host).
    public static func transcode(
        _ input: URL, plan: TranscodePlan, output: URL, hardwareEncoder: Bool = true,
        log: (@Sendable (String) -> Void)? = nil, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await transcode(
            input, plan: plan, output: output, hardwareEncoder: hardwareEncoder, log: log, stage: nil,
            stallLimit: defaultStallLimit, progress: progress)
    }

    /// Points a transcode passes, in order; tests cancel at each to prove cancellation ends it.
    enum Stage: Sendable, Equatable {
        /// The source is loaded; no writer exists yet.
        case loaded
        /// The writer is started (after any software fallback); reading has not begun.
        case writerStarted
        /// The session is started; the pumps are about to run.
        case pumping
    }

    /// How long a cancelled transcode waits for its worker to wind down before giving up on it.
    static let cancelGrace: Duration = .seconds(5)
    /// The most `cancelWriting()` may take when a transcode is torn down.
    static let teardownLimit: Duration = .seconds(5)
    /// No sample on any track for this long (awake time), with the writer still writing, fails the transcode.
    static let defaultStallLimit: Duration = .seconds(60)

    /// The unique file one attempt writes before it is moved to `output`.
    static func partialURL(for output: URL) -> URL {
        output.deletingLastPathComponent().appending(
            path: "\(output.lastPathComponent).partial-\(UUID().uuidString).mp4")
    }

    /// `transcode` with a `stage` hook and a `stallLimit` (tests). Cancellation is bounded: the worker is
    /// cancelled and awaited for at most `cancelGrace`; past that its partial file is removed,
    /// `CancellationError` is thrown, and the worker is left to finish on its own (it only ever touches its
    /// own partial file, which it also removes on every exit).
    static func transcode(
        _ input: URL, plan: TranscodePlan, output: URL, hardwareEncoder: Bool,
        log: (@Sendable (String) -> Void)?, stage: (@Sendable (Stage) -> Void)?, stallLimit: Duration,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let partial = partialURL(for: output)
        // Reader and writer are not Sendable; they live and die inside this detached task.
        let task = Task.detached(priority: .utility) {
            try await run(
                input, plan: plan, output: output, partial: partial, hardwareEncoder: hardwareEncoder,
                log: log,
                stage: stage, stallLimit: stallLimit, progress: progress)
        }
        return try await awaitBounded(task, grace: cancelGrace) {
            try? FileManager.default.removeItem(at: partial)
            log?("transcode did not stop within \(cancelGrace) of cancellation; abandoned it")
        }
    }

    /// Awaits `task`. Once the caller is cancelled, `task` is cancelled too and awaited for at most `grace`;
    /// past that `onAbandon` runs and only then is `CancellationError` thrown, while `task` winds down on its
    /// own.
    static func awaitBounded<T: Sendable>(
        _ task: Task<T, Error>, grace: Duration, onAbandon: @escaping @Sendable () -> Void
    ) async throws -> T {
        let gate = ResultGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                gate.install(continuation)
                Task.detached { gate.deliver(await task.result) }
            }
        } onCancel: {
            task.cancel()
            Task.detached {
                try? await Task.sleep(for: grace)
                gate.deliver(.failure(CancellationError()), beforeResume: onAbandon)
            }
        }
    }

    /// Resumes one continuation exactly once with the first delivered result, whether that arrives before or
    /// after the continuation is installed; later results are ignored.
    final class ResultGate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var pending: Result<T, Error>?
        private var delivered = false

        func install(_ continuation: CheckedContinuation<T, Error>) {
            let ready = lock.withLock { () -> Result<T, Error>? in
                guard let pending else {
                    self.continuation = continuation
                    return nil
                }
                self.pending = nil
                return pending
            }
            if let ready { continuation.resume(with: ready) }
        }

        /// Claims the gate for `result`; when this is the first result, `beforeResume` runs, then the
        /// continuation is resumed (or the result kept until `install`). True when this result was delivered.
        @discardableResult
        func deliver(_ result: Result<T, Error>, beforeResume: (() -> Void)? = nil) -> Bool {
            let first = lock.withLock { () -> Bool in
                guard !delivered else { return false }
                delivered = true
                return true
            }
            guard first else { return false }
            beforeResume?()
            let waiting = lock.withLock { () -> CheckedContinuation<T, Error>? in
                defer { continuation = nil }
                if continuation == nil { pending = result }
                return continuation
            }
            waiting?.resume(with: result)
            return true
        }
    }

    private static func run(
        _ input: URL, plan: TranscodePlan, output: URL, partial: URL, hardwareEncoder: Bool,
        log: (@Sendable (String) -> Void)?, stage: (@Sendable (Stage) -> Void)?, stallLimit: Duration,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        // Whatever happens, this attempt's partial file does not outlive it (after success it is already moved).
        defer { try? FileManager.default.removeItem(at: partial) }
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
        stage?(.loaded)
        // A transcode cancelled before the writer exists never creates (or replaces) the output.
        try Task.checkCancellation()

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
            try? FileManager.default.removeItem(at: partial)
            guard let writer = try? AVAssetWriter(outputURL: partial, fileType: .mp4) else {
                throw TranscodeError.cannotWrite
            }
            writer.shouldOptimizeForNetworkUse = true
            let settings: [String: Any] = [
                AVVideoCodecKey: plan.codec.avCodec,
                AVVideoWidthKey: rotated ? plan.height : plan.width,
                AVVideoHeightKey: rotated ? plan.width : plan.height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: VideoEncoding.compressionProperties(
                    bitrate: plan.videoBitrate, fps: Double(nominalFPS), hardware: hardware,
                    codec: plan.codec),
                AVVideoEncoderSpecificationKey: hardware
                    ? VideoEncoding.encoderSpecification() : VideoEncoding.softwareEncoderSpecification(),
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            videoInput.transform = transform
            videoInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoInput) else {
                try? FileManager.default.removeItem(at: partial)
                if VideoEncoding.shouldRetryInSoftware(hardware: hardware, inputRejected: true, error: nil) {
                    return .encoderUnavailable(
                        "the writer rejected the hardware \(plan.codec.label) settings")
                }
                log?("cannot add the \(plan.codec.label) video input")
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
                // Synchronous on purpose: this writer never started, so cancelling it returns at once.
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: partial)
                let reason = VideoEncoding.describe(error)
                if VideoEncoding.shouldRetryInSoftware(hardware: hardware, inputRejected: false, error: error)
                {
                    return .encoderUnavailable(reason)
                }
                log?("could not start writing: \(reason)")
                throw TranscodeError.failed(error?.localizedDescription ?? "writing could not start")
            }
            return .started((writer, videoInput, audioInput))
        }

        // A stale output from an earlier transcode must not outlive this one if it fails.
        try? FileManager.default.removeItem(at: output)
        var attempt = try startWriter(hardware: hardwareEncoder)
        if case .encoderUnavailable(let reason) = attempt {
            // Cancelled while the hardware attempt failed: nothing is started, so there is nothing to undo.
            try Task.checkCancellation()
            log?("hardware \(plan.codec.label) encoder unavailable (\(reason)), using software")
            attempt = try startWriter(hardware: false)
        }
        guard case .started(let (writer, videoInput, audioInput)) = attempt else {
            throw TranscodeError.cannotWrite
        }
        let writerBox = Unchecked(writer)
        /// Cancels the writer (bounded by `teardownLimit`; a stuck one is logged and left) and removes this
        /// attempt's partial file.
        func discard() async {
            let stopped = await cancelWritingBounded(writerBox)
            if !stopped {
                log?("cancelWriting did not return within \(teardownLimit); partial file removed anyway")
            }
            try? FileManager.default.removeItem(at: partial)
        }
        stage?(.writerStarted)
        if Task.isCancelled {
            await discard()
            throw CancellationError()
        }
        guard reader.startReading() else {
            await discard()
            throw TranscodeError.cannotRead
        }
        writer.startSession(atSourceTime: .zero)
        stage?(.pumping)

        let total = duration.seconds
        let activity = Activity()
        let videoPump = Pump(
            output: videoOutput, input: videoInput, writer: writerBox, label: "video", activity: activity,
            log: log,
            onSample: { seconds in
                guard total.isFinite, total > 0 else { return }
                progress(min(0.99, max(0, seconds / total)))
            })
        var pumps = [videoPump]
        if let audioOutput, let audioInput {
            pumps.append(
                Pump(
                    output: audioOutput, input: audioInput, writer: writerBox, label: "audio",
                    activity: activity,
                    log: log, onSample: { _ in }))
        }
        // Stops every pump, including one parked waiting for `isReadyForMoreMediaData`, so the group always ends.
        let readerBox = Unchecked(reader)
        let pumpList = pumps
        let abortAll: @Sendable () -> Void = {
            readerBox.value.cancelReading()
            for pump in pumpList { pump.abort() }
        }
        let watchdog = Watchdog(
            writer: writerBox, activity: activity, stallLimit: stallLimit, log: log, onTrip: abortAll)
        watchdog.start()
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for pump in pumpList { group.addTask { await pump.run(onFailure: abortAll) } }
            }
        } onCancel: {
            abortAll()
        }
        watchdog.stop()

        // Never `finishWriting` after a cancel: the writer is cancelled instead, and nothing waits on it unbounded.
        if Task.isCancelled {
            await discard()
            throw CancellationError()
        }
        if writer.status == .failed {
            let reason = writer.error?.localizedDescription ?? "writing failed"
            await discard()
            throw TranscodeError.failed(reason)
        }
        if reader.status == .failed {
            await discard()
            throw TranscodeError.failed(reader.error?.localizedDescription ?? "reading failed")
        }
        if reader.status == .cancelled || writer.status != .writing {
            await discard()
            throw TranscodeError.failed("transcoding stopped early")
        }
        await writer.finishWritingOnce()
        // Cancelled while finishing (the caller may already have given up): the partial file is dropped (defer).
        try Task.checkCancellation()
        guard writer.status == .completed else {
            throw TranscodeError.failed(writer.error?.localizedDescription ?? "writing did not complete")
        }
        do {
            if FileManager.default.fileExists(atPath: output.path) {
                _ = try FileManager.default.replaceItemAt(output, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: output)
            }
        } catch {
            log?("could not move the transcode into place: \(error.localizedDescription)")
            throw TranscodeError.cannotWrite
        }
        progress(1)
        let elapsed = start.duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        log?(throughputLine(frames: activity.appended("video"), seconds: seconds, plan: plan))
        return output
    }

    /// `cancelWriting()` off the cooperative pool, awaited for at most `teardownLimit`; false when it overran
    /// (it then finishes on its own).
    private static func cancelWritingBounded(_ writer: Unchecked<AVAssetWriter>) async -> Bool {
        struct Overran: Error {}
        do {
            try await Deadline.run(timeout: teardownLimit, error: Overran()) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global(qos: .utility).async {
                        writer.value.cancelWriting()
                        continuation.resume()
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    private struct Unchecked<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// When any pump last appended a sample, and how many each appended. Stall time is measured on
    /// `SuspendingClock`, so time the Mac spends asleep never counts as a stall.
    private final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private let clock = SuspendingClock()
        private var last: SuspendingClock.Instant
        private var counts: [String: Int] = [:]

        init() { last = clock.now }

        func touch(_ label: String) {
            lock.withLock {
                last = clock.now
                counts[label, default: 0] += 1
            }
        }

        /// Awake time since any pump last appended.
        var idle: Duration { lock.withLock { last.duration(to: clock.now) } }

        func appended(_ label: String) -> Int { lock.withLock { counts[label] ?? 0 } }

        /// "video 12, audio 30".
        var summary: String {
            lock.withLock {
                counts.sorted { $0.key > $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            }
        }
    }

    /// Watches one transcode from its own queue and stops every pump (`onTrip`, once) when the writer leaves
    /// `.writing` (`requestMediaDataWhenReady` never calls back after that) or no pump appended anything for
    /// `stallLimit` while the writer still writes. Pumps waiting on each other (interleaving) do not count as
    /// a stall as long as one of them moves.
    private final class Watchdog: @unchecked Sendable {
        static let interval: DispatchTimeInterval = .milliseconds(250)

        private let writer: Unchecked<AVAssetWriter>
        private let activity: Activity
        private let stallLimit: Duration
        private let log: (@Sendable (String) -> Void)?
        private let onTrip: @Sendable () -> Void
        private let queue = DispatchQueue(label: "QuickTube.transcode.watchdog")
        // Touched only on `queue`.
        private var timer: DispatchSourceTimer?
        private var tripped = false

        init(
            writer: Unchecked<AVAssetWriter>, activity: Activity, stallLimit: Duration,
            log: (@Sendable (String) -> Void)?, onTrip: @escaping @Sendable () -> Void
        ) {
            self.writer = writer
            self.activity = activity
            self.stallLimit = stallLimit
            self.log = log
            self.onTrip = onTrip
        }

        func start() {
            queue.sync {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(
                    deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(100))
                timer.setEventHandler { [self] in check() }
                self.timer = timer
                timer.resume()
            }
        }

        func stop() {
            queue.sync {
                timer?.cancel()
                timer = nil
            }
        }

        /// Runs on `queue`.
        private func check() {
            guard !tripped else { return }
            let writer = writer.value
            if writer.status != .writing {
                trip(
                    "writer left writing (status \(writer.status.rawValue): "
                        + "\(VideoEncoding.describe(writer.error))); appended \(activity.summary)")
            } else if activity.idle > stallLimit {
                trip(
                    "no sample on any track for \(stallLimit), writer still writing; appended \(activity.summary)"
                )
            }
        }

        /// Runs on `queue`.
        private func trip(_ reason: String) {
            tripped = true
            timer?.cancel()
            timer = nil
            log?("transcode watchdog stopped the pumps: \(reason)")
            onTrip()
        }
    }

    /// Moves samples from one reader output to one writer input on its own queue until either runs dry,
    /// the writer stops writing, or `abort()` is called (by cancellation, a sibling's failure or the
    /// `Watchdog`).
    private final class Pump: @unchecked Sendable {
        private let output: AVAssetReaderOutput
        private let input: AVAssetWriterInput
        private let writer: Unchecked<AVAssetWriter>
        private let label: String
        private let activity: Activity
        private let log: (@Sendable (String) -> Void)?
        private let queue: DispatchQueue
        private let onSample: @Sendable (Double) -> Void
        // Touched only on `queue`.
        private var finished = false
        private var continuation: CheckedContinuation<Void, Never>?

        init(
            output: AVAssetReaderOutput, input: AVAssetWriterInput, writer: Unchecked<AVAssetWriter>,
            label: String, activity: Activity, log: (@Sendable (String) -> Void)?,
            onSample: @escaping @Sendable (Double) -> Void
        ) {
            self.output = output
            self.input = input
            self.writer = writer
            self.label = label
            self.activity = activity
            self.log = log
            self.queue = DispatchQueue(label: "QuickTube.transcode.\(label)")
            self.onSample = onSample
        }

        /// Returns once this track is done; `onFailure` runs when the writer rejects or stops taking samples.
        func run(onFailure: @escaping @Sendable () -> Void) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Registration, `abort()` and `finish()` all run on `queue`, so an input is never asked for
                // data after it was marked finished (AVFoundation raises on that), and the continuation is
                // resumed exactly once.
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
                    fail("the writer left writing", onFailure)
                    return
                }
                guard let sample = output.copyNextSampleBuffer() else {
                    finish()
                    return
                }
                guard input.append(sample) else {
                    fail("an append was rejected", onFailure)
                    return
                }
                activity.touch(label)
                onSample(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
            if writer.value.status != .writing {
                fail("the writer left writing", onFailure)
            }
        }

        /// Runs on `queue`.
        private func fail(_ reason: String, _ onFailure: @Sendable () -> Void) {
            let writer = writer.value
            log?(
                "\(label) pump stopped: \(reason) (writer status \(writer.status.rawValue): "
                    + "\(VideoEncoding.describe(writer.error)))")
            finish()
            onFailure()
        }

        /// Ends `run` even if the writer never asks for more data again.
        func abort() {
            queue.async { [self] in finish() }
        }

        /// Runs on `queue`; marks the input finished once and resumes `run` once.
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
