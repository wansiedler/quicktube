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
}
