import CoreMedia
import Foundation
import QuickTubeCore
import Testing

@Suite struct RecordingNamingTests {
    let date = Date(timeIntervalSince1970: 1_791_624_600)  // 2026-10-10 09:30:00 UTC
    let utc = TimeZone(identifier: "UTC")!

    @Test func titleIsSortableTimestamp() {
        #expect(RecordingNaming.title(for: date, timeZone: utc) == "2026-10-10 09.30.00")
    }

    @Test func fileNameAddsExtension() {
        #expect(RecordingNaming.fileName(for: date, timeZone: utc) == "2026-10-10 09.30.00.mp4")
    }

    func context(app: String? = "Xcode", display: String? = "Studio Display") -> TitleContext {
        TitleContext(date: date, app: app, display: display, timeZone: utc)
    }

    @Test func rendersAllPlaceholders() {
        #expect(
            RecordingNaming.render(template: "{date} {app} {display}", context: context())
                == "2026-10-10 09.30.00 Xcode Studio Display")
    }

    @Test func missingValuesLeaveNoStraySpaces() {
        #expect(
            RecordingNaming.render(template: "{app} {display} {date}", context: context(app: nil))
                == "Studio Display 2026-10-10 09.30.00")
        #expect(
            RecordingNaming.render(
                template: "{date} {app} {display}", context: context(app: nil, display: nil))
                == "2026-10-10 09.30.00")
    }

    @Test func emptyResultFallsBackToDate() {
        #expect(
            RecordingNaming.render(template: "{app}", context: context(app: nil))
                == "2026-10-10 09.30.00")
        #expect(RecordingNaming.render(template: "  ", context: context()) == "2026-10-10 09.30.00")
    }

    @Test func illegalCharactersBecomeDashes() {
        #expect(
            RecordingNaming.render(template: "{app} {display}", context: context(app: "A/B", display: "C:D"))
                == "A-B C-D")
    }

    @Test func metadataLineFormatting() {
        let info = VideoInfo(width: 1920, height: 1080, fps: 29.97, duration: 12)
        #expect(
            RecordingNaming.metadataLine(display: "Built-in Retina Display", info: info)
                == "Built-in Retina Display · 1920×1080 · 30 fps")
        #expect(RecordingNaming.metadataLine(display: nil, info: info) == "1920×1080 · 30 fps")
        let slow = VideoInfo(width: 3840, height: 2160, fps: 59.4, duration: 1)
        #expect(RecordingNaming.metadataLine(display: nil, info: slow) == "3840×2160 · 59 fps")
    }

    @Test func compressionLineShowsBeforeAndAfter() {
        let info = VideoInfo(width: 6016, height: 3384, fps: 59.97, duration: 30)
        let plan = TranscodePlan(width: 3008, height: 1692, videoBitrate: 1, audioBitrate: 1)
        #expect(
            RecordingNaming.compressionLine(
                from: info, sizeBytes: 120 << 20, to: plan, targetBytes: 48 << 20)
                == "Compressing · 6016×3384 60 fps 120 MB → 3008×1692 60 fps ~48 MB")
        // 120.4 MB rounds down, 47.6 MB rounds up.
        #expect(
            RecordingNaming.compressionLine(
                from: info, sizeBytes: 126_250_000, to: plan, targetBytes: 49_900_000)
                == "Compressing · 6016×3384 60 fps 120 MB → 3008×1692 60 fps ~48 MB")
    }

    @Test func compressionLineOmitsUnknownFps() {
        let info = VideoInfo(width: 1280, height: 720, fps: nil, duration: 2)
        let plan = TranscodePlan(width: 1280, height: 720, videoBitrate: 1, audioBitrate: 1)
        #expect(
            RecordingNaming.compressionLine(
                from: info, sizeBytes: 60 << 20, to: plan, targetBytes: 50 << 20)
                == "Compressing · 1280×720 60 MB → 1280×720 ~50 MB")
    }

    @Test func metadataLineSkipsUnknownFps() {
        let info = VideoInfo(width: 1280, height: 720, fps: nil, duration: 2)
        #expect(RecordingNaming.metadataLine(display: "Display", info: info) == "Display · 1280×720")
    }

    @Test func displaySizeAppliesTheTransform() {
        let natural = CGSize(width: 1920, height: 1080)
        #expect(VideoInfo.displaySize(natural: natural, transform: .identity) == (1920, 1080))
        let rotated = CGAffineTransform(rotationAngle: .pi / 2)
        #expect(VideoInfo.displaySize(natural: natural, transform: rotated) == (1080, 1920))
        let flipped = CGAffineTransform(scaleX: -1, y: 1)
        #expect(VideoInfo.displaySize(natural: natural, transform: flipped) == (1920, 1080))
    }

    @Test func frameRateFallsBackToMinFrameDuration() {
        #expect(VideoInfo.frameRate(nominal: 30, minFrameDuration: .invalid) == 30)
        #expect(VideoInfo.frameRate(nominal: 0, minFrameDuration: CMTime(value: 1, timescale: 60)) == 60)
        #expect(VideoInfo.frameRate(nominal: 0, minFrameDuration: .invalid) == nil)
        #expect(VideoInfo.frameRate(nominal: 0, minFrameDuration: .zero) == nil)
    }
}
