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
    public static let minimumVideoBitrate = 300_000
    /// Container overhead and encoder overshoot.
    static let headroom = 0.92
    /// Under this many bits per pixel per frame screen text smears, so the size steps down.
    static let minimumBitsPerPixel = 0.1
    static let longSideSteps = [1920, 1280, 960, 640]
    static let fallbackFPS = 30.0

    /// Pure: pick an output size and bitrates so the file fits `limitBytes` with 8 % headroom.
    /// The natural size is kept while the video bitrate gives at least 0.1 bit/pixel/frame;
    /// otherwise the long side steps down 1920 → 1280 → 960 → 640 (never up), keeping aspect and even dimensions.
    public static func plan(info: VideoInfo, limitBytes: Int, audioBitrate: Int = 96_000) -> TranscodePlan {
        let duration = info.duration > 0 ? info.duration : 1
        let bitsPerSecond = (Double(limitBytes) * 8 * headroom / duration).rounded(.down)
        let video = max(minimumVideoBitrate, Int(bitsPerSecond) - audioBitrate)
        let fps = info.fps.flatMap { $0 > 0 ? $0 : nil } ?? fallbackFPS
        func enough(_ size: (Int, Int)) -> Bool {
            Double(video) / (Double(size.0 * size.1) * fps) >= minimumBitsPerPixel
        }

        let longSide = max(info.width, info.height)
        var size = (evenDown(info.width), evenDown(info.height))
        if !enough(size) {
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
            throw TranscodeError.cannotRead
        }
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }),
            let (transform, nominalFPS) = try? await videoTrack.load(.preferredTransform, .nominalFrameRate),
            let reader = try? AVAssetReader(asset: asset)
        else { throw TranscodeError.cannotRead }
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
        var pumps = [
            Pump(
                output: videoOutput, input: videoInput, label: "video",
                onSample: { seconds in
                    guard total.isFinite, total > 0 else { return }
                    progress(min(0.99, max(0, seconds / total)))
                })
        ]
        if let audioOutput, let audioInput {
            pumps.append(Pump(output: audioOutput, input: audioInput, label: "audio", onSample: { _ in }))
        }
        let readerBox = Unchecked(reader)
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for pump in pumps { group.addTask { await pump.run() } }
            }
        } onCancel: {
            readerBox.value.cancelReading()
        }

        func discard() {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
        }
        if Task.isCancelled || reader.status == .cancelled {
            discard()
            throw CancellationError()
        }
        if reader.status == .failed {
            discard()
            throw TranscodeError.failed(reader.error?.localizedDescription ?? "reading failed")
        }
        if writer.status == .failed {
            discard()
            throw TranscodeError.failed(writer.error?.localizedDescription ?? "writing failed")
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

    /// Moves samples from one reader output to one writer input on its own queue until either runs dry.
    private final class Pump: @unchecked Sendable {
        private let output: AVAssetReaderOutput
        private let input: AVAssetWriterInput
        private let queue: DispatchQueue
        private let onSample: @Sendable (Double) -> Void
        /// Touched only on `queue`.
        private var finished = false

        init(
            output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String,
            onSample: @escaping @Sendable (Double) -> Void
        ) {
            self.output = output
            self.input = input
            self.queue = DispatchQueue(label: "QuickTube.transcode.\(label)")
            self.onSample = onSample
        }

        func run() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    guard !finished else { return }
                    while input.isReadyForMoreMediaData {
                        guard let sample = output.copyNextSampleBuffer() else {
                            finish(continuation)
                            return
                        }
                        guard input.append(sample) else {
                            finish(continuation)
                            return
                        }
                        onSample(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                    }
                }
            }
        }

        private func finish(_ continuation: CheckedContinuation<Void, Never>) {
            finished = true
            input.markAsFinished()
            continuation.resume()
        }
    }
}
