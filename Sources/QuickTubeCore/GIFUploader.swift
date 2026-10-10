import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How a recording is turned into a GIF; read from Settings at each conversion.
public struct GIFOptions: Sendable, Equatable {
    public var fps: Int
    public var maxWidth: Int
    public var maxSeconds: Int

    public init(fps: Int, maxWidth: Int, maxSeconds: Int) {
        self.fps = fps
        self.maxWidth = maxWidth
        self.maxSeconds = maxSeconds
    }
}

public enum GIFError: Error, Equatable {
    case cannotRead
    case cannotWrite
    case noFrames
}

/// The GIF "destination": converts the recording to `<stem>.gif` next to it; the link is that file's URL.
public actor GIFUploader: VideoUploader {
    private let options: @Sendable () -> GIFOptions
    private let log: @Sendable (String) -> Void

    /// `options` is read at each conversion, so Settings changes apply to the next one.
    public init(
        options: @escaping @Sendable () -> GIFOptions,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.options = options
        self.log = log
    }

    public func upload(
        file: URL, title: String, context: UploadContext,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UploadResult {
        let options = options()
        let output = Self.outputURL(for: file)
        context.onStatus("Rendering GIF")
        progress(0)
        let log = log
        // The asset and its image generator are not Sendable; they live and die inside this detached task.
        let task = Task.detached(priority: .utility) {
            try await Self.render(file, to: output, options: options, log: log, progress: progress)
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        progress(1)
        return UploadResult(link: output)
    }

    /// `<stem>.gif` next to the recording.
    public static func outputURL(for file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("gif")
    }

    /// Frame times from the start, one every `1/fps` s, covering `min(duration, maxSeconds)`.
    public static func frameTimes(duration: Double, fps: Int, maxSeconds: Int) -> [CMTime] {
        let fps = max(1, fps)
        let span = min(duration, Double(max(1, maxSeconds)))
        guard span.isFinite, span > 0 else { return [] }
        // A tiny epsilon keeps an exact multiple (1.0 s at 10 fps) from planning one frame past the end.
        let count = Int((span * Double(fps) - 1e-9).rounded(.up))
        return (0..<max(1, count)).map { CMTime(value: CMTimeValue($0), timescale: CMTimeScale(fps)) }
    }

    /// `natural` scaled down to at most `maxWidth` wide, keeping aspect, in whole pixels; never scaled up.
    public static func outputSize(for natural: CGSize, maxWidth: Int) -> CGSize {
        let width = abs(natural.width)
        let height = abs(natural.height)
        guard width > 0, height > 0 else { return .zero }
        let targetWidth = min(width, CGFloat(max(1, maxWidth))).rounded(.down)
        let scale = targetWidth / width
        return CGSize(width: max(1, targetWidth), height: max(1, (height * scale).rounded()))
    }

    // MARK: - Rendering

    private static func render(
        _ input: URL, to output: URL, options: GIFOptions, log: @Sendable (String) -> Void,
        progress: @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: input)
        let duration: CMTime
        let natural: CGSize
        do {
            duration = try await asset.load(.duration)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw GIFError.cannotRead
            }
            let (size, transform) = try await video.load(.naturalSize, .preferredTransform)
            natural = size.applying(transform)
        } catch {
            try Task.checkCancellation()
            throw GIFError.cannotRead
        }
        let times = frameTimes(duration: duration.seconds, fps: options.fps, maxSeconds: options.maxSeconds)
        let size = outputSize(for: natural, maxWidth: options.maxWidth)
        guard !times.isEmpty, size != .zero else { throw GIFError.noFrames }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = size

        try? FileManager.default.removeItem(at: output)
        guard
            let destination = CGImageDestinationCreateWithURL(
                output as CFURL, UTType.gif.identifier as CFString, times.count, nil)
        else {
            throw GIFError.cannotWrite
        }
        CGImageDestinationSetProperties(
            destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = 1 / Double(max(1, options.fps))
        let frameProperties =
            [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay,
                ]
            ] as CFDictionary

        func discard() {
            try? FileManager.default.removeItem(at: output)
        }
        // A frame the generator cannot produce repeats a neighbouring good one, so the timing stays right.
        var last: CGImage?
        var added = 0
        var missed = 0
        for await result in generator.images(for: times) {
            if Task.isCancelled { break }
            do {
                let image = try result.image
                for _ in 0...missed { CGImageDestinationAddImage(destination, image, frameProperties) }
                added += missed + 1
                missed = 0
                last = image
            } catch {
                log("GIF: no frame at \(result.requestedTime.seconds) s: \(error)")
                missed += 1
            }
            progress(min(0.99, Double(added + missed) / Double(times.count)))
        }
        if Task.isCancelled {
            discard()
            throw CancellationError()
        }
        guard let last else {
            discard()
            throw GIFError.noFrames
        }
        for _ in 0..<missed { CGImageDestinationAddImage(destination, last, frameProperties) }
        guard CGImageDestinationFinalize(destination) else {
            discard()
            throw GIFError.cannotWrite
        }
    }
}
