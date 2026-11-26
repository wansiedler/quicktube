import CoreGraphics
import QuickTubeCore
import Testing

@Suite struct RecordingInterruptionTests {
    @Test func microphoneNotificationKeepsItsWording() {
        #expect(RecordingInterruption.microphoneSwitchFailed.reason == "Microphone switch failed")
        #expect(
            RecordingInterruption.microphoneSwitchFailed.notification
                == "Microphone switch failed — recording paused; press pause to resume")
    }

    @Test func displayLossSaysToResumeWhenTheDisplayIsBack() {
        #expect(RecordingInterruption.displayLost.reason == "The display went away")
        #expect(
            RecordingInterruption.displayLost.notification
                == "The display went away — recording paused; resume when it is back")
    }
}

@Suite struct RecorderResumeTargetTests {
    @Test func displayStillThereIsKept() {
        let target = Recorder.resumeTarget(for: .display(2), displays: [1, 2], cursorDisplay: 1)
        #expect(target == .display(2))
    }

    @Test func goneDisplayFallsBackToTheDisplayUnderTheCursor() {
        let target = Recorder.resumeTarget(for: .display(5), displays: [1, 2], cursorDisplay: 2)
        #expect(target == .display(2))
    }

    @Test func goneDisplayWithTheCursorNowhereKnownTakesTheFirstDisplay() {
        let target = Recorder.resumeTarget(for: .display(5), displays: [3, 4], cursorDisplay: 9)
        #expect(target == .display(3))
    }

    @Test func noDisplayAtAllGivesNothing() {
        #expect(Recorder.resumeTarget(for: .display(5), displays: [], cursorDisplay: 5) == nil)
        let region = CaptureTarget.region(display: 5, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(Recorder.resumeTarget(for: region, displays: [], cursorDisplay: nil) == nil)
    }

    @Test func regionOnAPresentDisplayIsKept() {
        let region = CaptureTarget.region(display: 1, rect: CGRect(x: 10, y: 10, width: 200, height: 100))
        #expect(Recorder.resumeTarget(for: region, displays: [1], cursorDisplay: 1) == region)
    }

    @Test func regionOnAGoneDisplayRecordsTheWholeDisplayUnderTheCursor() {
        let region = CaptureTarget.region(display: 5, rect: CGRect(x: 10, y: 10, width: 200, height: 100))
        #expect(Recorder.resumeTarget(for: region, displays: [1, 2], cursorDisplay: 2) == .display(2))
    }

    @Test func windowTargetsAreLeftAlone() {
        #expect(Recorder.resumeTarget(for: .window(42), displays: [], cursorDisplay: nil) == .window(42))
    }
}
