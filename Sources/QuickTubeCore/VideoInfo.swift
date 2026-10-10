import AVFoundation
import Foundation

/// Pixel size, frame rate, length and audio layout of a finished recording.
public struct VideoInfo: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// nil when the file has no usable frame rate (variable-rate screen captures can report none).
    public let fps: Double?
    public let duration: TimeInterval
    /// Number of audio tracks; nil when unknown (then a transcode plan reserves room for mixed audio).
    public let audioTrackCount: Int?
    /// The estimated data rate (bit/s) of the audio track when there is exactly one, else nil.
    public let audioDataRate: Float?

    public init(
        width: Int, height: Int, fps: Double?, duration: TimeInterval, audioTrackCount: Int? = nil,
        audioDataRate: Float? = nil
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.duration = duration
        self.audioTrackCount = audioTrackCount
        self.audioDataRate = audioDataRate
    }

    public enum ReadError: Error, Equatable {
        case noVideoTrack
    }

    /// Reads the first video track (the size is the displayed one, rotation applied) and counts the audio tracks.
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
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        var audioDataRate: Float?
        if audioTracks.count == 1 {
            audioDataRate = try? await audioTracks[0].load(.estimatedDataRate)
        }
        return VideoInfo(
            width: width, height: height,
            fps: frameRate(nominal: nominal, minFrameDuration: minDuration),
            duration: duration.seconds, audioTrackCount: audioTracks.count, audioDataRate: audioDataRate)
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
