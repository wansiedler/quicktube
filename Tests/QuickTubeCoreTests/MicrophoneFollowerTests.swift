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
        #expect(follower.deviceChanged(uid: "headset") == .none)
        #expect(!follower.isRolling)
    }

    @Test func changeWhileRecordingRollsTheSegment() {
        var follower = recording()
        #expect(follower.deviceChanged(uid: "headset") == .rollSegment)
        #expect(follower.isRolling)
    }

    @Test func sameDeviceIsIgnored() {
        var follower = recording()
        #expect(follower.deviceChanged(uid: "built-in") == .none)
        #expect(!follower.isRolling)
    }

    @Test func unknownStartingDeviceRollsOnAnyChange() {
        var follower = recording(uid: nil)
        #expect(follower.deviceChanged(uid: "built-in") == .rollSegment)
    }

    @Test func pausedDoesNothing() {
        var follower = recording()
        follower.paused()
        #expect(follower.deviceChanged(uid: "headset") == .none)
        #expect(!follower.isRolling)
    }

    @Test func changesDuringARollCoalesceIntoIt() {
        var follower = recording()
        #expect(follower.deviceChanged(uid: "headset") == .rollSegment)
        #expect(follower.deviceChanged(uid: "usb") == .none)
        #expect(follower.deviceChanged(uid: "headset") == .none)
        // The roll opened on the device that was default then, which is still the default: done.
        #expect(follower.rollFinished(rolledTo: "headset", currentDefault: "headset") == .none)
        #expect(!follower.isRolling)
        #expect(follower.recordingUID == "headset")
    }

    @Test func oneMoreRollWhenTheDefaultMovedOnDuringTheRoll() {
        var follower = recording()
        _ = follower.deviceChanged(uid: "headset")
        _ = follower.deviceChanged(uid: "usb")
        #expect(follower.rollFinished(rolledTo: "headset", currentDefault: "usb") == .rollSegment)
        #expect(follower.isRolling)
        #expect(follower.rollFinished(rolledTo: "usb", currentDefault: "usb") == .none)
        #expect(follower.recordingUID == "usb")
    }

    @Test func rollWithoutAKnownDefaultEnds() {
        var follower = recording()
        _ = follower.deviceChanged(uid: "headset")
        #expect(follower.rollFinished(rolledTo: nil, currentDefault: nil) == .none)
        #expect(follower.phase == .recording)
    }

    @Test func failedRollStopsFollowing() {
        var follower = recording()
        _ = follower.deviceChanged(uid: "headset")
        follower.rollFailed()
        #expect(!follower.isRolling)
        #expect(follower.phase == .paused)
        #expect(follower.deviceChanged(uid: "usb") == .none)
    }

    @Test func resumingStartsFollowingAgain() {
        var follower = recording()
        follower.paused()
        follower.began(uid: "headset")
        #expect(follower.deviceChanged(uid: "headset") == .none)
        #expect(follower.deviceChanged(uid: "usb") == .rollSegment)
    }

    @Test func stoppingReturnsToIdle() {
        var follower = recording()
        _ = follower.deviceChanged(uid: "headset")
        follower.stopped()
        #expect(follower.phase == .idle)
        #expect(follower.recordingUID == nil)
        #expect(!follower.isRolling)
        #expect(follower.deviceChanged(uid: "usb") == .none)
    }
}
