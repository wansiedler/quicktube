import AVFoundation
import Foundation

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

/// Re-encodes a recording to HEVC + AAC at a target size and bitrate (used to fit Telegram's limit).
public enum VideoTranscoder {
    /// Below this the picture falls apart regardless of size.
    public static let minimumVideoBitrate = 150_000
    /// Container overhead and encoder overshoot.
    static let headroom = 0.92
    /// Under this many bits per pixel per frame screen text smears, so the size steps down.
    static let minimumBitsPerPixel = 0.1
    static let longSideSteps = [1920, 1280, 960, 640]
    static let fallbackFPS = 30.0

    /// Pure: pick an output size and bitrates so the file fits `limitBytes` with 8 % headroom.
    /// The natural (even-rounded) size is always kept unless `allowDownscale` is true; then it is kept while the
    /// video bitrate gives at least 0.1 bit/pixel/frame, otherwise the long side steps down
    /// 1920 → 1280 → 960 → 640 (never up), keeping aspect and even dimensions.
    public static func plan(
        info: VideoInfo, limitBytes: Int, audioBitrate: Int = 96_000, allowDownscale: Bool = false
    ) -> TranscodePlan {
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

    /// AVAssetReader → AVAssetWriter (HEVC at `plan.videoBitrate`, AAC at `plan.audioBitrate`), reporting
    /// progress 0…1. Replaces `output` if it exists and removes it again on failure. Returns `output`.
    public static func transcode(
        _ input: URL, plan: TranscodePlan, output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        // Reader and writer are not Sendable; they live and die inside this detached task.
        let task = Task.detached(priority: .utility) {
            try await run(input, plan: plan, output: output, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func run(
        _ input: URL, plan: TranscodePlan, output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
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

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw TranscodeError.cannotRead }
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
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

        try? FileManager.default.removeItem(at: output)
        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else {
            throw TranscodeError.cannotWrite
        }
        writer.shouldOptimizeForNetworkUse = true
        // The plan is in display orientation; a rotated track is encoded in its natural orientation.
        let rotated = abs(transform.b) > 0.5 && abs(transform.c) > 0.5
        var compression: [String: Any] = [AVVideoAverageBitRateKey: plan.videoBitrate]
        if nominalFPS > 0 { compression[AVVideoExpectedSourceFrameRateKey] = Int(nominalFPS.rounded()) }
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: rotated ? plan.height : plan.width,
                AVVideoHeightKey: rotated ? plan.width : plan.height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: compression,
            ])
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw TranscodeError.cannotWrite }
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let aac = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: plan.audioBitrate,
                ])
            aac.expectsMediaDataInRealTime = false
            guard writer.canAdd(aac) else { throw TranscodeError.cannotWrite }
            writer.add(aac)
            audioInput = aac
        }

        guard reader.startReading() else { throw TranscodeError.cannotRead }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw TranscodeError.cannotWrite
        }
        writer.startSession(atSourceTime: .zero)

        let total = duration.seconds
        let writerBox = Unchecked(writer)
        var pumps = [
            Pump(
                output: videoOutput, input: videoInput, writer: writerBox, label: "video",
                onSample: { seconds in
                    guard total.isFinite, total > 0 else { return }
                    progress(min(0.99, max(0, seconds / total)))
                })
        ]
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
