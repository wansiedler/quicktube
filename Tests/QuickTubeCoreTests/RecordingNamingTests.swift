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
}
