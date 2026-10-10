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
