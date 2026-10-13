import Foundation
import QuickTubeCore
import Testing

@Suite struct RecordingQualityTests {
    let sixK = CGSize(width: 6016, height: 3384)

    @Test func nativeKeepsSize() {
        #expect(RecordingQuality.Resolution.native.outputSize(forNative: sixK) == sixK)
    }

    @Test func presetsScaleTheLongSideDown() {
        #expect(
            RecordingQuality.Resolution.uhd4K.outputSize(forNative: sixK) == CGSize(width: 3840, height: 2160)
        )
        #expect(
            RecordingQuality.Resolution.fullHD.outputSize(forNative: sixK)
                == CGSize(width: 1920, height: 1080))
    }

    @Test func presetsNeverUpscaleAndStayEven() {
        let small = CGSize(width: 1440, height: 901)
        #expect(
            RecordingQuality.Resolution.uhd4K.outputSize(forNative: small) == CGSize(width: 1440, height: 900)
        )
        let portrait = CGSize(width: 2160, height: 3840)
        #expect(
            RecordingQuality.Resolution.fullHD.outputSize(forNative: portrait)
                == CGSize(width: 1080, height: 1920))
    }

    @Test func roundTripsThroughJSON() throws {
        let quality = RecordingQuality(resolution: .fullHD, fps: 30)
        let data = try JSONEncoder().encode(quality)
        #expect(try JSONDecoder().decode(RecordingQuality.self, from: data) == quality)
    }
}

@Suite struct RecordingBitrateTests {
    @Test func presetsHaveLabelsAndBitsPerPixel() {
        #expect(RecordingQuality.Bitrate.allCases == [.high, .balanced, .compact])
        #expect(RecordingQuality.Bitrate.allCases.map(\.label) == ["High", "Balanced", "Compact"])
        #expect(RecordingQuality.Bitrate.high.bitsPerPixelFrame == 0.032)
        #expect(RecordingQuality.Bitrate.balanced.bitsPerPixelFrame == 0.012)
        #expect(RecordingQuality.Bitrate.compact.bitsPerPixelFrame == 0.006)
    }

    @Test func bitrateScalesWithPixelsAndFrameRate() {
        func mbit(_ preset: RecordingQuality.Bitrate) -> Double {
            Double(RecordingQuality.bitrate(width: 6016, height: 3384, fps: 60, preset: preset)) / 1e6
        }
        #expect(abs(mbit(.balanced) - 14.66) < 0.01)
        #expect(abs(mbit(.compact) - 7.33) < 0.01)
        #expect(abs(mbit(.high) - 39.09) < 0.01)
    }

    @Test func bitrateIsClamped() {
        #expect(RecordingQuality.bitrate(width: 1920, height: 1080, fps: 30, preset: .compact) == 1_000_000)
        #expect(RecordingQuality.bitrate(width: 7680, height: 4320, fps: 120, preset: .high) == 80_000_000)
        #expect(RecordingQuality.bitrate(width: 0, height: 0, fps: 0, preset: .high) == 1_000_000)
    }

    @Test func presetsDifferAt1080p() {
        func rate(_ fps: Int, _ preset: RecordingQuality.Bitrate) -> Int {
            RecordingQuality.bitrate(width: 1920, height: 1080, fps: fps, preset: preset)
        }
        #expect(rate(30, .high) > rate(30, .balanced))
        #expect(rate(60, .high) > rate(60, .balanced))
        #expect(rate(60, .balanced) > rate(60, .compact))
    }

    @Test func defaultIsNative60Balanced() {
        #expect(
            RecordingQuality.default == RecordingQuality(resolution: .native, fps: 60, bitrate: .balanced))
        #expect(RecordingQuality(resolution: .fullHD, fps: 30).bitrate == .balanced)
    }

    @Test func storedValueWithoutBitrateDecodesAsBalanced() throws {
        let json = Data(#"{"resolution":"uhd4K","fps":30}"#.utf8)
        let quality = try JSONDecoder().decode(RecordingQuality.self, from: json)
        #expect(quality == RecordingQuality(resolution: .uhd4K, fps: 30, bitrate: .balanced))
    }

    @Test func bitrateRoundTripsThroughJSON() throws {
        let quality = RecordingQuality(resolution: .native, fps: 60, bitrate: .compact)
        let data = try JSONEncoder().encode(quality)
        #expect(try JSONDecoder().decode(RecordingQuality.self, from: data) == quality)
    }
}
