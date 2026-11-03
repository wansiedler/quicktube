import QuickTubeCore
import Testing

@Suite struct MicrophoneFollowerTests {
    private func recording(uid: String? = "built-in") -> MicrophoneFollower {
        var follower = MicrophoneFollower()
        follower.began(uid: uid)
        return follower
    }

    @Test func idleIgnoresChanges() {
        var follower = MicrophoneFollower()
        #expect(follower.deviceChanged(uid: "headset", at: 10) == .none)
        #expect(follower.tick(now: 20) == .none)
        #expect(!follower.isAwaitingSample)
    }

    @Test func changeWhileRecordingUpdatesTheConfiguration() {
        var follower = recording()
        #expect(follower.deviceChanged(uid: "headset", at: 10) == .updateConfiguration(uid: "headset"))
        #expect(follower.isAwaitingSample)
        #expect(follower.configuredUID == "headset")
    }

    @Test func sameDeviceIsIgnored() {
        var follower = recording()
        #expect(follower.deviceChanged(uid: "built-in", at: 10) == .none)
        #expect(!follower.isAwaitingSample)
    }

    @Test func sampleAfterTheChangeConfirmsWithoutRolling() {
        var follower = recording()
        _ = follower.deviceChanged(uid: "headset", at: 10)
        follower.configurationApplied(at: 10.2)
        #expect(follower.microphoneSampleArrived(at: 10.5) == .none)
        #expect(!follower.isAwaitingSample)
        #expect(follower.tick(now: 13) == .none)
    }

    @Test func sampleBeforeTheUpdateWasAppliedDoesNotConfirm() {
        var follower = recording()
        _ = follower.deviceChanged(uid: "headset", at: 10)
        follower.configurationApplied(at: 10.4)
        #expect(follower.microphoneSampleArrived(at: 10.3) == .none)
        #expect(follower.isAwaitingSample)
    }

    @Test func noSampleWithinGraceRollsTheSegment() {
        var follower = recording()
        _ = follower.deviceChanged(uid: "headset", at: 10)
        follower.configurationApplied(at: 10)
        #expect(follower.tick(now: 11.4) == .none)
        #expect(follower.tick(now: 10 + MicrophoneFollower.grace) == .rollSegment)
        #expect(!follower.isAwaitingSample)
        // Rolled once; later ticks do nothing.
        #expect(follower.tick(now: 20) == .none)
    }

    @Test func graceCountsFromTheAppliedUpdate() {
        var follower = recording()
        _ = follower.deviceChanged(uid: "headset", at: 10)
        follower.configurationApplied(at: 11)
        #expect(follower.tick(now: 12) == .none)
        #expect(follower.tick(now: 12.5) == .rollSegment)
    }

    @Test func failedUpdateRollsAtOnce() {
        var follower = recording()
        _ = follower.deviceChanged(uid: "headset", at: 10)
        #expect(follower.updateFailed() == .rollSegment)
        #expect(!follower.isAwaitingSample)
    }

    @Test func failedUpdateWithoutPendingChangeDoesNothing() {
        var follower = recording()
        #expect(follower.updateFailed() == .none)
    }

    @Test func rapidChangesCoalesceToTheLastDevice() {
        var follower = recording()
        #expect(follower.deviceChanged(uid: "headset", at: 10) == .updateConfiguration(uid: "headset"))
        #expect(follower.deviceChanged(uid: "headset", at: 10.1) == .none)
        #expect(follower.deviceChanged(uid: "usb", at: 10.2) == .updateConfiguration(uid: "usb"))
        #expect(follower.configuredUID == "usb")
        // The grace restarted with the last change.
        #expect(follower.tick(now: 11.6) == .none)
        #expect(follower.tick(now: 11.75) == .rollSegment)
    }

    @Test func switchingBackWhileAwaitingUpdatesAgain() {
        var follower = recording()
        _ = follower.deviceChanged(uid: "headset", at: 10)
        #expect(follower.deviceChanged(uid: "built-in", at: 10.5) == .updateConfiguration(uid: "built-in"))
    }

    @Test func pausedRecordsTheDeviceForResume() {
        var follower = recording()
        follower.paused()
        #expect(follower.deviceChanged(uid: "headset", at: 10) == .none)
        #expect(follower.configuredUID == "headset")
        #expect(!follower.isAwaitingSample)
        #expect(follower.tick(now: 20) == .none)
    }

    @Test func pausingDropsAPendingCheck() {
        var follower = recording()
        _ = follower.deviceChanged(uid: "headset", at: 10)
        follower.paused()
        #expect(follower.tick(now: 20) == .none)
        #expect(follower.microphoneSampleArrived(at: 20) == .none)
    }

    @Test func newSegmentClearsThePendingCheck() {
        var follower = recording()
        _ = follower.deviceChanged(uid: "headset", at: 10)
        follower.began(uid: "headset")
        #expect(!follower.isAwaitingSample)
        #expect(follower.tick(now: 20) == .none)
        #expect(follower.deviceChanged(uid: "headset", at: 21) == .none)
    }

    @Test func stoppingReturnsToIdle() {
        var follower = recording()
        _ = follower.deviceChanged(uid: "headset", at: 10)
        follower.stopped()
        #expect(follower.phase == .idle)
        #expect(follower.configuredUID == nil)
        #expect(follower.tick(now: 20) == .none)
        #expect(follower.deviceChanged(uid: "usb", at: 21) == .none)
    }

    @Test func unknownStartingDeviceFollowsAnyChange() {
        var follower = recording(uid: nil)
        #expect(follower.deviceChanged(uid: "built-in", at: 10) == .updateConfiguration(uid: "built-in"))
    }
}
