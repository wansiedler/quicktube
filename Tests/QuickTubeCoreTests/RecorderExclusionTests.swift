import CoreGraphics
import QuickTubeCore
import Testing

@Suite struct RecorderExclusionTests {
    @Test func allRequestedWindowsListedAreMatched() {
        let result = Recorder.excludedWindowIDs(requested: [7, 3], available: [1, 3, 5, 7])
        #expect(result.matched == [7, 3])
        #expect(result.missing.isEmpty)
    }

    @Test func unlistedWindowsAreReportedMissing() {
        let result = Recorder.excludedWindowIDs(requested: [3, 99, 7], available: [3, 5])
        #expect(result.matched == [3])
        #expect(result.missing == [99, 7])
    }

    @Test func nothingRequestedExcludesNothing() {
        let result = Recorder.excludedWindowIDs(requested: [], available: [1, 2])
        #expect(result.matched.isEmpty)
        #expect(result.missing.isEmpty)
    }

    @Test func duplicatesAreDropped() {
        let result = Recorder.excludedWindowIDs(requested: [3, 3, 4, 4], available: [3])
        #expect(result.matched == [3])
        #expect(result.missing == [4])
    }
}
