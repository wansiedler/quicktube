import AVFoundation
import Foundation

/// Pixel size, frame rate and length of a finished recording.
public struct VideoInfo: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// nil when the file has no usable frame rate (variable-rate screen captures can report none).
    public let fps: Double?
    public let duration: TimeInterval

    public init(width: Int, height: Int, fps: Double?, duration: TimeInterval) {
        self.width = width
        self.height = height
        self.fps = fps
        self.duration = duration
    }

    public enum ReadError: Error, Equatable {
        case noVideoTrack
    }

    /// Reads the first video track; the size is the displayed one (rotation applied).
    public static func read(_ url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        guard let track = tracks.first(where: { $0.mediaType == .video }) else {
            throw ReadError.noVideoTrack
        }
        let (size, transform, nominal, minDuration) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration)
        let duration = try await asset.load(.duration)
        let (width, height) = displaySize(natural: size, transform: transform)
        return VideoInfo(
            width: width, height: height,
            fps: frameRate(nominal: nominal, minFrameDuration: minDuration),
            duration: duration.seconds)
    }

    /// The displayed size: the natural size with the track's rotation applied.
    public static func displaySize(natural: CGSize, transform: CGAffineTransform) -> (Int, Int) {
        let box = CGRect(origin: .zero, size: natural).applying(transform)
        return (Int(abs(box.width).rounded()), Int(abs(box.height).rounded()))
    }

    /// The nominal rate, else the one implied by the shortest frame duration, else nil.
    public static func frameRate(nominal: Float, minFrameDuration: CMTime) -> Double? {
        if nominal > 0 { return Double(nominal) }
        let seconds = minFrameDuration.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        return 1 / seconds
    }
}
