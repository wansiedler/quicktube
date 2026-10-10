import Foundation

/// Output size and frame rate presets; the recorder scales the display down, never up.
public struct RecordingQuality: Sendable, Equatable, Codable {
    public enum Resolution: String, Sendable, CaseIterable, Codable {
        case native
        case uhd4K
        case fullHD

        public var label: String {
            switch self {
            case .native: "Native"
            case .uhd4K: "4K"
            case .fullHD: "1080p"
            }
        }

        /// The longest side the preset allows; nil keeps the native size.
        var maxLongSide: CGFloat? {
            switch self {
            case .native: nil
            case .uhd4K: 3840
            case .fullHD: 1920
            }
        }

        /// Scales `native` to fit the preset, keeping the aspect ratio and even dimensions (HEVC needs them).
        public func outputSize(forNative native: CGSize) -> CGSize {
            var width = native.width
            var height = native.height
            if let limit = maxLongSide, max(width, height) > limit {
                let factor = limit / max(width, height)
                width *= factor
                height *= factor
            }
            return CGSize(width: Int(width.rounded()) & ~1, height: Int(height.rounded()) & ~1)
        }
    }

    public var resolution: Resolution
    public var fps: Int

    public init(resolution: Resolution, fps: Int) {
        self.resolution = resolution
        self.fps = fps
    }

    public static let `default` = RecordingQuality(resolution: .native, fps: 60)
    public static let frameRates = [30, 60]
}
