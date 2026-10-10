import AVFoundation
import Foundation

/// Pixel size, frame rate and length of a finished recording.
public struct VideoInfo: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let fps: Double
    public let duration: TimeInterval

    public init(width: Int, height: Int, fps: Double, duration: TimeInterval) {
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
        let (size, transform, fps) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration)
        let box = CGRect(origin: .zero, size: size).applying(transform)
        return VideoInfo(
            width: Int(abs(box.width).rounded()), height: Int(abs(box.height).rounded()),
            fps: Double(fps), duration: duration.seconds)
    }
}
