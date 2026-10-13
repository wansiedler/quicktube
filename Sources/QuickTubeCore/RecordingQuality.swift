import Foundation

/// Output size, frame rate and bitrate presets; the recorder scales the display down, never up.
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

    /// How many bits the encoder spends per pixel and frame; the video bitrate follows size and frame rate.
    public enum Bitrate: String, Sendable, CaseIterable, Codable {
        case high
        case balanced
        case compact

        public var label: String {
            switch self {
            case .high: "High"
            case .balanced: "Balanced"
            case .compact: "Compact"
            }
        }

        /// 6016×3384 at 60 fps: high ≈ 39 Mbit/s, balanced ≈ 14.7, compact ≈ 7.3 (ScreenCaptureKit's own
        /// recording output used ≈ 21 with no control).
        public var bitsPerPixelFrame: Double {
            switch self {
            case .high: 0.032
            case .balanced: 0.012
            case .compact: 0.006
            }
        }
    }

    /// The video bitrate range a preset is clamped into: below 1 Mbit/s small frames fall apart, above
    /// 80 Mbit/s files grow without visible gain.
    public static let bitrateRange = 1_000_000...80_000_000

    public var resolution: Resolution
    public var fps: Int
    public var bitrate: Bitrate

    public init(resolution: Resolution, fps: Int, bitrate: Bitrate = .balanced) {
        self.resolution = resolution
        self.fps = fps
        self.bitrate = bitrate
    }

    /// Stored values from before the bitrate preset existed decode as `.balanced`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try container.decode(Resolution.self, forKey: .resolution)
        fps = try container.decode(Int.self, forKey: .fps)
        bitrate = try container.decodeIfPresent(Bitrate.self, forKey: .bitrate) ?? .balanced
    }

    /// Pure: width × height × fps × the preset's bits per pixel and frame, clamped to `bitrateRange`.
    public static func bitrate(width: Int, height: Int, fps: Int, preset: Bitrate) -> Int {
        let raw = Double(width) * Double(height) * Double(fps) * preset.bitsPerPixelFrame
        let clamped = min(Double(bitrateRange.upperBound), max(Double(bitrateRange.lowerBound), raw))
        return Int(clamped.rounded())
    }

    public static let `default` = RecordingQuality(resolution: .native, fps: 60, bitrate: .balanced)
    public static let frameRates = [30, 60]
}
